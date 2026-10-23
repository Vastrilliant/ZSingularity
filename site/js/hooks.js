const ARM64 = 0x0100000c;
const STUB_WORDS = 3;
const CAVE_STRIDE = 48;
const CAVE_ORIG_OFFSET = 16;
const SLOT_SIZE = 8;
const BR_X16 = 0xd61f0200;
const CBZ_X16_PLUS8 = 0xb4000050;
const LDR_X16_BASE = 0xf9400210;
const ADD_X16_BASE = 0x91000210;
const ADRP_X16_BASE = 0x90000010;
const PAGE = 4096;
const PIECE = 1 << 22;

const TARGETS = [
  ["MainUI.LowerControlUIPanel.UpdateUserInfo",
    "d10183ff6d0123e9a9025ff8a90357f6a9044ff4a9057bfd910143fdaa0103f4" +
    "aa0003f39003b955394846a837000308d0039220910e8000974fbd21f00394a0" +
    "91382000974fbd1e900394c091050000974fbd1b900394c09103e000974fbd18" +
    "90039260913c2000974fbd159003982091296000974fbd12f0039740911dc000" +
    "974fbd0f52800028390846a8b4001454f0039748911dc108f9404275b9402289" +
    "b9000be9f9400101910023e0d2800002951b4529b4001315aa0003e1f00394b6"],
  ["MainUI.UserInfoCard.SetIntroductionText",
    "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0203f4aa0103f5aa0003f3" +
    "f003b5763959bac837000128f00390e09103e000974dd8e290038ea091144000" +
    "974dd8df528000283919bac8f9406660b40008e0aa1503e1d280000297f1dd4e" +
    "f9406660b4000840f00390f69103e2d6aa1403e1d280000297f1dd4e291fd275" +
    "f94002c094d51080b4000720f9406668b40006e8f9415c16aa0803e0d2800001" +
    "97f1dd6faa0003f7f9406660b4000600d280000197f1dd71b40005b6aa0003e2"],
  ["LoadingSceneManager.SetHintText",
    "6dbb23e9a9015ff8a90257f6a9034ff4a9047bfd910103fdaa0003f3d003f9b4" +
    "39742688f003d555910462b5370002a89003d580911fe000977009cd9003d460" +
    "91086000977009ca9003d4609108e000977009c79003d2e09105e000977009c4" +
    "f003d54091046000977009c1f003d2e0913c2000977009be5280002839342688" +
    "f94002a094f7416cb4000ee0f9413c00b4000ea09003d468910861089003d2f6" +
    "9105e2d6f940010194b26f50aa0003f4f94002c0b940e4083500004897700a14"],
  ["UnityEngine.Rendering.VolumeManager.Update",
    "d10303ff6d0333ed6d042beb6d0523e9a9066ffca90767faa9085ff8a90957f6" +
    "a90a4ff4a90b7bfd9102c3fdaa0303f5aa0203f6aa0103f9aa0003f790013f54" +
    "394fba88f00117d3910ae27336000348a9027ffff9400260b940e40834000628" +
    "f9405c08f9400914b4000094aa1403e0d2800001940cfa78f90017f49100a3e8" +
    "a90123ff394182e87100051f54001c21f9401ee0b4001ec0d28000019401ae19" +
    "340004c0b4001e59528000283900832814000027b0011a809111a00096126d4a"],
  ["MainUI.SettingsPanelEtc.Open",
    "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0003f3f003b115396ceaa8" +
    "d0038c96913822d6d0038a3491216294370001e890038a00912d0000974bab24" +
    "90038a20910c2000974bab21d0038a2091216000974bab1ed0038c8091382000" +
    "974bab1b52800028392ceaa8f94002c094d2e0e3aa0003f5f9400280974babc6" +
    "aa0003f4f003b117396ceee8b0038a56912342d6370000c8b0038a4091234000" +
    "974bab0b52800028392ceee8aa1403e0d28000019518837df94002c0974babb6"],
  ["MainUI.SettingsPanelEtc.ReloadUI",
    "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0003f3f003b114396aa688" +
    "370002a8d0038c8091382000974baaa8b0038ec091052000974baaa5d0038f00" +
    "91044000974baaa2d0038f40911de000974baa9f90038ec0913ea000974baa9c" +
    "b0038fa09109c000974baa9952800028392aa688940000caaa0003f4f9401a60" +
    "b40018c0aa1403e1d280000297d91bb5f9401e60b4001820d0038c95913822b5" +
    "aa1403e1d280000297d91baeaa1303e052800021940000edf9402274f94002a0"],
  ["MainUI.ShowIntegrateCodeUIPopup.SetPublicId",
    "a9be4ff4a9017bfd910043fdaa0003f3f80b8e61aa1303e0974c6cbdf85c0260" +
    "b4000100f9400261f9400008f942ad03f942b102a9417bfda8c24ff4d61f0060" +
    "974c6d85"],
  ["MainUI.ShowIntegrateCodeUIPopup.SetDataOpen",
    "d100c3ffa9014ff4a9027bfd910083fdaa0003f3f80a0c01974c6cacaa1303e0" +
    "d280000197f987c39003b2b439650e88370000c8b0038bc0912d2000974c6cbe" +
    "5280002839250e88f9405660b4000380b0038bd4912d2294d2800001d2800002" +
    "97d8e15cf90007e0f9400280b940e408340001a8910023e0d280000195187a26" +
    "1e602008540001c5f9406261aa1303e09400004aa9427bfda9414ff49100c3ff" +
    "d65f03c0974c6d0c910023e0d280000195187a191e60200854fffe84d003b448"],
  ["StageStatisticPopupSlotScrollViewItem.SetData",
    "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0103f4aa0003f3b003f3b5" +
    "39511aa837000248d003cec091356000976d001ed003cec091358000976d001b" +
    "d003cec09135a000976d0018b003cce0913c2000976d0015f003cf4091396000" +
    "976d00125280002839111aa8aa1303e0f8058c14aa1403e1976cfff1b4000854" +
    "f9403260b4000080f9400a81d28000029563f990f9403675b40001f5b9401a96" +
    "b003cce8913c2108f9400100b940e40835000048976d0065aa1603e0d2800001"],
  ["MainUI.SelectIntegrateAccountItemObject.SetData",
    "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0103f3aa0003f4d003b2b5" +
    "3964f2a8370000c8d0038bc0913c2000974c75b2528000283924f2a8f9401280" +
    "b40007a0d0038bd7913c22f7f9400261f9400008f942ad09f942b102d63f0120" +
    "f9401695b9400a76f94002e0b940e40835000048974c7609aa1603e0d2800001" +
    "97f0cc5eb4000595aa0003e1f94002a8f942ad09f942b102aa1503e0d63f0120" +
    "f9401e95b9400e60d280000197f0cc53b4000435aa0003e1f94002a8f942ad09"],
  ["MainUI.AskBeforeConfirmIntegratePanel.SetData",
    "d10103ffa9024ff4a9037bfd9100c3fdaa0003f4f9401000b4000240aa0103f3" +
    "3dc000203d8003e0f9400828f9000be8910003e19400000cf9401680b4000120" +
    "f9400261f9400008f942ad03f942b102a9437bfda9424ff4910103ffd61f0060" +
    "974c7676"],
  ["LoginSceneManager.SetLoginInfo",
    "d10183ff6d0223e9a90357f6a9044ff4a9057bfd910143fdaa0003f39003f8d4" +
    "3978da8837000428d003d18091056000976f9393b003d1a091282000976f9390" +
    "b003d1e0912fc000976f938d9003d46091382000976f938ab003d760911fc000" +
    "976f9387f003d6c091156000976f9384f003d7809103e000976f9381f003d700" +
    "913da000976f937ed003d680913ea000976f937bd003d76091028000976f9378" +
    "528000283938da88f9405a60b4001e4052800001d2800002956d04d5f9403260"],
];

