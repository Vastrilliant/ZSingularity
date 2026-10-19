import { textRange } from "./iap.js";

const FINGERPRINT_HEX =
  "a9bc5ff8a90157f6a9024ff4a9037bfd910003fdaa0003f39000001439400288" +
  "90000015910002b536000488f94002b690000017394002e89000001491000294" +
  "3600058890000017910002f7f9400280b940000834000628d280000094000000" +
  "aa0003f4f94002b5f94002e0b94000083500004894000000f100029f9a9402a0" +
  "f100027f9a9302c1d280000294000000aa0003f3d2800001940000007100001f" +
  "9a9f1260a9437bfda9424ff4a94157f6a8c45ff8d65f03c09000000091000000" +
  "940000009000000091000000940000005280002839000288f94002b690000017" +
  "394002e890000014910002943707fac890000000910000009400000052800028" +
  "390002e890000017910002f7f9400280b940000835fffa289400000014000000";

const FP_GC =
  "a9be4ff4a9017bfd910003fd9000001339400268900000149100029436000108" +
  "f9400280b9400008340004a8d2800000a9417bfda8c24ff4d65f03c090000000" +
  "9100000094000000900000009100000094000000900000009100000094000000" +
  "9000000091000000940000009000000091000000940000009000000091000000" +
  "9400000090000000910000009400000090000000910000009400000090000000" +
  "91000000940000005280002839000268f9400280b940000835fffba894000000" +
  "d2800000a9417bfda8c24ff4d65f03c0";

const FP_GET =
  "d10183ffa90357f6a9044ff4a9057bfd910003fdaa0803f390000015394002a8" +
  "9000001491000294360002c8f9400280b940000834000488f94000083940010a" +
  "b94000097100055f540004c13500008994000000f9400288f9400108ad400500" +
  "ad0006603dc009003d800a60a9457bfda9444ff4a94357f6910003ffd65f03c0" +
  "9000000091000000940000009000000091000000940000009000000091000000" +
  "9400000090000000910000009400000052800028390002a8f9400280b9400008" +
  "35fffbc894000000f9400280f94000083940010ab94000097100055f54fffb80" +
  "3500004994000000910003e894000000ad4007e0ad0006603dc00be03d800a60" +
  "f9400280b94000083500006894000000f9400280f9400008ad4007e03dc00be2" +
  "ad0089013d800100f9400288f940010891000100d280000194000000a9457bfd" +
  "a9444ff4a94357f6910003ffd65f03c0";

const FP_GBLS =
  "d10303ffa9066ffca90767faa9085ff8a90957f6a90a4ff4a90b7bfd910003fd" +
  "aa0803f390000014394002889000001b9100037b360001e8a9057ffff90003ff" +
  "f9400360b9400008340005e8900000143940028836000608f9400360b9400008";

const FP_GFN =
  "a9be4ff4a9017bfd910003fdaa0003f39000001439400288370000c890000000" +
  "91000000940000005280002839000288b4000513b9400268340004c890000014" +
  "91000294f9400280b94000083500006894000000f9400280f9400008f9400101" +
  "aa1303e0d2800002940000003100041f54000381f9400280b9400008340001a8" +
  "f9400008f9400101aa1303e0d28000029400000037f801e011000401aa1303e0";

const FP_ADD =
  "b940000811000508b9000008f9400008b40001c8b9800009b940010a6b0a013f" +
  "540000c21100052ab900000a8b090d00f8020c0114000000f9400048f9400108" +
  "f940010214000000a9bf7bfd910003fd94000000a9bd57f6a9014ff4a9027bfd" +
  "910003fdf9400008b40003a8b9800014";

const FP_SDO =
  "94000000aa0003f4f9400275f94002c0b940000834000228aa1503e0d2800001" +
  "d28000029400000035000240b4000054b9400294f9400260f94002c8b9400109" +
  "34000c29d2800001d28000029400000035000ca01400000094000000aa1503e0" +
  "d2800001d28000029400000034fffe009000000891000108f940010094000000" +
  "aa0003f9d2800001940000009000000891000108f940010094000000aa0003f7" +
  "9000000891000108f940010194000000b4002139aa1903f5f8010eb7aa1503e0" +
  "aa1703e194000000b4001374f90003f9b94002887100051f54001aab52800017" +
  "5280001990000016910002d614000000f9400108f9400108f9400102aa1b03e0" +
  "aa1a03e19400000011000739b94002886b08033f540018ea";

