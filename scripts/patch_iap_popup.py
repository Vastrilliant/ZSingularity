import mmap
import struct
import sys

TARGET_HEX = [
    "d10183ffa90167faa9025ff8a90357f6a9044ff4a9057bfd910003fdaa0203f3"
    "aa0103f49000001539549aa8370002a89000000891000108aa0003f6aa0803e0"
    "9400000090000000910000009400000090000000910000009400000090000000"
    "9100000094000000900000009100000094000000aa1603e05280002839149aa8"
    "b4000a40d280000194000000b40009e090000017910002f79000001891000318"
    "900000199100033990000016910002d6f9400008a95b8509d63f0120aa0003f5"
    "b9000ff4f94002e0910003e194000000aa0003e2f9400300aa1503e1aa1303e3"
    "d280000494000000f9400328b940e50934000389d280000194000000f94002c0"
    "b940e408340004089000001339786a6836000428f94002c0b940e408340004c8"
    "f9405c08f9400100b40005009000000891000108f9400101d2800002d2800003"
    "94000000a9457bfda9444ff4a94357f6a9425ff8a94167fa910003ffd65f03c0"
    "aa0003f3aa0803e094000000aa1303e0d280000194000000f94002c0b940e408"
    "35fffc48940000009000001339786a683707fc28900000009100000094000000"
    "5280002839386a68f94002c0b940e40835fffb8894000000f94002c0f9405c08"
    "f9400100b5fffb4094000000",
    "d10183ffa90167faa9025ff8a90357f6a9044ff4a9057bfd910003fdaa0203f3"
    "aa0103f4900000153954bea8370002a89000000891000108aa0003f6aa0803e0"
    "9400000090000000910000009400000090000000910000009400000090000000"
    "9100000094000000900000009100000094000000aa1603e0528000283914bea8"
    "b4000a40d280000194000000b40009e090000017910002f79000001891000318"
    "900000199100033990000016910002d6f9400008a95b8509d63f0120aa0003f5"
    "b9000ff4f94002e0910003e194000000aa0003e2f9400300aa1503e1aa1303e3"
    "d280000494000000f9400328b940e50934000389d280000194000000f94002c0"
    "b940e408340004089000001339786a6836000428f94002c0b940e408340004c8"
    "f9405c08f9400100b40005009000000891000108f9400101d2800002d2800003"
    "94000000a9457bfda9444ff4a94357f6a9425ff8a94167fa910003ffd65f03c0"
    "aa0003f3aa0803e094000000aa1303e0d280000194000000f94002c0b940e408"
    "35fffc48940000009000001339786a683707fc28900000009100000094000000"
    "5280002839386a68f94002c0b940e40835fffb8894000000f94002c0f9405c08"
    "f9400100b5fffb4094000000",
]

SITE_INDEX = 80
NOP = 0xD503201F
NOP_BYTES = struct.pack("<I", NOP)
ARM64 = 0x0100000C
BL_OPCODE = 37


def hex_words(h):
    return struct.unpack(">%dI" % (len(h) // 8), bytes.fromhex(h))


def mask_word(w):
    top = w >> 26
    if top == 37 or top == 5:
        return w & 0xFC000000
    if (w & 0x9F000000) == 0x90000000:
        return w & 0x9F00001F
    if (w & 0xFF800000) == 0x91000000:
        return w & 0xFFC003FF
    return w


def text_range(buf):
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
            name = bytes(buf[p + 8:p + 24]).split(b"\0", 1)[0].decode("ascii", "replace")
            if name == "__TEXT":
                fileoff, filesize = struct.unpack_from("<QQ", buf, p + 40)
                return base + fileoff, filesize
        p += size
    return None


def find_sites(buf, start, size):
    targets = [hex_words(h) for h in TARGET_HEX]
    masked = [[mask_word(w) for w in t] for t in targets]
    length = len(targets[0])
    end = start + size - (size % 4)
    hits = [[] for _ in targets]
    anchors = [struct.pack("<I", t[0]) for t in targets]
    for t, anchor in enumerate(anchors):
        pos = start
        while True:
            pos = buf.find(anchor, pos, end)
            if pos < 0:
                break
            if (pos - start) % 4 != 0 or pos + length * 4 > end:
                pos += 1
                continue
            words = struct.unpack_from("<%dI" % length, buf, pos)
            fp = masked[t]
            ok = True
            for k in range(length):
                if k == SITE_INDEX:
                    continue
                if mask_word(words[k]) != fp[k]:
                    ok = False
                    break
            if ok:
                hits[t].append((pos + SITE_INDEX * 4, words[SITE_INDEX]))
            pos += 4
    return hits


def main():
    if len(sys.argv) != 2:
        print("usage: patch_iap_popup.py <UnityFramework binary>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    with open(path, "r+b") as f:
        with mmap.mmap(f.fileno(), 0) as buf:
            rng = text_range(buf)
            if rng is None:
                print("::warning::Could not locate an arm64 __TEXT segment in %s, purchase popup not suppressed." % path)
                return 0
            hits = find_sites(buf, rng[0], rng[1])
            patches = []
            already = 0
            status = "missing"
            for h in hits:
                if not h:
                    continue
                if len(h) > 1:
                    status = "ambiguous"
                    continue
                offset, word = h[0]
                if word == NOP:
                    already += 1
                    continue
                if word >> 26 != BL_OPCODE:
                    status = "unexpected"
                    continue
                patches.append(offset)
            for offset in patches:
                buf[offset:offset + 4] = NOP_BYTES
            buf.flush()
    if patches:
        print("Purchase popup patch applied @ " + ", ".join(hex(o) for o in patches))
        return 0
    if already:
        print("Purchase popup patch already present, framework left untouched")
        return 0
    print("::warning::This game build's purchase code did not match the expected layout (%s), so the launch purchase error popup was not suppressed." % status)
    return 0


if __name__ == "__main__":
    sys.exit(main())
