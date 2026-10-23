import mmap
import struct
import sys

FINGERPRINT_HEX = (
    "a9bc5ff8a90157f6a9024ff4a9037bfd910003fdaa0003f39000001439400288"
    "90000015910002b536000488f94002b690000017394002e89000001491000294"
    "3600058890000017910002f7f9400280b940000834000628d280000094000000"
    "aa0003f4f94002b5f94002e0b94000083500004894000000f100029f9a9402a0"
    "f100027f9a9302c1d280000294000000aa0003f3d2800001940000007100001f"
    "9a9f1260a9437bfda9424ff4a94157f6a8c45ff8d65f03c09000000091000000"
    "940000009000000091000000940000005280002839000288f94002b690000017"
    "394002e890000014910002943707fac890000000910000009400000052800028"
    "390002e890000017910002f7f9400280b940000835fffa289400000014000000"
)

SITE_INDEX = 23
ANCHOR_AT = 1
ANCHOR_LEN = 3
MAX_MISMATCH = 6
GETTER_WORDS = 60
ICALL_ADRP_INDEX = 26
ICALL_ADD_INDEX = 27
SCAN_SPAN = 0x4000
DATA_PATH_ICALL = b"UnityEngine.Application::get_dataPath"
PERSISTENT_PATH_ICALL = b"UnityEngine.Application::get_persistentDataPath"
ARM64 = 0x0100000C
BL_OPCODE = 37


def mask_word(w):
    top = w >> 26
    if top == 37 or top == 5:
        return w & 0xFC000000
    if (w & 0x9F000000) == 0x90000000:
        return w & 0x9F00001F
    if (w & 0xFF800000) == 0x91000000:
        return w & 0xFFC003FF
    if (w & 0x3B000000) == 0x39000000:
        return w & 0xFFC003FF
    return w


