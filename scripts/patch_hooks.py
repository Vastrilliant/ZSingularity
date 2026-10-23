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
     "aa0003f39003b955394846a837000308d0039220910e8000974fbd21f00394a0"
     "91382000974fbd1e900394c091050000974fbd1b900394c09103e000974fbd18"
     "90039260913c2000974fbd159003982091296000974fbd12f0039740911dc000"
     "974fbd0f52800028390846a8b4001454f0039748911dc108f9404275b9402289"
     "b9000be9f9400101910023e0d2800002951b4529b4001315aa0003e1f00394b6"),
    ("MainUI.UserInfoCard.SetIntroductionText",
     "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0203f4aa0103f5aa0003f3"
     "f003b5763959bac837000128f00390e09103e000974dd8e290038ea091144000"
     "974dd8df528000283919bac8f9406660b40008e0aa1503e1d280000297f1dd4e"
     "f9406660b4000840f00390f69103e2d6aa1403e1d280000297f1dd4e291fd275"
     "f94002c094d51080b4000720f9406668b40006e8f9415c16aa0803e0d2800001"
     "97f1dd6faa0003f7f9406660b4000600d280000197f1dd71b40005b6aa0003e2"),
    ("LoadingSceneManager.SetHintText",
     "6dbb23e9a9015ff8a90257f6a9034ff4a9047bfd910103fdaa0003f3d003f9b4"
     "39742688f003d555910462b5370002a89003d580911fe000977009cd9003d460"
     "91086000977009ca9003d4609108e000977009c79003d2e09105e000977009c4"
     "f003d54091046000977009c1f003d2e0913c2000977009be5280002839342688"
     "f94002a094f7416cb4000ee0f9413c00b4000ea09003d468910861089003d2f6"
     "9105e2d6f940010194b26f50aa0003f4f94002c0b940e4083500004897700a14"),
    ("UnityEngine.Rendering.VolumeManager.Update",
     "d10303ff6d0333ed6d042beb6d0523e9a9066ffca90767faa9085ff8a90957f6"
     "a90a4ff4a90b7bfd9102c3fdaa0303f5aa0203f6aa0103f9aa0003f790013f54"
     "394fba88f00117d3910ae27336000348a9027ffff9400260b940e40834000628"
     "f9405c08f9400914b4000094aa1403e0d2800001940cfa78f90017f49100a3e8"
     "a90123ff394182e87100051f54001c21f9401ee0b4001ec0d28000019401ae19"
     "340004c0b4001e59528000283900832814000027b0011a809111a00096126d4a"),
    ("MainUI.SettingsPanelEtc.Open",
     "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0003f3f003b115396ceaa8"
     "d0038c96913822d6d0038a3491216294370001e890038a00912d0000974bab24"
     "90038a20910c2000974bab21d0038a2091216000974bab1ed0038c8091382000"
     "974bab1b52800028392ceaa8f94002c094d2e0e3aa0003f5f9400280974babc6"
     "aa0003f4f003b117396ceee8b0038a56912342d6370000c8b0038a4091234000"
     "974bab0b52800028392ceee8aa1403e0d28000019518837df94002c0974babb6"),
    ("MainUI.SettingsPanelEtc.ReloadUI",
     "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0003f3f003b114396aa688"
     "370002a8d0038c8091382000974baaa8b0038ec091052000974baaa5d0038f00"
     "91044000974baaa2d0038f40911de000974baa9f90038ec0913ea000974baa9c"
     "b0038fa09109c000974baa9952800028392aa688940000caaa0003f4f9401a60"
     "b40018c0aa1403e1d280000297d91bb5f9401e60b4001820d0038c95913822b5"
     "aa1403e1d280000297d91baeaa1303e052800021940000edf9402274f94002a0"),
    ("MainUI.ShowIntegrateCodeUIPopup.SetPublicId",
     "a9be4ff4a9017bfd910043fdaa0003f3f80b8e61aa1303e0974c6cbdf85c0260"
     "b4000100f9400261f9400008f942ad03f942b102a9417bfda8c24ff4d61f0060"
     "974c6d85"),
    ("MainUI.ShowIntegrateCodeUIPopup.SetDataOpen",
     "d100c3ffa9014ff4a9027bfd910083fdaa0003f3f80a0c01974c6cacaa1303e0"
     "d280000197f987c39003b2b439650e88370000c8b0038bc0912d2000974c6cbe"
     "5280002839250e88f9405660b4000380b0038bd4912d2294d2800001d2800002"
     "97d8e15cf90007e0f9400280b940e408340001a8910023e0d280000195187a26"
     "1e602008540001c5f9406261aa1303e09400004aa9427bfda9414ff49100c3ff"
     "d65f03c0974c6d0c910023e0d280000195187a191e60200854fffe84d003b448"),
    ("StageStatisticPopupSlotScrollViewItem.SetData",
     "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0103f4aa0003f3b003f3b5"
     "39511aa837000248d003cec091356000976d001ed003cec091358000976d001b"
     "d003cec09135a000976d0018b003cce0913c2000976d0015f003cf4091396000"
     "976d00125280002839111aa8aa1303e0f8058c14aa1403e1976cfff1b4000854"
     "f9403260b4000080f9400a81d28000029563f990f9403675b40001f5b9401a96"
     "b003cce8913c2108f9400100b940e40835000048976d0065aa1603e0d2800001"),
    ("MainUI.SelectIntegrateAccountItemObject.SetData",
     "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0103f3aa0003f4d003b2b5"
     "3964f2a8370000c8d0038bc0913c2000974c75b2528000283924f2a8f9401280"
     "b40007a0d0038bd7913c22f7f9400261f9400008f942ad09f942b102d63f0120"
     "f9401695b9400a76f94002e0b940e40835000048974c7609aa1603e0d2800001"
     "97f0cc5eb4000595aa0003e1f94002a8f942ad09f942b102aa1503e0d63f0120"
     "f9401e95b9400e60d280000197f0cc53b4000435aa0003e1f94002a8f942ad09"),
    ("MainUI.AskBeforeConfirmIntegratePanel.SetData",
     "d10103ffa9024ff4a9037bfd9100c3fdaa0003f4f9401000b4000240aa0103f3"
     "3dc000203d8003e0f9400828f9000be8910003e19400000cf9401680b4000120"
     "f9400261f9400008f942ad03f942b102a9437bfda9424ff4910103ffd61f0060"
     "974c7676"),
    ("LoginSceneManager.SetLoginInfo",
     "d10183ff6d0223e9a90357f6a9044ff4a9057bfd910143fdaa0003f39003f8d4"
     "3978da8837000428d003d18091056000976f9393b003d1a091282000976f9390"
     "b003d1e0912fc000976f938d9003d46091382000976f938ab003d760911fc000"
     "976f9387f003d6c091156000976f9384f003d7809103e000976f9381f003d700"
     "913da000976f937ed003d680913ea000976f937bd003d76091028000976f9378"
     "528000283938da88f9405a60b4001e4052800001d2800002956d04d5f9403260"),
]