const SITE_INDEX = 23;
const GETTER_WORDS = 60;
const ICALL_ADRP_INDEX = 26;
const ICALL_ADD_INDEX = 27;
const SCAN_SPAN = 0x4000;
const PIECE = 1 << 22;
const DATA_PATH_ICALL = "UnityEngine.Application::get_dataPath";
const PERSISTENT_PATH_ICALL = "UnityEngine.Application::get_persistentDataPath";
const GC_WILD = [11, 48];
const CAVE_BACK = 0x12c;
const CAVE_ROOM = (CAVE_BACK - 8) / 4;
const GET_SITE_BYTES = 0x2d49490 - 0x2d493a4;
const SDO_NEW = 31;
const SDO_CTOR = 43;
const CELL_LIST = 7;
const CELL_CTOR = 5;
const CELL_ADD = 3;
const NOP_RET0 = 0x52800000;
const RET1 = 0x52800020;
const MOV_X0_0 = 0xd2800000;

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
  if (((w & 0x3f000000) >>> 0) === 0x39000000) return (w & 0xffc003ff) >>> 0;
  return w >>> 0;
}

function signExtend(v, bits) {
  return v >= 2 ** (bits - 1) ? v - 2 ** bits : v;
}

function wordsOf(buf) {
  return new Uint32Array(buf.buffer, buf.byteOffset, buf.byteLength >> 2);
}

async function icallName(read, range, func) {
  const head = await read(func + ICALL_ADRP_INDEX * 4, 8);
  const dv = new DataView(head.buffer, head.byteOffset, 8);
  const adrp = dv.getUint32(0, true);
  const add = dv.getUint32(4, true);
  if (((adrp & 0x9f000000) >>> 0) !== 0x90000000 || ((add & 0xff800000) >>> 0) !== 0x91000000) return null;
  const pc = range.vmaddr + (func + ICALL_ADRP_INDEX * 4 - range.fileoff - range.base);
  const imm = signExtend((((adrp >>> 5) & 0x7ffff) << 2) | ((adrp >>> 29) & 3), 21) * 4096;
  const shift = (add >>> 22) & 1 ? 4096 : 1;
  const va = pc - (pc % 4096) + imm + ((add >>> 10) & 0xfff) * shift;
  const off = va - range.vmaddr + range.fileoff + range.base;
  if (off < range.start || off + 96 > range.start + range.size) return null;
  const bytes = await read(off, 96);
  let name = "";
  for (let i = 0; i < bytes.length && bytes[i] !== 0; i++) name += String.fromCharCode(bytes[i]);
  return name;
}

async function findPersistentGetter(read, range, getter) {
  const span = Math.min(SCAN_SPAN + GETTER_WORDS * 4, range.start + range.size - getter);
  const buf = await read(getter, span);
  const u = wordsOf(buf);
  const shape = Array.from(u.subarray(0, GETTER_WORDS), maskWord);
  const found = [];
  const last = (u.length - GETTER_WORDS) | 0;
  for (let i = 1; i <= last; i++) {
    let ok = true;
    for (let k = 0; k < GETTER_WORDS; k++) {
      if (maskWord(u[i + k]) !== shape[k]) { ok = false; break; }
    }
    if (!ok) continue;
    const name = await icallName(read, range, getter + i * 4);
    if (name !== null && name.startsWith(PERSISTENT_PATH_ICALL)) found.push(getter + i * 4);
  }
  return found;
}

function matchAt(m, i, fp, wild) {
  for (let k = 1; k < fp.length; k++) {
    if (wild && wild.includes(k)) continue;
    if (m[i + k] !== fp[k]) return false;
  }
  return true;
}