const MIN_LEN = 16;
const MAX_MISMATCH = 2;
const tolFor = (len) => Math.min(6, Math.max(MAX_MISMATCH, Math.floor((len - STUB_WORDS) / 12)));

function hexWords(hex) {
  const out = new Uint32Array(hex.length / 8);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 8, i * 8 + 8), 16) >>> 0;
  return out;
}

function maskStrict(w) {
  const top = w >>> 26;
  if (top === 37 || top === 5) return (w & 0xfc000000) >>> 0;
  if (((w & 0x9f000000) >>> 0) === 0x90000000) return (w & 0x9f00001f) >>> 0;
  if (((w & 0xff800000) >>> 0) === 0x91000000) return (w & 0xffc003ff) >>> 0;
  return w >>> 0;
}

function maskWord(w) {
  const top = w >>> 26;
  if (top === 37 || top === 5) return (w & 0xfc000000) >>> 0;
  if (((w & 0x9f000000) >>> 0) === 0x90000000) return (w & 0x9f00001f) >>> 0;
  if (((w & 0xff800000) >>> 0) === 0x91000000) return (w & 0xffc003ff) >>> 0;
  if (((w & 0x3b000000) >>> 0) === 0x39000000) return (w & 0xffc003ff) >>> 0;
  return w >>> 0;
}

