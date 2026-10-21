import mmap
import struct
import sys

ARM64 = 0x0100000C
STUB_WORDS = 3
CAVE_STRIDE = 48
CAVE_ORIG_OFFSET = 16
SLOT_SIZE = 8
BR_X16 = 0xD61F0200
CBZ_X16_PLUS8 = 0xB4000050
LDR_X16_BASE = 0xF9400210
ADD_X16_BASE = 0x91000210
ADRP_X16_BASE = 0x90000010
PAGE = 0x1000

TARGETS = [
    ("MainUI.LowerControlUIPanel.UpdateUserInfo",
     "d10183ff6d0123e9a9025ff8a90357f6a9044ff4a9057bfd910143fdaa0103f4"
     "aa0003f3b003b955397422a8370003089003924091008000974fc460b00394c0"),
    ("MainUI.UserInfoCard.SetIntroductionText",
     "a9bb67faa9015ff8a90257f6a9034ff4a9047bfd910103fdaa0203f4aa0103f5"
     "aa0003f3b003b596394596c8370001289003910091350000974de043d0038ea0"),
    ("LoadingSceneManager.SetHintText",
     "6dbb23e9a9015ff8a90257f6a9034ff4a9047bfd910103fdaa0003f39003f9d4"
     "396006889003d575913582b5370002a8d003d580911100009770129fb003d460"),
    ("UnityEngine.Rendering.VolumeManager.Update",
     "d10303ff6d0333ed6d042beb6d0523e9a9066ffca90767faa9085ff8a90957f6"
     "a90a4ff4a90b7bfd9102c3fdaa0303f5aa0203f6aa0103f9aa0003f7b0013f54"),
    ("MainUI.SettingsPanelEtc.Open",
     "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0003f3b003b1353958c2a8"
     "90038cb6912942d690038a5491136294370001e8d0038a00911f0000974bb27f"),
    ("MainUI.SettingsPanelEtc.ReloadUI",
     "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0003f3b003b13439567e88"
     "370002a890038ca091294000974bb203d0038ec091360000974bb200f0038f00"),
    ("MainUI.ShowIntegrateCodeUIPopup.SetPublicId",
     "a9be4ff4a9017bfd910043fdaa0003f3f80b8e61aa1303e0974c7418f85c0260"
     "b4000100f9400261f9400008f942ad03f942b102a9417bfda8c24ff4d61f0060"),
    ("MainUI.ShowIntegrateCodeUIPopup.SetDataOpen",
     "d100c3ffa9014ff4a9027bfd910083fdaa0003f3f80a0c01974c7407aa1303e0"
     "d280000197f987dfd003b2b43950e688370000c8f0038bc0911f2000974c7419"),
    ("StageStatisticPopupSlotScrollViewItem.SetData",
     "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0103f4aa0003f3d003f3b5"
     "397cfaa8370002489003cee091268000976d08fd9003cee09126a000976d08fa"),
    ("MainUI.SelectIntegrateAccountItemObject.SetData",
     "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0103f3aa0003f49003b2d5"
     "3950caa8370000c890038be0912e2000974c7d0d528000283910caa8f9401280"),
    ("MainUI.AskBeforeConfirmIntegratePanel.SetData",
     "d10103ffa9024ff4a9037bfd9100c3fdaa0003f4f9401000b4000240aa0103f3"
     "3dc000203d8003e0f9400828f9000be8910003e19400000cf9401680b4000120"),
    ("LoginSceneManager.SetLoginInfo",
     "d10183ff6d0223e9a90357f6a9044ff4a9057bfd910143fdaa0003f3f003f8d4"
     "3964ba88370004289003d1a091382000976f9c659003d1c0911a2000976f9c62"),
]


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