async function scanAll(read, range, specs, onProgress) {
  const hits = specs.map(() => []);
  const longest = Math.max(...specs.map((s) => s.fp.length));
  const end = range.start + (range.size - (range.size % 4));
  for (let pos = range.start; pos + 4 <= end; pos += PIECE) {
    const len = Math.min(PIECE + longest * 4, end - pos);
    const raw = await read(pos, len);
    const u = wordsOf(raw);
    const m = new Uint32Array(u.length);
    for (let i = 0; i < u.length; i++) m[i] = maskWord(u[i]);
    const lim = Math.min(PIECE >> 2, u.length);
    for (let i = 0; i < lim; i++) {
      for (let s = 0; s < specs.length; s++) {
        const sp = specs[s];
        if (m[i] !== sp.fp[0] || i + sp.fp.length > m.length) continue;
        if (matchAt(m, i, sp.fp, sp.wild)) hits[s].push(pos + i * 4);
      }
    }
    if (onProgress) onProgress(Math.min(1, (pos - range.start + len) / range.size));
  }
  return hits;
}

const enc = {
  subSp: (n) => (0xd10003ff | (n << 10)) >>> 0,
  addSp: (n) => (0x910003ff | (n << 10)) >>> 0,
  movz: (r) => (0xd2800000 | r) >>> 0,
  mov: (d, m) => (0xaa0003e0 | (m << 16) | d) >>> 0,
  adrp: (r, pc, va) => {
    const imm = Math.floor(va / 4096) - Math.floor(pc / 4096);
    return (0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5) | r) >>> 0;
  },
  add: (d, n, i) => (0x91000000 | (i << 10) | (n << 5) | d) >>> 0,
  addw1: (d, n) => (0x11000400 | (n << 5) | d) >>> 0,
  ldrx: (t, n, i) => (0xf9400000 | ((i / 8) << 10) | (n << 5) | t) >>> 0,
  ldrw: (t, n, i) => (0xb9400000 | ((i / 4) << 10) | (n << 5) | t) >>> 0,
  strw: (t, n, i) => (0xb9000000 | ((i / 4) << 10) | (n << 5) | t) >>> 0,
  ldrxLsl3: (t, n, m) => (0xf8607800 | (m << 16) | (n << 5) | t) >>> 0,
  cmpw: (n, m) => (0x6b00001f | (m << 16) | (n << 5)) >>> 0,
  bl: (pc, va) => (0x94000000 | (((va - pc) >> 2) & 0x3ffffff)) >>> 0,
  b: (pc, va) => (0x14000000 | (((va - pc) >> 2) & 0x3ffffff)) >>> 0,
  cbz: (rt, pc, va) => (0xb4000000 | ((((va - pc) >> 2) & 0x7ffff) << 5) | rt) >>> 0,
  cbzw: (rt, pc, va) => (0x34000000 | ((((va - pc) >> 2) & 0x7ffff) << 5) | rt) >>> 0,
  blt: (pc, va) => (0x5400000b | ((((va - pc) >> 2) & 0x7ffff) << 5)) >>> 0,
};

function buildCave(base, t) {
  const w = [];
  const pc = () => base + w.length * 4;
  const loadCell = (reg, va) => {
    w.push(enc.adrp(8, pc(), va));
    w.push(enc.add(8, 8, va & 0xfff));
    w.push(enc.ldrx(reg, 8, 0));
  };
  w.push(enc.subSp(0x20));
  w.push(enc.movz(0));
  w.push(enc.bl(pc(), t.dirs));
  w.push(enc.mov(20, 0));
  loadCell(0, t.listClass);
  w.push(enc.bl(pc(), t.objNew));
  w.push(enc.mov(19, 0));
  loadCell(1, t.ctorInfo);
  w.push(enc.mov(0, 19));
  w.push(enc.bl(pc(), t.ctor));
  const fixCbz = w.length;
  w.push(0);
  w.push(enc.ldrw(8, 20, 0x18));
  const fixCbzw = w.length;
  w.push(0);
  w.push(enc.strw(8, 31, 8));
  w.push(enc.movz(0));
  w.push(enc.bl(pc(), t.noneKey));
  w.push(enc.mov(1, 0));
  w.push(enc.mov(0, 19));
  loadCell(2, t.addInfo);
  w.push(enc.bl(pc(), t.add));
  w.push(enc.strw(31, 31, 0));
  const loop = pc();
  w.push(enc.ldrw(9, 31, 0));
  w.push(enc.add(8, 20, 0x20));
  w.push(enc.ldrxLsl3(0, 8, 9));
  w.push(enc.movz(1));
  w.push(enc.bl(pc(), t.fileName));
  w.push(enc.mov(1, 0));
  w.push(enc.mov(0, 19));
  loadCell(2, t.addInfo);
  w.push(enc.bl(pc(), t.add));
  w.push(enc.ldrw(9, 31, 0));
  w.push(enc.addw1(9, 9));
  w.push(enc.strw(9, 31, 0));
  w.push(enc.ldrw(8, 31, 8));
  w.push(enc.cmpw(9, 8));
  w.push(enc.blt(pc(), loop));
  const done = pc();
  w.push(enc.mov(0, 19));
  w.push(enc.addSp(0x20));
  w.push(enc.b(pc(), t.epilogue));
  w[fixCbz] = enc.cbz(20, base + fixCbz * 4, done);
  w[fixCbzw] = enc.cbzw(8, base + fixCbzw * 4, done);
  return w;
}