function pcIndependent(w) {
  const a = (w & 0x9f000000) >>> 0;
  if (a === 0x90000000 || a === 0x10000000) return false;
  if (((w & 0x3b000000) >>> 0) === 0x18000000) return false;
  const top = w >>> 26;
  if (top === 5 || top === 37) return false;
  const c = (w & 0x7e000000) >>> 0;
  if (c === 0x34000000 || c === 0x36000000) return false;
  if (((w & 0xff000010) >>> 0) === 0x54000000) return false;
  if (((w & 0xfe000000) >>> 0) === 0xd6000000) return false;
  return true;
}

function adrp(rd, pc, target) {
  const delta = Math.floor(target / PAGE) - Math.floor(pc / PAGE);
  if (delta < -(2 ** 20) || delta >= 2 ** 20) return null;
  const d = (delta + 2 ** 21) % 2 ** 21;
  return (0x90000000 + (d & 3) * 0x20000000 + Math.floor(d / 4) * 32 + rd) >>> 0;
}

function stubWords(pc, target) {
  const a = adrp(16, pc, target);
  if (a === null) return null;
  return [a, (ADD_X16_BASE | ((target % PAGE) << 10)) >>> 0, BR_X16];
}

function decodeAdrp(w, pc) {
  let imm = (((w >>> 5) & 0x7ffff) << 2) | ((w >>> 29) & 3);
  if (imm & (1 << 20)) imm -= 2 ** 21;
  return Math.floor(pc / PAGE) * PAGE + imm * PAGE;
}

function wordsToBytes(words) {
  const out = new Uint8Array(words.length * 4);
  const dv = new DataView(out.buffer);
  words.forEach((w, i) => dv.setUint32(i * 4, w >>> 0, true));
  return out;
}

function u32(bytes, at) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(at, true);
}