def sign_extend(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def text_segment(buf):
    magic = struct.unpack_from(">I", buf, 0)[0]
    base = 0
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        is64 = magic == 0xCAFEBABF
        count = struct.unpack_from(">I", buf, 4)[0]
        stride = 32 if is64 else 20
        found = False
        for i in range(count):
            o = 8 + i * stride
            if struct.unpack_from(">I", buf, o)[0] == ARM64:
                base = struct.unpack_from(">Q" if is64 else ">I", buf, o + 8)[0]
                found = True
                break
        if not found:
            return None
    mh_magic, cputype = struct.unpack_from("<II", buf, base)
    if mh_magic != 0xFEEDFACF or cputype != ARM64:
        return None
    ncmds, sizeofcmds = struct.unpack_from("<II", buf, base + 16)
    p = base + 32
    end = p + sizeofcmds
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", buf, p)
        if size < 8 or p + size > end:
            return None
        if cmd == 0x19:
            name = bytes(buf[p + 8:p + 24]).split(b"\0", 1)[0]
            if name == b"__TEXT":
                vmaddr, _vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", buf, p + 24)
                return {"base": base, "start": base + fileoff, "size": filesize, "vmaddr": vmaddr, "fileoff": fileoff}
        p += size
    return None


def find_sites(buf, seg, fingerprint):
    length = len(fingerprint)
    anchor = struct.pack("<%dI" % ANCHOR_LEN, *fingerprint[ANCHOR_AT:ANCHOR_AT + ANCHOR_LEN])
    start = seg["start"]
    end = start + seg["size"] - (seg["size"] % 4)
    found = []
    pos = start
    while True:
        pos = buf.find(anchor, pos, end)
        if pos < 0:
            break
        base = pos - ANCHOR_AT * 4
        if base < start or (pos - start) % 4 != 0 or base + length * 4 > end:
            pos += 1
            continue
        words = struct.unpack_from("<%dI" % length, buf, base)
        miss = 0
        for k in range(length):
            if mask_word(words[k]) != fingerprint[k]:
                miss += 1
                if miss > MAX_MISMATCH:
                    break
        if miss <= MAX_MISMATCH:
            found.append((miss, base))
        pos += 4
    if not found:
        return []
    best = min(m for m, _ in found)
    return [b for m, b in found if m == best]


def bl_target(buf, site):
    w = struct.unpack_from("<I", buf, site)[0]
    if w >> 26 != BL_OPCODE:
        return None
    return site + sign_extend(w & 0x3FFFFFF, 26) * 4


def icall_name(buf, seg, func):
    adrp = struct.unpack_from("<I", buf, func + ICALL_ADRP_INDEX * 4)[0]
    add = struct.unpack_from("<I", buf, func + ICALL_ADD_INDEX * 4)[0]
    if (adrp & 0x9F000000) != 0x90000000 or (add & 0xFF800000) != 0x91000000:
        return None
    pc = seg["vmaddr"] + (func + ICALL_ADRP_INDEX * 4 - seg["fileoff"] - seg["base"])
    imm = sign_extend(((adrp >> 5) & 0x7FFFF) << 2 | ((adrp >> 29) & 3), 21) << 12
    shift = 12 if (add >> 22) & 1 else 0
    va = (pc & ~0xFFF) + imm + (((add >> 10) & 0xFFF) << shift)
    off = va - seg["vmaddr"] + seg["fileoff"] + seg["base"]
    if off < seg["start"] or off + 96 > seg["start"] + seg["size"]:
        return None
    return bytes(buf[off:off + 96]).split(b"\0", 1)[0]


def find_persistent_getter(buf, seg, data_getter):
    shape = [mask_word(w) for w in struct.unpack_from("<%dI" % GETTER_WORDS, buf, data_getter)]
    anchor = struct.pack("<4I", *struct.unpack_from("<4I", buf, data_getter))
    limit = min(data_getter + SCAN_SPAN, seg["start"] + seg["size"] - GETTER_WORDS * 4)
    found = []
    pos = data_getter + 4
    while True:
        pos = buf.find(anchor, pos, limit)
        if pos < 0:
            break
        if (pos - seg["start"]) % 4 == 0:
            words = struct.unpack_from("<%dI" % GETTER_WORDS, buf, pos)
            if all(mask_word(words[k]) == shape[k] for k in range(4, GETTER_WORDS)):
                name = icall_name(buf, seg, pos)
                if name is not None and name.startswith(PERSISTENT_PATH_ICALL):
                    found.append(pos)
        pos += 4
    return found


def warn(msg):
    print("::warning::" + msg)
    return 0


def main():
    if len(sys.argv) != 2:
        print("usage: patch_custom_localize.py <UnityFramework binary>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    fingerprint = [mask_word(w) for w in struct.unpack(">%dI" % (len(FINGERPRINT_HEX) // 8), bytes.fromhex(FINGERPRINT_HEX))]
    with open(path, "r+b") as f:
        with mmap.mmap(f.fileno(), 0) as buf:
            seg = text_segment(buf)
            if seg is None:
                return warn("Could not locate an arm64 __TEXT segment in %s, custom localize path not patched." % path)
            hits = find_sites(buf, seg, fingerprint)
            if len(hits) != 1:
                return warn("CustomDataPath.GetDirectory %s (%d matches), custom localize path not patched." % ("not found" if not hits else "is ambiguous", len(hits)))
            site = hits[0] + SITE_INDEX * 4
            target = bl_target(buf, site)
            if target is None:
                return warn("Unexpected instruction at the GetDirectory patch site, custom localize path not patched.")
            name = icall_name(buf, seg, target)
            if name is not None and name.startswith(PERSISTENT_PATH_ICALL):
                print("Custom localize path patch already present, framework left untouched")
                return 0
            if name is None or not name.startswith(DATA_PATH_ICALL):
                return warn("GetDirectory no longer calls Application.dataPath, custom localize path not patched.")
            persistent = find_persistent_getter(buf, seg, target)
            if len(persistent) != 1:
                return warn("Application.persistentDataPath getter %s (%d matches), custom localize path not patched." % ("not found" if not persistent else "is ambiguous", len(persistent)))
            delta = (persistent[0] - site) // 4
            if not -(1 << 25) <= delta < (1 << 25):
                return warn("persistentDataPath getter is out of branch range, custom localize path not patched.")
            buf[site:site + 4] = struct.pack("<I", 0x94000000 | (delta & 0x3FFFFFF))
            buf.flush()
    print("Custom localize path patch applied @ %s, Application.dataPath -> Application.persistentDataPath" % hex(site))
    return 0


if __name__ == "__main__":
    sys.exit(main())