def pc_independent(w):
    if (w & 0x9F000000) in (0x90000000, 0x10000000):
        return False
    if (w & 0x3B000000) == 0x18000000:
        return False
    if (w >> 26) in (5, 37):
        return False
    if (w & 0x7E000000) in (0x34000000, 0x36000000):
        return False
    if (w & 0xFF000010) == 0x54000000:
        return False
    if (w & 0xFE000000) == 0xD6000000:
        return False
    return True


def adrp(rd, pc, target):
    delta = ((target & ~(PAGE - 1)) - (pc & ~(PAGE - 1))) >> 12
    if not -(1 << 20) <= delta < (1 << 20):
        return None
    delta &= 0x1FFFFF
    return 0x90000000 | ((delta & 3) << 29) | ((delta >> 2) << 5) | rd


def stub_words(pc, target):
    a = adrp(16, pc, target)
    if a is None:
        return None
    return [a, ADD_X16_BASE | ((target & (PAGE - 1)) << 10), BR_X16]


def decode_adrp(w, pc):
    imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
    if imm & (1 << 20):
        imm -= 1 << 21
    return (pc & ~(PAGE - 1)) + (imm << 12)


def parse_macho(buf):
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
    segments = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", buf, p)
        if size < 8 or p + size > end:
            return None
        if cmd == 0x19:
            name = bytes(buf[p + 8:p + 24]).split(b"\0", 1)[0].decode("ascii", "replace")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", buf, p + 24)
            maxprot, initprot, nsects = struct.unpack_from("<iiI", buf, p + 56)
            sect_end = vmaddr
            q = p + 72
            for _s in range(nsects):
                saddr, ssize = struct.unpack_from("<QQ", buf, q + 32)
                sect_end = max(sect_end, saddr + ssize)
                q += 80
            segments.append({
                "name": name, "vmaddr": vmaddr, "vmsize": vmsize,
                "fileoff": base + fileoff, "filesize": filesize,
                "initprot": initprot, "used_end": sect_end,
            })
        p += size
    return base, segments


def va_to_off(segments, va):
    for s in segments:
        if s["vmaddr"] <= va < s["vmaddr"] + min(s["vmsize"], s["filesize"]):
            return s["fileoff"] + (va - s["vmaddr"])
    return None


def find_matches(buf, start, size, targets):
    masked = [[mask_word(w) for w in t] for t in targets]
    end = start + size - (size % 4)
    hits = [[] for _ in targets]
    skip = STUB_WORDS
    for t, words in enumerate(targets):
        anchor = struct.pack("<I", words[skip])
        length = len(words)
        pos = start + skip * 4
        while True:
            pos = buf.find(anchor, pos, end)
            if pos < 0:
                break
            head = pos - skip * 4
            if (pos - start) % 4 != 0 or head < start or head + length * 4 > end:
                pos += 1
                continue
            got = struct.unpack_from("<%dI" % length, buf, head)
            ok = True
            for k in range(skip, length):
                if mask_word(got[k]) != masked[t][k]:
                    ok = False
                    break
            if ok:
                hits[t].append((head, got[:skip] == tuple(words[:skip])))
            pos += 4
    return hits


def existing_cave(buf, segments, text, off):
    w = struct.unpack_from("<3I", buf, off)
    if (w[0] & 0x9F00001F) != ADRP_X16_BASE or (w[1] & 0xFFC003FF) != ADD_X16_BASE or w[2] != BR_X16:
        return None
    va = text["vmaddr"] + (off - text["fileoff"])
    cave = decode_adrp(w[0], va) + (((w[1] >> 10) & 0xFFF))
    cave_off = va_to_off(segments, cave)
    if cave_off is None:
        return None
    c = struct.unpack_from("<4I", buf, cave_off)
    if (c[0] & 0x9F00001F) != ADRP_X16_BASE or (c[1] & 0xFFC003FF) != LDR_X16_BASE:
        return None
    if c[2] != CBZ_X16_PLUS8 or c[3] != BR_X16:
        return None
    return cave


