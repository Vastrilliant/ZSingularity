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

const FP_ADDOPTS =
  "d101c3ffa9016ffca90267faa9035ff8a90457f6a9054ff4a9067bfd910183fd" +
  "aa0103f4aa0003f3b0012e15396c72a8370001e8900108a0911ae00096091668" +
  "b0010860912cc00096091665b0010860912ce00096091662b001070091308000" +
  "9609165f52800028392c72a8b4000934b9401a887100051f540007ab52800015" +
  "b0010879912ce339b001071a9130835a4f03f6003d8003e0900108bb911ae37b";

const FP_UCHARS =
  "d10283ffa9046ffca90567faa9065ff8a90757f6a9084ff4a9097bfd910243fd" +
  "aa0003f49003c356397cb6c8d0039b9391232273f0039db5912d02b5370002a8" +
  "f0039da0912d200097540828f0039da0912d000097540825d0039b8091232000" +
  "9754082290039c20910ea0009754081fb0039c60910da0009754081cb003a100" +
  "911360009754081952800028393cb6c8";

const OPTIONAL_SPECS = new Set(["addopts", "uchars"]);

const SITE_INDEX = 23;
const GETTER_WORDS = 60;
const ICALL_ADRP_INDEX = 26;
const ICALL_ADD_INDEX = 27;
const SCAN_SPAN = 0x4000;
const PIECE = 1 << 22;
const DATA_PATH_ICALL = "UnityEngine.Application::get_dataPath";
const PERSISTENT_PATH_ICALL = "UnityEngine.Application::get_persistentDataPath";
const GC_WILD = [11, 48];
const CELL_LIST = 7;
const CELL_CTOR = 5;
const CELL_ADD = 3;
const NOP_RET0 = 0x52800000;
const RET1 = 0x52800020;
const MOV_X0_0 = 0xd2800000;
const LDP_FP_LR = 0xa9417bfd;
const RET = 0xd65f03c0;
const BL_OP = 37;
const B_OP = 5;
const LC_FUNCTION_STARTS = 0x26;
const OBJNEW_WINDOW = 0x600;
const CAVE_MAX_FUNCS = 6;

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
  if (((w & 0x3b000000) >>> 0) === 0x39000000) return (w & 0xffc003ff) >>> 0;
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

function tolFor(len) {
  return Math.min(6, Math.floor(len / 16));
}