function wordBytes(words) {
  const out = new Uint8Array(words.length * 4);
  const dv = new DataView(out.buffer);
  words.forEach((x, i) => dv.setUint32(i * 4, x >>> 0, true));
  return out;
}

function sameBytes(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

async function pathPatch(read, range, hit) {
  const site = hit + SITE_INDEX * 4;
  const word = wordsOf(await read(site, 4))[0] >>> 0;
  if (word >>> 26 !== 37) return { status: "unexpected", offset: site };
  const target = site + signExtend(word & 0x3ffffff, 26) * 4;
  const name = await icallName(read, range, target);
  if (name !== null && name.startsWith(PERSISTENT_PATH_ICALL)) return { status: "already", offset: site };
  if (name === null || !name.startsWith(DATA_PATH_ICALL)) return { status: "unexpected", offset: site };
  const getters = await findPersistentGetter(read, range, target);
  if (getters.length !== 1) return { status: getters.length ? "ambiguous" : "missing", offset: site, count: getters.length };
  const delta = (getters[0] - site) / 4;
  if (delta < -(2 ** 25) || delta >= 2 ** 25) return { status: "unexpected", offset: site };
  return { status: "patch", offset: site, patches: [{ offset: site, bytes: wordBytes([(0x94000000 | (delta & 0x3ffffff)) >>> 0]) }] };
}

export async function findLocalizeSite(read, onProgress) {
  if (new Uint8Array(new Uint32Array([1]).buffer)[0] !== 1) return { status: "unsupported" };
  const range = await textRange(read);
  if (!range) return { status: "missing" };
  const toVa = (off) => range.vmaddr + (off - range.fileoff - range.base);
  const toOff = (va) => va - range.vmaddr + range.fileoff + range.base;
  const rdWord = async (off) => wordsOf(await read(off, 4))[0] >>> 0;
  const blTarget = async (off) => {
    const w = await rdWord(off);
    return w >>> 26 === 37 ? off + signExtend(w & 0x3ffffff, 26) * 4 : null;
  };
  const specs = [
    { id: "gd", fp: Array.from(hexWords(FINGERPRINT_HEX), maskWord) },
    { id: "gc", fp: Array.from(hexWords(FP_GC), maskWord), wild: GC_WILD },
    { id: "get", fp: Array.from(hexWords(FP_GET), maskWord) },
    { id: "gbls", fp: Array.from(hexWords(FP_GBLS), maskWord) },
    { id: "gfn", fp: Array.from(hexWords(FP_GFN), maskWord) },
    { id: "add", fp: Array.from(hexWords(FP_ADD), maskWord) },
    { id: "sdo", fp: Array.from(hexWords(FP_SDO), maskWord) },
  ];
  const hits = await scanAll(read, range, specs, onProgress);
  const one = {};
  for (let i = 0; i < specs.length; i++) {
    if (hits[i].length === 0) return { status: "missing", stage: specs[i].id };
    if (hits[i].length > 1) return { status: "ambiguous", stage: specs[i].id, count: hits[i].length };
    one[specs[i].id] = hits[i][0];
  }
  const path = await pathPatch(read, range, one.gd);
  if (path.status !== "patch" && path.status !== "already") return path;
  const gc = one.gc;
  const cells = [];
  const gcWords = wordsOf(await read(gc, 0xd0));
  for (let i = 0; i + 2 < gcWords.length; i++) {
    const a = gcWords[i];
    const b = gcWords[i + 1];
    const c = gcWords[i + 2];
    if (((a & 0x9f00001f) >>> 0) === 0x90000000 && ((b & 0xffc003ff) >>> 0) === 0x91000000 && c >>> 26 === 37) {
      const pc = toVa(gc + i * 4);
      const imm = signExtend((((a >>> 5) & 0x7ffff) << 2) | ((a >>> 29) & 3), 21) * 4096;
      const shift = (b >>> 22) & 1 ? 4096 : 1;
      cells.push(pc - (pc % 4096) + imm + ((b >>> 10) & 0xfff) * shift);
    }
  }
  if (cells.length !== 9) return { status: "unexpected", stage: "cells", offset: gc };
  const head = await rdWord(gc - 8);
  const tail = await rdWord(gc - 4);
  if ((head !== NOP_RET0 && head !== RET1) || tail !== 0xd65f03c0) return { status: "unexpected", stage: "isrunning", offset: gc };
  const dirs = gc + 0xd0;
  const noneKey = dirs + 0x11c;
  const dirsCall = await blTarget(dirs + (0x2d48610 - 0x2d485b4));
  if (dirsCall !== one.gd) return { status: "unexpected", stage: "dirs", offset: dirs };
  if (noneKey + 0x44 !== one.gd) return { status: "unexpected", stage: "nonekey", offset: noneKey };
  const objNew = await blTarget(one.sdo + SDO_NEW * 4);
  const ctor = await blTarget(one.sdo + SDO_CTOR * 4);
  const getCall = await blTarget(one.sdo);
  if (objNew === null || ctor === null || getCall !== gc) return { status: "unexpected", stage: "donor", offset: one.sdo };
  const getSite = one.get + GET_SITE_BYTES;
  const emptyInited = await blTarget(getSite);
  const gblsBytes = wordsOf(await read(one.gbls, 0x7c4));
  let gblsOk = false;
  const getBlWord = await rdWord(getSite);
  const gblsNow = getBlWord >>> 26 === 37 ? getSite + signExtend(getBlWord & 0x3ffffff, 26) * 4 : null;
  for (let i = 0; i < gblsBytes.length; i++) {
    if (gblsBytes[i] >>> 26 === 37 && one.gbls + i * 4 + signExtend(gblsBytes[i] & 0x3ffffff, 26) * 4 === emptyInited) gblsOk = true;
  }
  const alreadyGet = gblsNow === one.gbls;
  if (!alreadyGet && !gblsOk) return { status: "unexpected", stage: "get", offset: getSite };
  const cave = gc - CAVE_BACK;
  const t = {
    dirs: toVa(dirs),
    noneKey: toVa(noneKey),
    objNew: toVa(objNew),
    ctor: toVa(ctor),
    add: toVa(one.add),
    fileName: toVa(one.gfn),
    listClass: cells[CELL_LIST],
    ctorInfo: cells[CELL_CTOR],
    addInfo: cells[CELL_ADD],
    epilogue: toVa(gc + 0x30),
  };
  const caveWords = buildCave(toVa(cave), t);
  if (caveWords.length > CAVE_ROOM) return { status: "unexpected", stage: "cave", offset: cave };
  while (caveWords.length < CAVE_ROOM) caveWords.push(0xd4200000);
  const wanted = [
    { offset: cave, bytes: wordBytes(caveWords) },
    { offset: gc + 0x2c, bytes: wordBytes([enc.b(toVa(gc + 0x2c), toVa(cave))]) },
    { offset: gc + 0xc0, bytes: wordBytes([enc.b(toVa(gc + 0xc0), toVa(cave))]) },
    { offset: gc - 8, bytes: wordBytes([RET1]) },
    { offset: getSite, bytes: wordBytes([enc.bl(toVa(getSite), toVa(one.gbls))]) },
  ];
  if (path.status === "patch") wanted.push(...path.patches);
  const needed = [];
  for (const p of wanted) {
    const cur = await read(p.offset, p.bytes.length);
    if (!sameBytes(cur, p.bytes)) needed.push(p);
  }
  if (!needed.length) return { status: "already", offset: gc };
  return { status: "patch", offset: gc, patches: needed.sort((a, b) => a.offset - b.offset) };
}