async function layout(read) {
  const head = await read(0, 8);
  const hdv = new DataView(head.buffer, head.byteOffset, head.byteLength);
  const magic = hdv.getUint32(0, false);
  let base = 0;
  if (magic === 0xcafebabe || magic === 0xcafebabf) {
    const is64 = magic === 0xcafebabf;
    const n = hdv.getUint32(4, false);
    const stride = is64 ? 32 : 20;
    const table = await read(8, n * stride);
    const tdv = new DataView(table.buffer, table.byteOffset, table.byteLength);
    let found = false;
    for (let i = 0; i < n; i++) {
      const o = i * stride;
      if (tdv.getUint32(o, false) === ARM64) {
        base = is64 ? Number(tdv.getBigUint64(o + 8, false)) : tdv.getUint32(o + 8, false);
        found = true;
        break;
      }
    }
    if (!found) return null;
  }
  const mh = await read(base, 32);
  const mdv = new DataView(mh.buffer, mh.byteOffset, mh.byteLength);
  if (mdv.getUint32(0, true) !== 0xfeedfacf || mdv.getUint32(4, true) !== ARM64) return null;
  const ncmds = mdv.getUint32(16, true);
  const sizeofcmds = mdv.getUint32(20, true);
  const cmds = await read(base + 32, sizeofcmds);
  const cdv = new DataView(cmds.buffer, cmds.byteOffset, cmds.byteLength);
  const segments = [];
  let p = 0;
  for (let i = 0; i < ncmds; i++) {
    const cmd = cdv.getUint32(p, true);
    const size = cdv.getUint32(p + 4, true);
    if (size < 8 || p + size > cmds.length) return null;
    if (cmd === 0x19) {
      let name = "";
      for (let k = 0; k < 16 && cmds[p + 8 + k] !== 0; k++) name += String.fromCharCode(cmds[p + 8 + k]);
      const vmaddr = Number(cdv.getBigUint64(p + 24, true));
      const vmsize = Number(cdv.getBigUint64(p + 32, true));
      const fileoff = Number(cdv.getBigUint64(p + 40, true));
      const filesize = Number(cdv.getBigUint64(p + 48, true));
      const initprot = cdv.getInt32(p + 60, true);
      const nsects = cdv.getUint32(p + 64, true);
      let usedEnd = vmaddr;
      let q = p + 72;
      for (let s = 0; s < nsects; s++) {
        const saddr = Number(cdv.getBigUint64(q + 32, true));
        const ssize = Number(cdv.getBigUint64(q + 40, true));
        usedEnd = Math.max(usedEnd, saddr + ssize);
        q += 80;
      }
      segments.push({ name, vmaddr, vmsize, fileoff: base + fileoff, filesize, initprot, usedEnd });
    }
    p += size;
  }
  return segments;
}

function vaToOff(segments, va) {
  for (const s of segments) {
    if (s.vmaddr <= va && va < s.vmaddr + Math.min(s.vmsize, s.filesize)) return s.fileoff + (va - s.vmaddr);
  }
  return null;
}

async function existingCave(read, segments, text, off) {
  const w = await read(off, 12);
  const w0 = u32(w, 0);
  const w1 = u32(w, 4);
  const w2 = u32(w, 8);
  if (((w0 & 0x9f00001f) >>> 0) !== ADRP_X16_BASE || ((w1 & 0xffc003ff) >>> 0) !== ADD_X16_BASE || w2 !== BR_X16) return false;
  const va = text.vmaddr + (off - text.fileoff);
  const cave = decodeAdrp(w0, va) + ((w1 >>> 10) & 0xfff);
  const caveOff = vaToOff(segments, cave);
  if (caveOff === null) return false;
  const c = await read(caveOff, 16);
  if (((u32(c, 0) & 0x9f00001f) >>> 0) !== ADRP_X16_BASE || ((u32(c, 4) & 0xffc003ff) >>> 0) !== LDR_X16_BASE) return false;
  return u32(c, 8) === CBZ_X16_PLUS8 && u32(c, 12) === BR_X16;
}

