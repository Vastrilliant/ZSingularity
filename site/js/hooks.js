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
    "aa0003f3b003b955397422a8370003089003924091008000974fc460b00394c0"],
  ["MainUI.UserInfoCard.SetIntroductionText",
    "a9bb67faa9015ff8a90257f6a9034ff4a9047bfd910103fdaa0203f4aa0103f5" +
    "aa0003f3b003b596394596c8370001289003910091350000974de043d0038ea0"],
  ["LoadingSceneManager.SetHintText",
    "6dbb23e9a9015ff8a90257f6a9034ff4a9047bfd910103fdaa0003f39003f9d4" +
    "396006889003d575913582b5370002a8d003d580911100009770129fb003d460"],
  ["UnityEngine.Rendering.VolumeManager.Update",
    "d10303ff6d0333ed6d042beb6d0523e9a9066ffca90767faa9085ff8a90957f6" +
    "a90a4ff4a90b7bfd9102c3fdaa0303f5aa0203f6aa0103f9aa0003f7b0013f54"],
  ["MainUI.SettingsPanelEtc.Open",
    "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0003f3b003b1353958c2a8" +
    "90038cb6912942d690038a5491136294370001e8d0038a00911f0000974bb27f"],
  ["MainUI.SettingsPanelEtc.ReloadUI",
    "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0003f3b003b13439567e88" +
    "370002a890038ca091294000974bb203d0038ec091360000974bb200f0038f00"],
  ["MainUI.ShowIntegrateCodeUIPopup.SetPublicId",
    "a9be4ff4a9017bfd910043fdaa0003f3f80b8e61aa1303e0974c7418f85c0260" +
    "b4000100f9400261f9400008f942ad03f942b102a9417bfda8c24ff4d61f0060"],
  ["MainUI.ShowIntegrateCodeUIPopup.SetDataOpen",
    "d100c3ffa9014ff4a9027bfd910083fdaa0003f3f80a0c01974c7407aa1303e0" +
    "d280000197f987dfd003b2b43950e688370000c8f0038bc0911f2000974c7419"],
  ["StageStatisticPopupSlotScrollViewItem.SetData",
    "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0103f4aa0003f3d003f3b5" +
    "397cfaa8370002489003cee091268000976d08fd9003cee09126a000976d08fa"],
  ["MainUI.SelectIntegrateAccountItemObject.SetData",
    "a9bc5ff8a90157f6a9024ff4a9037bfd9100c3fdaa0103f3aa0003f49003b2d5" +
    "3950caa8370000c890038be0912e2000974c7d0d528000283910caa8f9401280"],
  ["MainUI.AskBeforeConfirmIntegratePanel.SetData",
    "d10103ffa9024ff4a9037bfd9100c3fdaa0003f4f9401000b4000240aa0103f3" +
    "3dc000203d8003e0f9400828f9000be8910003e19400000cf9401680b4000120"],
  ["LoginSceneManager.SetLoginInfo",
    "d10183ff6d0223e9a90357f6a9044ff4a9057bfd910143fdaa0003f3f003f8d4" +
    "3964ba88370004289003d1a091382000976f9c659003d1c0911a2000976f9c62"],
];

const FP_LEN = 16;

function hexWords(hex) {
  const out = new Uint32Array(hex.length / 8);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 8, i * 8 + 8), 16) >>> 0;
  return out;
}

function maskWord(w) {
  const top = w >>> 26;
  if (top === 37 || top === 5) return (w & 0xfc000000) >>> 0;
  if (((w & 0x9f000000) >>> 0) === 0x90000000) return (w & 0x9f00001f) >>> 0;
  if (((w & 0xff800000) >>> 0) === 0x91000000) return (w & 0xffc003ff) >>> 0;
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
  const hits = targets.map(() => []);
  const end = text.fileoff + (text.filesize - (text.filesize % 4));
  for (let pos = text.fileoff; pos + FP_LEN * 4 <= end; pos += PIECE) {
    const len = Math.min(PIECE + FP_LEN * 4, end - pos);
    const buf = await read(pos, len);
    const u = new Uint32Array(buf.buffer, buf.byteOffset, len >> 2);
    const last = Math.min(PIECE >> 2, (len >> 2) - FP_LEN + 1);
    for (let i = 0; i < last; i++) {
      const m = maskWord(u[i + STUB_WORDS]);
      for (let t = 0; t < masked.length; t++) {
        const fp = masked[t];
        if (m !== fp[STUB_WORDS]) continue;
        let ok = true;
        for (let k = STUB_WORDS + 1; k < FP_LEN; k++) {
          if (maskWord(u[i + k]) !== fp[k]) { ok = false; break; }
        }
        if (!ok) continue;
        let pristine = true;
        for (let k = 0; k < STUB_WORDS; k++) if (u[i + k] !== targets[t][k]) pristine = false;
        hits[t].push({ offset: pos + i * 4, pristine, words: [u[i], u[i + 1], u[i + 2]] });
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
    const found = [];
    for (const h of hits[t]) {
      if (h.pristine || (await existingCave(read, segments, text, h.offset))) found.push(h);
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
