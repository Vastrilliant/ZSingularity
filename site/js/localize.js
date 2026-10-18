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

const SITE_INDEX = 23;
const GETTER_WORDS = 60;
const ICALL_ADRP_INDEX = 26;
const ICALL_ADD_INDEX = 27;
const SCAN_SPAN = 0x4000;
const PIECE = 1 << 22;
const DATA_PATH_ICALL = "UnityEngine.Application::get_dataPath";
const PERSISTENT_PATH_ICALL = "UnityEngine.Application::get_persistentDataPath";

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

export async function findLocalizeSite(read, onProgress) {
  if (new Uint8Array(new Uint32Array([1]).buffer)[0] !== 1) return { status: "unsupported" };
  const range = await textRange(read);
  if (!range) return { status: "missing" };
  const fp = Array.from(hexWords(FINGERPRINT_HEX), maskWord);
  const L = fp.length;
  const end = range.start + (range.size - (range.size % 4));
  const hits = [];
  for (let pos = range.start; pos + L * 4 <= end; pos += PIECE) {
    const len = Math.min(PIECE + L * 4, end - pos);
    const buf = await read(pos, len);
    const u = wordsOf(buf);
    const last = Math.min(PIECE >> 2, (len >> 2) - L + 1);
    for (let i = 0; i < last; i++) {
      if (maskWord(u[i]) !== fp[0]) continue;
      let ok = true;
      for (let k = 1; k < L; k++) {
        if (maskWord(u[i + k]) !== fp[k]) { ok = false; break; }
      }
      if (ok) hits.push(pos + i * 4);
    }
    if (onProgress) onProgress(Math.min(1, (pos - range.start + len) / range.size));
  }
  if (hits.length === 0) return { status: "missing" };
  if (hits.length > 1) return { status: "ambiguous", count: hits.length };
  const site = hits[0] + SITE_INDEX * 4;
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
  const w = (0x94000000 | (delta & 0x3ffffff)) >>> 0;
  const bytes = new Uint8Array([w & 0xff, (w >>> 8) & 0xff, (w >>> 16) & 0xff, (w >>> 24) & 0xff]);
  return { status: "patch", offset: site, patches: [{ offset: site, bytes }] };
}