async function scanAll(read, range, specs, onProgress) {
  const raw = specs.map(() => []);
  const longest = Math.max(...specs.map((s) => s.fp.length));
  const end = range.start + (range.size - (range.size % 4));
  for (let pos = range.start; pos + 4 <= end; pos += PIECE) {
    const len = Math.min(PIECE + longest * 4, end - pos);
    const buf = await read(pos, len);
    const u = wordsOf(buf);
    const m = new Uint32Array(u.length);
    for (let i = 0; i < u.length; i++) m[i] = maskWord(u[i]);
    const lim = Math.min(PIECE >> 2, u.length);
    for (let i = 0; i < lim; i++) {
      for (let s = 0; s < specs.length; s++) {
        const sp = specs[s];
        const fp = sp.fp;
        if (i + fp.length > m.length) continue;
        if (m[i + 1] !== fp[1] || m[i + 2] !== fp[2]) continue;
        let miss = 0;
        for (let k = 0; k < fp.length; k++) {
          if (sp.wild && sp.wild.includes(k)) continue;
          if (m[i + k] !== fp[k] && ++miss > sp.tol) break;
        }
        if (miss <= sp.tol) raw[s].push({ offset: pos + i * 4, miss });
      }
    }
    if (onProgress) onProgress(Math.min(1, (pos - range.start + len) / range.size));
  }
  return raw.map((h) => {
    if (!h.length) return [];
    const best = Math.min(...h.map((x) => x.miss));
    return h.filter((x) => x.miss === best).map((x) => x.offset);
  });
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

class Asm {
  constructor(base) {
    this.base = base;
    this.w = [];
    this.fix = [];
    this.labels = {};
  }
  pc() { return this.base + this.w.length * 4; }
  emit(x) { this.w.push(x >>> 0); }
  label(n) { this.labels[n] = this.pc(); }
  ref(n, fn) { this.fix.push({ i: this.w.length, n, fn }); this.w.push(0); }
  done() {
    for (const f of this.fix) {
      const at = this.base + f.i * 4;
      if (this.labels[f.n] === undefined) throw new Error("label " + f.n);
      this.w[f.i] = f.fn(at, this.labels[f.n]) >>> 0;
    }
    return this.w;
  }
}

const a64 = {
  stp: (rt, rt2, off) => (0xa9000000 | (((off / 8) & 0x7f) << 15) | (rt2 << 10) | (31 << 5) | rt) >>> 0,
  ldp: (rt, rt2, off) => (0xa9400000 | (((off / 8) & 0x7f) << 15) | (rt2 << 10) | (31 << 5) | rt) >>> 0,
  movw0: (r) => (0x52800000 | r) >>> 0,
  strb: (t, n, i) => (0x39000000 | (i << 10) | (n << 5) | t) >>> 0,
  movw: (d, m) => (0x2a0003e0 | (m << 16) | d) >>> 0,
  subw1: (d, n) => (0x51000400 | (n << 5) | d) >>> 0,
  ldrhPost2: (t, n) => (0x78402400 | (n << 5) | t) >>> 0,
  bcond: (cond) => (pc, va) => (0x54000000 | ((((va - pc) >> 2) & 0x7ffff) << 5) | cond) >>> 0,
  bTo: (pc, va) => enc.b(pc, va),
  cbzx: (rt) => (pc, va) => enc.cbz(rt, pc, va),
  cbzw: (rt) => (pc, va) => enc.cbzw(rt, pc, va),
};
const SEL_INTERACTABLE = 0xd8;
const SEL_GROUPS_ALLOW = 0xe8;
const COND_EQ = 0;
const COND_NE = 1;
const COND_GE = 10;

function buildOptionsCave(base, t) {
  const a = new Asm(base);
  a.emit(enc.subSp(0x40));
  a.emit(a64.stp(29, 30, 0x30));
  a.emit(a64.stp(26, 25, 0x20));
  a.emit(a64.stp(24, 23, 0x10));
  a.emit(enc.ldrx(0, 19, t.dropdownOff));
  a.emit(enc.ldrx(1, 20, 0));
  a.emit(enc.movz(2));
  a.emit(enc.bl(a.pc(), t.setOptions));
  a.emit(enc.ldrx(0, 19, t.dropdownOff));
  a.emit(0x52800028);
  a.emit(a64.strb(8, 0, SEL_INTERACTABLE));
  a.emit(a64.strb(8, 0, SEL_GROUPS_ALLOW));
  a.emit(enc.movz(0));
  a.emit(enc.bl(a.pc(), t.candidates));
  a.emit(enc.mov(23, 0));
  a.ref("done", a64.cbzx(23));
  a.emit(enc.ldrx(0, 19, t.dropdownOff));
  a.emit(enc.mov(1, 23));
  a.emit(enc.movz(2));
  a.emit(enc.bl(a.pc(), t.addOptions));
  a.emit(enc.movz(0));
  a.emit(enc.bl(a.pc(), t.lastSelected));
  a.emit(enc.mov(24, 0));
  a.emit(a64.movw0(25));
  a.ref("setv", a64.cbzx(24));
  a.emit(enc.ldrw(26, 23, 0x18));
  a.label("loop");
  a.emit(enc.cmpw(25, 26));
  a.ref("notfound", a64.bcond(COND_GE));
  a.emit(enc.ldrx(8, 23, 0x10));
  a.emit(enc.add(8, 8, 0x20));
  a.emit(enc.ldrxLsl3(9, 8, 25));
  a.emit(enc.ldrw(10, 9, 0x10));
  a.emit(enc.ldrw(11, 24, 0x10));
  a.emit(enc.cmpw(10, 11));
  a.ref("next", a64.bcond(COND_NE));
  a.emit(enc.add(12, 9, 0x14));
  a.emit(enc.add(13, 24, 0x14));
  a.label("cmp");
  a.ref("setv", a64.cbzw(10));
  a.emit(a64.ldrhPost2(14, 12));
  a.emit(a64.ldrhPost2(15, 13));
  a.emit(a64.subw1(10, 10));
  a.emit(enc.cmpw(14, 15));
  a.ref("cmp", a64.bcond(COND_EQ));
  a.label("next");
  a.emit(enc.addw1(25, 25));
  a.ref("loop", a64.bTo);
  a.label("notfound");
  a.emit(a64.movw0(25));
  a.label("setv");
  a.emit(enc.ldrx(0, 19, t.dropdownOff));
  a.emit(a64.movw(1, 25));
  a.emit(enc.movz(2));
  a.emit(enc.bl(a.pc(), t.setValue));
  a.label("done");
  a.emit(a64.ldp(24, 23, 0x10));
  a.emit(a64.ldp(26, 25, 0x20));
  a.emit(a64.ldp(29, 30, 0x30));
  a.emit(enc.addSp(0x40));
  a.emit(enc.b(a.pc(), t.resume));
  return a.done();
}

function buildOkCave(base, t) {
  const a = new Asm(base);
  a.emit(enc.subSp(0x20));
  a.emit(a64.stp(19, 30, 0x10));
  a.emit(enc.mov(19, 0));
  a.emit(enc.ldrx(8, 19, t.dropdownOff));
  a.ref("out", a64.cbzx(8));
  a.emit(enc.ldrx(0, 8, t.optionsOff));
  a.ref("out", a64.cbzx(0));
  a.emit(enc.ldrw(1, 8, t.valueOff));
  a.emit(enc.movz(2));
  a.emit(enc.bl(a.pc(), t.applyChoice));
  a.label("out");
  a.emit(enc.mov(0, 19));
  a.emit(enc.movz(1));
  a.emit(a64.ldp(19, 30, 0x10));
  a.emit(enc.addSp(0x20));
  a.emit(enc.b(a.pc(), t.close));
  return a.done();
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

function words32(buf) {
  if ((buf.byteOffset & 3) === 0) return wordsOf(buf);
  const copy = new Uint8Array(buf.length & ~3);
  copy.set(buf.subarray(0, copy.length));
  return new Uint32Array(copy.buffer);
}

function blTargetIn(u, i, at) {
  const w = u[i];
  return w >>> 26 === BL_OP ? at + i * 4 + signExtend(w & 0x3ffffff, 26) * 4 : null;
}

async function functionStarts(read, range) {
  const mh = await read(range.base, 32);
  const mdv = new DataView(mh.buffer, mh.byteOffset, mh.byteLength);
  const ncmds = mdv.getUint32(16, true);
  const sizeofcmds = mdv.getUint32(20, true);
  const cmds = await read(range.base + 32, sizeofcmds);
  const cdv = new DataView(cmds.buffer, cmds.byteOffset, cmds.byteLength);
  let p = 0;
  let dataoff = 0;
  let datasize = 0;
  for (let i = 0; i < ncmds; i++) {
    const cmd = cdv.getUint32(p, true);
    const size = cdv.getUint32(p + 4, true);
    if (size < 8 || p + size > cmds.length) return null;
    if (cmd === LC_FUNCTION_STARTS) {
      dataoff = cdv.getUint32(p + 8, true);
      datasize = cdv.getUint32(p + 12, true);
      break;
    }
    p += size;
  }
  if (!datasize) return null;
  const raw = await read(range.base + dataoff, datasize);
  const starts = [];
  let va = range.vmaddr;
  for (let i = 0; i < raw.length;) {
    let delta = 0;
    let mul = 1;
    for (;;) {
      if (i >= raw.length) return null;
      const b = raw[i++];
      delta += (b & 0x7f) * mul;
      mul *= 128;
      if (!(b & 0x80)) break;
    }
    if (delta === 0) break;
    va += delta;
    const off = va - range.vmaddr + range.fileoff + range.base;
    if (off >= range.start && off < range.start + range.size) starts.push(off);
  }
  return starts.length ? starts : null;
}

function startIndex(starts, off) {
  let lo = 0;
  let hi = starts.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (starts[mid] === off) return mid;
    if (starts[mid] < off) lo = mid + 1;
    else hi = mid - 1;
  }
  return -1;
}

function isAdrpAdd(a, b, rd) {
  return ((a & 0x9f00001f) >>> 0) === ((0x90000000 | rd) >>> 0) && ((b & 0xffc003ff) >>> 0) === ((0x91000000 | (rd << 5) | rd) >>> 0);
}

function matchObjNewBlock(u, i, at) {
  if (i + 16 > u.length) return null;
  const a = u[i] & 31;
  const b = u[i + 7] & 31;
  const c = u[i + 12] & 31;
  if (!isAdrpAdd(u[i], u[i + 1], a) || u[i + 2] !== ((0xf9400000 | (a << 5)) >>> 0)) return null;
  if (!isAdrpAdd(u[i + 7], u[i + 8], b) || u[i + 9] !== ((0xf9400000 | (b << 5)) >>> 0)) return null;
  if (!isAdrpAdd(u[i + 12], u[i + 13], c) || u[i + 14] !== ((0xf9400001 | (c << 5)) >>> 0)) return null;
  if ((u[i + 4] & 0xffffffe0) >>> 0 !== 0xaa0003e0 || (u[i + 11] & 0xffffffe0) >>> 0 !== 0xaa0003e0) return null;
  if (u[i + 5] !== 0xd2800001) return null;
  const objNew = blTargetIn(u, i + 3, at);
  const ctor0 = blTargetIn(u, i + 6, at);
  const objNew2 = blTargetIn(u, i + 10, at);
  const ctor = blTargetIn(u, i + 15, at);
  if (objNew === null || ctor0 === null || objNew2 === null || ctor === null) return null;
  if (objNew !== objNew2 || ctor === ctor0) return null;
  return { at: at + i * 4, objNew, ctor };
}

async function scanBranches(read, range, gc, cave, caveEnd, gcEnd, onProgress, extra) {
  const callers = [];
  const stray = [];
  const end = range.start + (range.size - (range.size % 4));
  for (let pos = range.start; pos + 4 <= end; pos += PIECE) {
    const len = Math.min(PIECE, end - pos);
    const u = words32(await read(pos, len));
    for (let i = 0; i < u.length; i++) {
      const top = u[i] >>> 26;
      if (top !== BL_OP && top !== B_OP) continue;
      const at = pos + i * 4;
      const target = at + signExtend(u[i] & 0x3ffffff, 26) * 4;
      if (top === BL_OP && target === gc) callers.push(at);
      if (extra && target >= extra.start && target < extra.end && !(at >= extra.start && at < extra.end)) extra.stray.push(at);
      if (target >= cave && target < caveEnd && !(at >= cave && at < caveEnd)) {
        if (!(target === cave && at >= gc && at < gcEnd)) stray.push(at);
      }
    }
    if (onProgress) onProgress(Math.min(1, (pos - range.start + len) / range.size));
  }
  return { callers, stray };
}

async function findObjNew(read, callers) {
  const found = [];
  for (const caller of callers) {
    const u = words32(await read(caller, OBJNEW_WINDOW));
    for (let i = 0; i + 16 <= u.length; i++) {
      const m = matchObjNewBlock(u, i, caller);
      if (m) found.push(m);
    }
  }
  const uniq = new Map();
  for (const f of found) uniq.set(f.objNew + ":" + f.ctor, f);
  return [...uniq.values()];
}

function initCells(words, base, toVa) {
  const out = [];
  for (let i = 0; i + 2 < words.length; i++) {
    const a = words[i];
    const b = words[i + 1];
    const c = words[i + 2];
    if (((a & 0x9f00001f) >>> 0) === 0x90000000 && ((b & 0xffc003ff) >>> 0) === 0x91000000 && c >>> 26 === BL_OP) {
      const pc = toVa(base + i * 4);
      const imm = signExtend((((a >>> 5) & 0x7ffff) << 2) | ((a >>> 29) & 3), 21) * 4096;
      const shift = (b >>> 22) & 1 ? 4096 : 1;
      out.push(pc - (pc % 4096) + imm + ((b >>> 10) & 0xfff) * shift);
    }
  }
  return out;
}

const DROPDOWN_FIELD = 0xf9401660;
const HOOK_STR_OPTIONS = 0xf8010e95;

async function planDropdown(c) {
  const { read, toVa, starts, idx, one, extra } = c;
  const fnEnd = (off) => starts[startIndex(starts, off) + 1];
  const wordsAt = async (off) => words32(await read(off, fnEnd(off) - off));
  let addopts = one.addopts;
  if (!addopts && c.multi.addopts) {
    const want = c.gcCells[6];
    const pick = [];
    for (const h of c.multi.addopts) {
      const cells = initCells(words32(await read(h, fnEnd(h) - h)), h, toVa);
      if (cells.includes(want)) pick.push(h);
    }
    if (pick.length === 1) addopts = pick[0];
  }
  if (!addopts) return { status: "skip", stage: "addoptions" };
  if (!one.uchars) return { status: "skip", stage: "space" };
  const uc = one.uchars;
  const ucEnd = fnEnd(uc);
  if (extra.stray.length) return { status: "skip", stage: "space-live", offset: extra.stray[0] };
  if (ucEnd - uc < 0x180) return { status: "skip", stage: "space-size" };

  const lo = Math.max(0, idx.get - 4);
  const hi = Math.min(starts.length - 2, idx.get + 14);
  const funcs = [];
  for (let k = lo; k <= hi; k++) funcs.push({ off: starts[k], words: await wordsAt(starts[k]) });
  const calls = (f, target) => {
    for (let i = 0; i < f.words.length; i++) if (blTargetIn(f.words, i, f.off) === target) return true;
    return false;
  };
  const slsList = funcs.filter((f) => f.off !== one.get && f.off !== one.gbls && calls(f, one.gbls));
  if (slsList.length !== 1) return { status: "skip", stage: "select-fn" };
  const sls = slsList[0].off;
  const b0List = funcs.filter((f) => f.off !== sls && calls(f, sls));
  if (b0List.length !== 1) return { status: "skip", stage: "changed-fn" };
  const b0 = b0List[0].off;

  let sdo = null;
  for (const f of funcs) {
    for (let i = 0; i + 1 < f.words.length; i++) {
      if (blTargetIn(f.words, i, f.off) === one.get && blTargetIn(f.words, i + 1, f.off) === one.gc) {
        if (sdo) return { status: "skip", stage: "setdata-dup" };
        sdo = f;
      }
    }
  }
  if (!sdo) return { status: "skip", stage: "setdata" };
  const w = sdo.words;
  let hook = -1;
  let hooked = false;
  for (let i = 4; i + 10 <= w.length; i++) {
    const isCbz = (x) => ((x & 0xff00001f) >>> 0) === 0xb4000000;
    const rest =
      w[i - 4] === HOOK_STR_OPTIONS &&
      w[i] === DROPDOWN_FIELD &&
      isCbz(w[i + 1]) &&
      w[i + 3] === 0xd2800002 &&
      w[i + 4] >>> 26 === BL_OP &&
      w[i + 5] === DROPDOWN_FIELD &&
      isCbz(w[i + 6]) &&
      w[i + 7] === 0x52800001 &&
      w[i + 8] === 0xd2800002 &&
      w[i + 9] >>> 26 === BL_OP;
    if (!rest) continue;
    if (w[i + 2] === 0xf9400281) { hook = i; break; }
    if (w[i + 2] >>> 26 === B_OP) { hook = i; hooked = true; break; }
  }
  if (hook < 0) return { status: "skip", stage: "setdata-shape" };
  if (hooked) return { status: "already" };

  const setOptions = blTargetIn(w, hook + 4, sdo.off);
  const setValue = blTargetIn(w, hook + 9, sdo.off);
  const so = words32(await read(setOptions, 24));
  const optionsOff = (((so[4] >>> 10) & 0xfff) * 8) | 0;
  if (((so[4] & 0xffc003ff) >>> 0) !== 0xf9400000 || optionsOff < 0x20 || optionsOff > 0x400) return { status: "skip", stage: "options-field" };
  const gv = words32(await read(setValue - 8, 8));
  const valueOff = ((gv[0] >>> 10) & 0xfff) * 4;
  if (((gv[0] & 0xffc003ff) >>> 0) !== 0xb9400000 || gv[1] !== RET || valueOff < 0x20 || valueOff > 0x400) return { status: "skip", stage: "value-field" };

  const gls = starts[idx.gd + 1];
  const glsEnd = fnEnd(gls);
  const glsWords = words32(await read(gls, glsEnd - gls));
  if (glsEnd - gls < 0x40 || glsEnd - gls > 0xc0 || glsWords[0] !== 0xa9be4ff4 || !glsWords.includes(0xf9400800) || !glsWords.includes(RET)) return { status: "skip", stage: "last-selected" };

  const okFn = starts[idx.gc + 2];
  const closeFn = starts[idx.gc + 3];
  if (fnEnd(okFn) - okFn !== 4 || (await rdWordAt(read, okFn)) !== RET) return { status: "skip", stage: "ok-fn" };
  if (fnEnd(starts[idx.gc + 1]) - starts[idx.gc + 1] !== 8 || fnEnd(closeFn) - closeFn < 0x40) return { status: "skip", stage: "close-fn" };

  const base = toVa(uc);
  const optT = {
    dropdownOff: 0x28,
    setOptions: toVa(setOptions),
    candidates: toVa(one.gc),
    addOptions: toVa(addopts),
    lastSelected: toVa(gls),
    setValue: toVa(setValue),
    resume: toVa(sdo.off + (hook + 10) * 4),
  };
  const optWords = buildOptionsCave(base, optT);
  const okBase = base + optWords.length * 4;
  const okWords = buildOkCave(okBase, {
    dropdownOff: 0x28,
    optionsOff,
    valueOff,
    applyChoice: toVa(b0),
    close: toVa(closeFn),
  });
  if ((optWords.length + okWords.length) * 4 > ucEnd - uc) return { status: "skip", stage: "space-fit" };
  const hookAt = sdo.off + (hook + 2) * 4;
  return {
    status: "patch",
    patches: [
      { offset: uc, bytes: wordBytes(optWords.concat(okWords)) },
      { offset: hookAt, bytes: wordBytes([enc.b(toVa(hookAt), base)]) },
      { offset: okFn, bytes: wordBytes([enc.b(toVa(okFn), okBase)]) },
    ],
  };
}

async function rdWordAt(read, off) {
  return words32(await read(off, 4))[0] >>> 0;
}

export async function findLocalizeSite(read, onProgress) {
  if (new Uint8Array(new Uint32Array([1]).buffer)[0] !== 1) return { status: "unsupported" };
  const range = await textRange(read);
  if (!range) return { status: "missing" };
  const toVa = (off) => range.vmaddr + (off - range.fileoff - range.base);
  const rdWord = async (off) => words32(await read(off, 4))[0] >>> 0;
  const blTarget = async (off) => {
    const w = await rdWord(off);
    return w >>> 26 === BL_OP ? off + signExtend(w & 0x3ffffff, 26) * 4 : null;
  };
  const specs = [
    { id: "gd", hex: FINGERPRINT_HEX },
    { id: "gc", hex: FP_GC, wild: GC_WILD },
    { id: "get", hex: FP_GET },
    { id: "gbls", hex: FP_GBLS },
    { id: "gfn", hex: FP_GFN },
    { id: "add", hex: FP_ADD },
    { id: "addopts", hex: FP_ADDOPTS },
    { id: "uchars", hex: FP_UCHARS },
  ].map((sp) => {
    const fp = Array.from(hexWords(sp.hex), maskWord);
    return { id: sp.id, fp, wild: sp.wild, tol: tolFor(fp.length) };
  });
  const hits = await scanAll(read, range, specs, (f) => onProgress && onProgress(f * 0.6));
  const one = {};
  const multi = {};
  for (let i = 0; i < specs.length; i++) {
    const optional = OPTIONAL_SPECS.has(specs[i].id);
    if (hits[i].length === 0) {
      if (optional) continue;
      return { status: "missing", stage: specs[i].id };
    }
    if (hits[i].length > 1) {
      if (optional) {
        multi[specs[i].id] = hits[i];
        continue;
      }
      return { status: "ambiguous", stage: specs[i].id, count: hits[i].length };
    }
    one[specs[i].id] = hits[i][0];
  }
  const path = await pathPatch(read, range, one.gd);
  if (path.status !== "patch" && path.status !== "already") return path;

  const starts = await functionStarts(read, range);
  if (!starts) return { status: "unexpected", stage: "funcstarts" };
  const idx = {};
  for (const k of ["gd", "gc", "get", "gbls"]) {
    idx[k] = startIndex(starts, one[k]);
    if (idx[k] < 0) return { status: "unexpected", stage: "start-" + k, offset: one[k] };
  }
  const fnEnd = (off) => starts[startIndex(starts, off) + 1];
  const gc = one.gc;
  const gcEnd = fnEnd(gc);
  const gcWords = words32(await read(gc, gcEnd - gc));
  const cells = [];
  for (let i = 0; i + 2 < gcWords.length; i++) {
    const a = gcWords[i];
    const b = gcWords[i + 1];
    const c = gcWords[i + 2];
    if (((a & 0x9f00001f) >>> 0) === 0x90000000 && ((b & 0xffc003ff) >>> 0) === 0x91000000 && c >>> 26 === BL_OP) {
      const pc = toVa(gc + i * 4);
      const imm = signExtend((((a >>> 5) & 0x7ffff) << 2) | ((a >>> 29) & 3), 21) * 4096;
      const shift = (b >>> 22) & 1 ? 4096 : 1;
      cells.push(pc - (pc % 4096) + imm + ((b >>> 10) & 0xfff) * shift);
    }
  }
  if (cells.length !== 9) return { status: "unexpected", stage: "cells", offset: gc };

  const noneKey = starts[idx.gd - 1];
  const dirs = starts[idx.gd - 2];
  let headIdx = idx.gd - 3;
  if (starts[headIdx] === gc || starts[headIdx] === one.get) headIdx--;
  const head = starts[headIdx];
  const dirsWords = words32(await read(dirs, noneKey - dirs));
  let dirsCalls = 0;
  for (let i = 0; i < dirsWords.length; i++) if (blTargetIn(dirsWords, i, dirs) === one.gd) dirsCalls++;
  if (dirsCalls < 1) return { status: "unexpected", stage: "dirs", offset: dirs };
  if (one.gd - noneKey > 0x100 || noneKey - dirs < 0x20) return { status: "unexpected", stage: "nonekey", offset: noneKey };
  const headOrig = await rdWord(head);
  if (fnEnd(head) - head !== 8 || (headOrig !== NOP_RET0 && headOrig !== RET1) || (await rdWord(head + 4)) !== RET) return { status: "unexpected", stage: "isrunning", offset: head };

  const sites = [];
  let epilogueAt = -1;
  const caveProbe = buildCave(0, { dirs: 0, noneKey: 0, objNew: 0, ctor: 0, add: 0, fileName: 0, listClass: 0, ctorInfo: 0, addInfo: 0, epilogue: 0 });
  const needBytes = caveProbe.length * 4;
  let caveIdx = headIdx;
  while (head - starts[caveIdx] < needBytes) {
    caveIdx--;
    if (caveIdx < 0 || headIdx - caveIdx > CAVE_MAX_FUNCS) return { status: "unexpected", stage: "cave", offset: head };
  }
  const cave = starts[caveIdx];
  const caveWords = head - cave >> 2;
  for (let i = 0; i + 1 < gcWords.length; i++) {
    const w = gcWords[i];
    const isSite = w === MOV_X0_0 || w >>> 26 === B_OP && gc + i * 4 + signExtend(w & 0x3ffffff, 26) * 4 === cave;
    if (isSite && gcWords[i + 1] === LDP_FP_LR) {
      sites.push(gc + i * 4);
      if (epilogueAt < 0) epilogueAt = gc + (i + 1) * 4;
    }
  }
  if (!sites.length || epilogueAt < 0) return { status: "unexpected", stage: "isrunning-sites", offset: gc };

  const extra = one.uchars ? { start: one.uchars, end: fnEnd(one.uchars), stray: [] } : null;
  const scan = await scanBranches(read, range, gc, cave, head, gcEnd, (f) => onProgress && onProgress(0.6 + f * 0.35), extra);
  if (scan.stray.length) return { status: "unexpected", stage: "cave-live", offset: scan.stray[0] };
  const blocks = await findObjNew(read, scan.callers);
  if (blocks.length !== 1) return { status: blocks.length ? "ambiguous" : "missing", stage: "objnew", count: blocks.length };
  const objNew = blocks[0].objNew;
  const ctor = blocks[0].ctor;

  const getEnd = fnEnd(one.get);
  const getWords = words32(await read(one.get, getEnd - one.get));
  const getSites = [];
  for (let i = 0; i + 1 < getWords.length; i++) {
    if (((getWords[i] & 0xffc003ff) >>> 0) === 0x910003e8 && getWords[i + 1] >>> 26 === BL_OP) getSites.push(one.get + (i + 1) * 4);
  }
  if (getSites.length !== 1) return { status: "unexpected", stage: "get", offset: one.get };
  const getSite = getSites[0];
  const emptyInited = await blTarget(getSite);
  const gblsWords = words32(await read(one.gbls, fnEnd(one.gbls) - one.gbls));
  let gblsOk = false;
  for (let i = 0; i < gblsWords.length; i++) if (blTargetIn(gblsWords, i, one.gbls) === emptyInited) gblsOk = true;
  const alreadyGet = emptyInited === one.gbls;
  if (!alreadyGet && !gblsOk) return { status: "unexpected", stage: "get", offset: getSite };

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
    epilogue: toVa(epilogueAt),
  };
  const words = buildCave(toVa(cave), t);
  if (words.length > caveWords) return { status: "unexpected", stage: "cave", offset: cave };
  while (words.length < caveWords) words.push(0xd4200000);
  const wanted = [{ offset: cave, bytes: wordBytes(words) }];
  for (const s of sites) wanted.push({ offset: s, bytes: wordBytes([enc.b(toVa(s), toVa(cave))]) });
  wanted.push({ offset: head, bytes: wordBytes([RET1]) });
  wanted.push({ offset: getSite, bytes: wordBytes([enc.bl(toVa(getSite), toVa(one.gbls))]) });
  if (path.status === "patch") wanted.push(...path.patches);
  let dropdown = { status: "skip", stage: "space" };
  if (extra) {
    try {
      dropdown = await planDropdown({ read, toVa, starts, idx, one, extra, multi, gcCells: cells });
    } catch (e) {
      dropdown = { status: "skip", stage: "error" };
    }
  }
  if (dropdown.status === "patch") wanted.push(...dropdown.patches);
  const needed = [];
  for (const p of wanted) {
    const cur = await read(p.offset, p.bytes.length);
    if (!sameBytes(cur, p.bytes)) needed.push(p);
  }
  if (!needed.length) return { status: "already", offset: gc, dropdown: dropdown.status === "patch" ? "applied" : dropdown.stage || dropdown.status };
  return { status: "patch", offset: gc, dropdown: dropdown.status === "patch" ? "applied" : dropdown.stage || dropdown.status, patches: needed.sort((a, b) => a.offset - b.offset) };
}