def hex_words(h):
    return struct.unpack(">%dI" % (len(h) // 8), bytes.fromhex(h))


def mask_strict(w):
    top = w >> 26
    if top == 37 or top == 5:
        return w & 0xFC000000
    if (w & 0x9F000000) == 0x90000000:
        return w & 0x9F00001F
    if (w & 0xFF800000) == 0x91000000:
        return w & 0xFFC003FF
    return w


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


def tol_for(length):
    return min(6, max(2, (length - STUB_WORDS) // 12))


def find_matches(buf, start, size, targets):
    masked = [[mask_word(w) for w in t] for t in targets]
    strict = [[mask_strict(w) for w in t] for t in targets]
    end = start + size - (size % 4)
    hits = [[] for _ in targets]
    skip = STUB_WORDS
    for t, words in enumerate(targets):
        length = len(words)
        tol = tol_for(length)
        anchor_at = next((k for k in range(skip, length) if (words[k] >> 24) == 0xA9), skip)
        anchor = struct.pack("<I", words[anchor_at])
        pos = start + anchor_at * 4
        while True:
            pos = buf.find(anchor, pos, end)
            if pos < 0:
                break
            head = pos - anchor_at * 4
            if (pos - start) % 4 != 0 or head < start or head + length * 4 > end:
                pos += 1
                continue
            got = struct.unpack_from("<%dI" % length, buf, head)
            miss = 0
            for k in range(skip, length):
                if mask_word(got[k]) != masked[t][k]:
                    miss += 1
                    if miss > tol:
                        break
            if miss <= tol:
                s_miss = sum(1 for k in range(skip, length) if mask_strict(got[k]) != strict[t][k])
                hits[t].append((head, got[:skip] == tuple(words[:skip]), miss, s_miss))
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
                if len(h) > 1:
                    best = min(x[2] * 1000 + x[3] for x in h)
                    h = [x for x in h if x[2] * 1000 + x[3] == best]
                if not h:
                    problems.append("%s: not found" % name)
                    continue
                if len(h) > 1:
                    problems.append("%s: ambiguous" % name)
                    continue
                off, pristine = h[0][0], h[0][1]
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
