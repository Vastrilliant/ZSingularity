import { ChunkedBuffer } from "./macho.js";
import { crc32, crc32OfBlob, dataRange, rawBlob, inflateChunks } from "./zip.js";

async function runFinders(finders, read, report, from, to) {
  const span = (to - from) / finders.length;
  const results = [];
  for (let n = 0; n < finders.length; n++) {
    const a = from + span * n;
    const r = await finders[n].find(read, (f) => report(a + f * span));
    results.push({ id: finders[n].id, ...r });
  }
  return results;
}

function collectPatches(results) {
  const all = [];
  for (const r of results) if (r.status === "patch") all.push(...r.patches);
  return all.sort((a, b) => a.offset - b.offset);
}

export async function patchFramework(ipa, entry, finders, { progress, log }) {
  const report = (f) => progress("Patching framework", f);
  if (entry.method === 0) {
    const { start, end } = await dataRange(ipa, entry);
    const src = ipa.slice(start, end);
    const results = await runFinders(finders, async (o, l) => new Uint8Array(await src.slice(o, o + l).arrayBuffer()), report, 0, 0.6);
    const patches = collectPatches(results);
    if (!patches.length) return { results, blob: null };
    const parts = [];
    let at = 0;
    for (const p of patches) {
      parts.push(src.slice(at, p.offset), p.bytes);
      at = p.offset + p.bytes.length;
    }
    parts.push(src.slice(at));
    const blob = new Blob(parts);
    const crc = await crc32OfBlob(blob, (f) => report(0.6 + f * 0.4));
    return { results, blob, crc };
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
    const results = await runFinders(finders, async (o, l) => buf.read(o, l), report, 0.3, 0.7);
    const patches = collectPatches(results);
    if (!patches.length) return { results, blob: null };
    for (const p of patches) buf.write(p.offset, p.bytes);
    let crc = 0;
    let done = 0;
    for (const c of chunks) {
      crc = crc32(crc, c);
      done += c.length;
      report(0.7 + 0.3 * (done / Math.max(1, buf.length)));
    }
    return { results, blob: new Blob(chunks), crc };
  }
  throw new Error("Unsupported compression method " + entry.method + " on the framework executable.");
}
