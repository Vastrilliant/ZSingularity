import { ChunkedBuffer } from "./macho.js";
import { crc32, crc32OfBlob, dataRange, rawBlob, inflateChunks } from "./zip.js";

const FINGERPRINT_HEX =
  "d10143ffa9015ff8a90257f6a9034ff4a9047bfd910003fdaa0003f390000014" +
  "3940d28837000308900000009100000094000000900000009100000094000000" +
  "9000000091000000940000009000000091000000940000009000000091000000" +
  "9400000090000000910000009400000090000000910000009400000052800028" +
  "3900d28890000016910002d6f90007ffb9400268340006489000000891000108" +
  "f9401274f940010094000000aa0003f5900000173940d6e8370000c890000000" +
  "9100000094000000528000283900d6e89000000891000108f9400101aa1503e0" +
  "94000000b4001054f8010e95aa1403e0aa1503e194000000f9400280b40003c0" +
  "90000015910002b5f94002a194000000b40004a0f94002a1f940000879425d09" +
  "b4000129f940590a9100014af85f814beb01017f540006009100014af1000529" +
  "54ffff61aa0003f45280002294000000aa0003e8aa1403e014000000f9401668" +
  "f90007e8f900167f12800008b9000268140000009000000891000108f9400100" +
  "b940e40835000048940000009000000891000108f9400100d280000194000000" +
  "14000000f9400294b4000ab49000000891000108f9400101f940028879425d09" +
  "b4000129f940590a9100014af85f814beb01017f540006209100014af1000529" +
  "54ffff61aa1403e0528000029400000014000000b9400149110005298b29d108" +
  "91000108a9400509d63f0120b4000740d280000194000000f90007e0910003e0" +
  "d280000194000000360000a0910003e0d28000019400000014000000b900027f" +
  "f94007e8aa1303e0f8028c08d280000194000000f94002c0b940e40835000048" +
  "940000009000000891000108f940010391000260910003e1aa1303e294000000" +
  "a9447bfda9434ff4a94257f6a9415ff8910003ffd65f03c0b98001498b091108" +
  "91000100a9400408aa1403e0d63f010012800028b8008668f94002c0b940e408" +
  "3500004894000000aa1303e0d280000194000000a9447bfda9434ff4a94257f6" +
  "a9415ff8910003ffd65f03c09400000014000000940000001400000094000000" +
  "1400000014000000140000001400000014000000140000001400000014000000" +
  "14000000aa0003f47100043f54000541aa1403e094000000aa0003f490000000" +
  "9100000094000000f9400288f940010194000000340002a0f940029494000000" +
  "12800028b8008668900000009100000094000000b940e4083500004894000000" +
  "aa1303e0aa1403e1d280000294000000a9447bfda9434ff4a94257f6a9415ff8" +
  "910003ffd65f03c05280010094000000f9400288f90000089000000191000021" +
  "d280000294000000d4200020aa0003f494000000aa1403e09400000094000000";

const SITE_INDEX = 103;
const SITE_PRELUDE = 0xd2800001;
const NOP = 0xd503201f;
const PIECE = 1 << 22;
const ARM64 = 0x0100000c;

function fingerprintWords() {
  const out = new Uint32Array(FINGERPRINT_HEX.length / 8);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(FINGERPRINT_HEX.slice(i * 8, i * 8 + 8), 16) >>> 0;
  return out;
}

function maskWord(w) {
  const top = w >>> 26;
  if (top === 37 || top === 5) return (w & 0xfc000000) >>> 0;
  if (((w & 0x9f000000) >>> 0) === 0x90000000) return (w & 0x9f00001f) >>> 0;
  if (((w & 0xff800000) >>> 0) === 0x91000000) return (w & 0xffc003ff) >>> 0;
  return w >>> 0;
}

async function textRange(read) {
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
        const fileoff = Number(cdv.getBigUint64(p + 40, true));
        const filesize = Number(cdv.getBigUint64(p + 48, true));
        return { start: base + fileoff, size: filesize };
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
  const fp = fingerprintWords();
  const L = fp.length;
  const end = range.start + (range.size - (range.size % 4));
  const hits = [];
  for (let pos = range.start; pos + L * 4 <= end; pos += PIECE) {
    const len = Math.min(PIECE + L * 4, end - pos);
    const buf = await read(pos, len);
    const u = new Uint32Array(buf.buffer, buf.byteOffset, len >> 2);
    const last = Math.min(PIECE >> 2, (len >> 2) - L + 1);
    for (let i = 0; i < last; i++) {
      if (maskWord(u[i]) !== fp[0]) continue;
      let ok = true;
      for (let k = 1; k < L; k++) {
        if (k === SITE_INDEX) continue;
        if (maskWord(u[i + k]) !== fp[k]) { ok = false; break; }
      }
      if (ok) hits.push({ offset: pos + (i + SITE_INDEX) * 4, original: u[i + SITE_INDEX] >>> 0, prelude: u[i + SITE_INDEX - 1] >>> 0 });
    }
    if (onProgress) onProgress(Math.min(1, (pos - range.start + len) / range.size));
  }
  if (hits.length === 0) return { status: "missing" };
  if (hits.length > 1) return { status: "ambiguous", count: hits.length };
  const h = hits[0];
  if (h.original === NOP) return { status: "already", offset: h.offset };
  if (h.original >>> 26 !== 37 || h.prelude !== SITE_PRELUDE) return { status: "unexpected", offset: h.offset };
  return { status: "patch", offset: h.offset };
}

export const NOP_BYTES = new Uint8Array([0x1f, 0x20, 0x03, 0xd5]);

export async function patchIapPopup(ipa, entry, { progress, log }) {
  const report = (f) => progress("Patching framework", f);
  if (entry.method === 0) {
    const { start, end } = await dataRange(ipa, entry);
    const src = ipa.slice(start, end);
    const result = await findIapSite(async (o, l) => new Uint8Array(await src.slice(o, o + l).arrayBuffer()), (f) => report(f * 0.6));
    if (result.status !== "patch") return { ...result, blob: null };
    const blob = new Blob([src.slice(0, result.offset), NOP_BYTES, src.slice(result.offset + 4)]);
    const crc = await crc32OfBlob(blob, (f) => report(0.6 + f * 0.4));
    return { ...result, blob, crc };
  }
  if (entry.method === 8) {
    const raw = await rawBlob(ipa, entry);
    const chunks = [];
    let got = 0;
    await inflateChunks(raw, (c) => {
      chunks.push(c);
      got += c.length;
      report(Math.min(0.3, (got / Math.max(1, entry.usize)) * 0.3));
    });
    log("Inflated framework executable: " + chunks.length + " chunks, " + got + " bytes");
    const buf = new ChunkedBuffer(chunks);
    const result = await findIapSite(async (o, l) => buf.read(o, l), (f) => report(0.3 + f * 0.4));
    if (result.status !== "patch") return { ...result, blob: null };
    buf.write(result.offset, NOP_BYTES);
    let crc = 0;
    let done = 0;
    for (const c of chunks) {
      crc = crc32(crc, c);
      done += c.length;
      report(0.7 + 0.3 * (done / Math.max(1, buf.length)));
    }
    return { ...result, blob: new Blob(chunks), crc };
  }
  throw new Error("Unsupported compression method " + entry.method + " on the framework executable.");
}
