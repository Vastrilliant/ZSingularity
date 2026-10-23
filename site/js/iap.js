const TARGET_HEX = [
  "d10183ffa90167faa9025ff8a90357f6a9044ff4a9057bfd910003fdaa0203f3" +
  "aa0103f49000001539549aa8370002a89000000891000108aa0003f6aa0803e0" +
  "9400000090000000910000009400000090000000910000009400000090000000" +
  "9100000094000000900000009100000094000000aa1603e05280002839149aa8" +
  "b4000a40d280000194000000b40009e090000017910002f79000001891000318" +
  "900000199100033990000016910002d6f9400008a95b8509d63f0120aa0003f5" +
  "b9000ff4f94002e0910003e194000000aa0003e2f9400300aa1503e1aa1303e3" +
  "d280000494000000f9400328b940e50934000389d280000194000000f94002c0" +
  "b940e408340004089000001339786a6836000428f94002c0b940e408340004c8" +
  "f9405c08f9400100b40005009000000891000108f9400101d2800002d2800003" +
  "94000000a9457bfda9444ff4a94357f6a9425ff8a94167fa910003ffd65f03c0" +
  "aa0003f3aa0803e094000000aa1303e0d280000194000000f94002c0b940e408" +
  "35fffc48940000009000001339786a683707fc28900000009100000094000000" +
  "5280002839386a68f94002c0b940e40835fffb8894000000f94002c0f9405c08" +
  "f9400100b5fffb4094000000",
];

const SITE_INDEX = 80;
const ANCHOR_AT = 1;
const ANCHOR_LEN = 4;
const MAX_MISMATCH = 6;
const NOP = 0xd503201f;
const PIECE = 1 << 22;
const ARM64 = 0x0100000c;
const NOP_BYTES = new Uint8Array([0x1f, 0x20, 0x03, 0xd5]);

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

export async function textRange(read) {
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
  let p = 0;
  for (let i = 0; i < ncmds; i++) {
    const cmd = cdv.getUint32(p, true);
    const size = cdv.getUint32(p + 4, true);
    if (size < 8 || p + size > cmds.length) return null;
    if (cmd === 0x19) {
      let name = "";
      for (let k = 0; k < 16 && cmds[p + 8 + k] !== 0; k++) name += String.fromCharCode(cmds[p + 8 + k]);
      if (name === "__TEXT") {
        const vmaddr = Number(cdv.getBigUint64(p + 24, true));
        const fileoff = Number(cdv.getBigUint64(p + 40, true));
        const filesize = Number(cdv.getBigUint64(p + 48, true));
        return { start: base + fileoff, size: filesize, base, vmaddr, fileoff };
      }
    }
    p += size;
  }
  return null;
}

export async function findIapSite(read, onProgress) {
  if (new Uint8Array(new Uint32Array([1]).buffer)[0] !== 1) return { status: "unsupported" };
  const range = await textRange(read);
  if (!range) return { status: "missing" };
  const fp = hexWords(TARGET_HEX[0]);
  const L = fp.length;
  const m = Uint32Array.from(fp, maskWord);
  const end = range.start + (range.size - (range.size % 4));
  const hits = [];
  for (let pos = range.start; pos + L * 4 <= end; pos += PIECE) {
    const len = Math.min(PIECE + L * 4, end - pos);
    const buf = await read(pos, len);
    const u = new Uint32Array(buf.buffer, buf.byteOffset, len >> 2);
    const last = Math.min(PIECE >> 2, (len >> 2) - L + 1);
    for (let i = 0; i < last; i++) {
      if (maskWord(u[i + ANCHOR_AT]) !== m[ANCHOR_AT]) continue;
      let ok = true;
      for (let k = 1; k < ANCHOR_LEN; k++) if (maskWord(u[i + ANCHOR_AT + k]) !== m[ANCHOR_AT + k]) { ok = false; break; }
      if (!ok) continue;
      let miss = 0;
      for (let k = 0; k < L && miss <= MAX_MISMATCH; k++) {
        if (k !== SITE_INDEX && maskWord(u[i + k]) !== m[k]) miss++;
      }
      if (miss > MAX_MISMATCH) continue;
      hits.push({ offset: pos + (i + SITE_INDEX) * 4, word: u[i + SITE_INDEX] >>> 0, miss });
    }
    if (onProgress) onProgress(Math.min(1, (pos - range.start + len) / range.size));
  }
  if (!hits.length) return { status: "missing" };
  if (hits.length > 4) return { status: "ambiguous", offset: hits[0].offset };
  const patches = [];
  let already = 0;
  let status = "missing";
  for (const hit of hits) {
    if (hit.word === NOP) { already++; continue; }
    if (hit.word >>> 26 !== 37) { status = "unexpected"; continue; }
    patches.push({ offset: hit.offset, bytes: NOP_BYTES });
  }
  if (patches.length) return { status: "patch", offset: patches[0].offset, patches };
  if (already) return { status: "already", offset: hits[0].offset };
  return { status, offset: hits[0].offset };
}