def main():
    if len(sys.argv) != 2:
        print("usage: patch_hooks.py <UnityFramework binary>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    with open(path, "r+b") as f:
        with mmap.mmap(f.fileno(), 0) as buf:
            parsed = parse_macho(buf)
            if parsed is None:
                print("::warning::Could not parse an arm64 Mach-O in %s, event hooks not installed." % path)
                return 0
            _base, segments = parsed
            text = next((s for s in segments if s["name"] == "__TEXT"), None)
            data = next((s for s in segments if s["name"] == "__DATA"), None)
            if not text or not data or not (data["initprot"] & 2):
                print("::warning::Unexpected segment layout, event hooks not installed.")
                return 0

            targets = [hex_words(h) for _n, h in TARGETS]
            hits = find_matches(buf, text["fileoff"], text["filesize"], targets)

            cave_va = (text["used_end"] + 15) & ~15
            cave_limit = text["vmaddr"] + min(text["vmsize"], text["filesize"])
            slot_va = (data["used_end"] + 7) & ~7
            slot_limit = data["vmaddr"] + data["vmsize"]

            planned = []
            applied = []
            already = []
            problems = []
            for (name, _h), h, words in zip(TARGETS, hits, targets):
                h = [x for x in h if x[1] or existing_cave(buf, segments, text, x[0]) is not None]
                if not h:
                    problems.append("%s: not found" % name)
                    continue
                if len(h) > 1:
                    problems.append("%s: ambiguous" % name)
                    continue
                off, pristine = h[0]
                if not pristine:
                    already.append(name)
                    continue
                displaced = list(words[:STUB_WORDS])
                if not all(pc_independent(w) for w in displaced):
                    problems.append("%s: entry instructions are position dependent" % name)
                    continue
                if cave_va + CAVE_STRIDE > cave_limit:
                    problems.append("%s: no room for a trampoline" % name)
                    continue
                if slot_va + SLOT_SIZE > slot_limit:
                    problems.append("%s: no room for a hook slot" % name)
                    continue
                func_va = text["vmaddr"] + (off - text["fileoff"])
                entry = stub_words(func_va, cave_va)
                cave_off = va_to_off(segments, cave_va)
                if entry is None or cave_off is None:
                    problems.append("%s: trampoline out of range" % name)
                    continue
                if any(struct.unpack_from("<12I", buf, cave_off)):
                    problems.append("%s: trampoline area is not empty" % name)
                    continue
                back = stub_words(cave_va + 28, func_va + STUB_WORDS * 4)
                if back is None:
                    problems.append("%s: return trampoline out of range" % name)
                    continue
                slot_adrp = adrp(16, cave_va, slot_va)
                if slot_adrp is None:
                    problems.append("%s: hook slot out of range" % name)
                    continue
                cave = [
                    slot_adrp,
                    LDR_X16_BASE | (((slot_va & (PAGE - 1)) >> 3) << 10),
                    CBZ_X16_PLUS8,
                    BR_X16,
                ] + list(struct.unpack_from("<3I", buf, off)) + back
                planned.append((name, off, entry, cave_off, cave, cave_va, slot_va))
                cave_va += CAVE_STRIDE
                slot_va += SLOT_SIZE

            for name, off, entry, cave_off, cave, cva, sva in planned:
                buf[cave_off:cave_off + len(cave) * 4] = struct.pack("<%dI" % len(cave), *cave)
            for name, off, entry, cave_off, cave, cva, sva in planned:
                buf[off:off + 12] = struct.pack("<3I", *entry)
                applied.append(name)
            buf.flush()

    for name in applied:
        print("Event hook site installed: " + name)
    for name in already:
        print("Event hook site already present: " + name)
    if problems:
        print("::warning::Event hook sites skipped (%s). Features depending on them keep using their fallback." % "; ".join(problems))
    if not applied and not already:
        print("::warning::No event hook sites were installed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