export async function findHookSites(read, onProgress) {
  if (new Uint8Array(new Uint32Array([1]).buffer)[0] !== 1) return { status: "unsupported" };
  const segments = await layout(read);
  if (!segments) return { status: "missing" };
  const text = segments.find((s) => s.name === "__TEXT");
  const data = segments.find((s) => s.name === "__DATA");
  if (!text || !data || !(data.initprot & 2)) return { status: "layout" };

  const targets = TARGETS.map(([, hex]) => hexWords(hex));
  const masked = targets.map((t) => Uint32Array.from(t, maskWord));
  const strict = targets.map((t) => Uint32Array.from(t, maskStrict));
  const tols = targets.map((t) => tolFor(t.length));
  const longest = Math.max(...targets.map((t) => t.length));
  const hits = targets.map(() => []);
  const end = text.fileoff + (text.filesize - (text.filesize % 4));
  for (let pos = text.fileoff; pos + longest * 4 <= end; pos += PIECE) {
    const len = Math.min(PIECE + longest * 4, end - pos);
    const buf = await read(pos, len);
    const u = new Uint32Array(buf.buffer, buf.byteOffset, len >> 2);
    const last = Math.min(PIECE >> 2, (len >> 2) - longest + 1);
    for (let i = 0; i < last; i++) {
      const m = maskWord(u[i + STUB_WORDS]);
      const m2 = maskWord(u[i + STUB_WORDS + 1]);
      for (let t = 0; t < masked.length; t++) {
        const fp = masked[t];
        if (m !== fp[STUB_WORDS] || m2 !== fp[STUB_WORDS + 1]) continue;
        let miss = 0;
        for (let k = STUB_WORDS + 2; k < fp.length; k++) {
          if (maskWord(u[i + k]) !== fp[k] && ++miss > tols[t]) break;
        }
        if (miss > tols[t]) continue;
        let sMiss = 0;
        for (let k = STUB_WORDS; k < fp.length; k++) if (maskStrict(u[i + k]) !== strict[t][k]) sMiss++;
        let pristine = true;
        for (let k = 0; k < STUB_WORDS; k++) if (u[i + k] !== targets[t][k]) pristine = false;
        hits[t].push({ offset: pos + i * 4, pristine, miss, sMiss, words: [u[i], u[i + 1], u[i + 2]] });
      }
    }
    if (onProgress) onProgress(Math.min(1, (pos - text.fileoff + len) / text.filesize));
  }

  let caveVa = Math.ceil(text.usedEnd / 16) * 16;
  const caveLimit = text.vmaddr + Math.min(text.vmsize, text.filesize);
  let slotVa = Math.ceil(data.usedEnd / 8) * 8;
  const slotLimit = data.vmaddr + data.vmsize;

  const patches = [];
  const applied = [];
  const already = [];
  const problems = [];
  for (let t = 0; t < TARGETS.length; t++) {
    const name = TARGETS[t][0];
    let found = [];
    for (const h of hits[t]) {
      if (h.pristine || (await existingCave(read, segments, text, h.offset))) found.push(h);
    }
    if (found.length > 1) {
      const rank = (h) => h.miss * 1000 + h.sMiss;
      const best = Math.min(...found.map(rank));
      found = found.filter((h) => rank(h) === best);
    }
    if (!found.length) { problems.push(name + ": not found"); continue; }
    if (found.length > 1) { problems.push(name + ": ambiguous"); continue; }
    const hit = found[0];
    if (!hit.pristine) { already.push(name); continue; }
    if (!hit.words.every(pcIndependent)) { problems.push(name + ": entry instructions are position dependent"); continue; }
    if (caveVa + CAVE_STRIDE > caveLimit) { problems.push(name + ": no room for a trampoline"); continue; }
    if (slotVa + SLOT_SIZE > slotLimit) { problems.push(name + ": no room for a hook slot"); continue; }
    const funcVa = text.vmaddr + (hit.offset - text.fileoff);
    const entry = stubWords(funcVa, caveVa);
    const caveOff = vaToOff(segments, caveVa);
    if (!entry || caveOff === null) { problems.push(name + ": trampoline out of range"); continue; }
    const area = await read(caveOff, CAVE_STRIDE);
    if (area.some((b) => b !== 0)) { problems.push(name + ": trampoline area is not empty"); continue; }
    const back = stubWords(caveVa + 28, funcVa + STUB_WORDS * 4);
    const slotAdrp = adrp(16, caveVa, slotVa);
    if (!back || slotAdrp === null) { problems.push(name + ": trampoline out of range"); continue; }
    const cave = [
      slotAdrp,
      (LDR_X16_BASE | (((slotVa % PAGE) >> 3) << 10)) >>> 0,
      CBZ_X16_PLUS8,
      BR_X16,
      ...hit.words,
      ...back,
    ];
    patches.push({ offset: caveOff, bytes: wordsToBytes(cave) });
    patches.push({ offset: hit.offset, bytes: wordsToBytes(entry) });
    applied.push(name);
    caveVa += CAVE_STRIDE;
    slotVa += SLOT_SIZE;
  }
  patches.sort((a, b) => a.offset - b.offset);
  if (patches.length) return { status: "patch", offset: patches[0].offset, patches, applied, already, problems };
  if (already.length) return { status: "already", applied, already, problems };
  return { status: "missing", applied, already, problems };
}
