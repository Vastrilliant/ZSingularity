import { parsePlist, serializePlist } from "./plist.js";
import { readZip, dataRange, rawBlob, readEntryBytes, inflateChunks, crc32, crc32OfBlob, ZipWriter, unixAttr } from "./zip.js";
import { patchMachO, ChunkedBuffer } from "./macho.js";
import { patchIapPopup } from "./iap.js";

const TRUE_KEYS = [
  "CADisableMinimumFrameDuration",
  "CADisableMinimumFrameDurationOnPhone",
  "LSSupportsGameMode",
  "LSSupportsOpeningDocumentsInPlace",
  "UIFileSharingEnabled",
];
const LOCATION_KEYS = ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription"];
const LOCATION_TEXT = "Used by the Keep Alive developer tool to prevent suspension during testing.";
const DYLIB_NAME = "ZSingularity.dylib";
const DYLIB_REF = "@executable_path/Frameworks/" + DYLIB_NAME;
const UNITY_FRAMEWORK = "/Frameworks/UnityFramework.framework/UnityFramework";

function metaOf(e) {
  return { versionMadeBy: e.versionMadeBy, time: e.time, date: e.date, intAttr: e.intAttr, extAttr: e.extAttr };
}

export async function inject(ipa, payload, opts = {}) {
  const progress = opts.onProgress || (() => {});
  const log = opts.onLog || (() => {});
  const warnings = [];
  progress("Reading IPA", 0);
  const zip = await readZip(ipa);
  const nDirs = zip.entries.filter((e) => e.isDir).length;
  const totalUsize = zip.entries.reduce((n, e) => n + (e.usize || 0), 0);
  log("Zip: " + zip.entries.length + " entries (" + nDirs + " dirs, " + (zip.entries.length - nDirs) + " files), central directory at " + zip.cdOffset + ", uncompressed total " + totalUsize + " bytes");
  const plistEntry = zip.entries.find((e) => /^Payload\/[^/]+\.app\/Info\.plist$/i.test(e.name));
  if (!plistEntry) throw new Error("No Payload/<App>.app/Info.plist found. Is this a valid .ipa?");
  const appDir = plistEntry.name.replace(/\/Info\.plist$/i, "");
  log("App bundle: " + appDir + " \u00b7 Info.plist method " + plistEntry.method + ", " + plistEntry.usize + " bytes");

  progress("Patching Info.plist", 0);
  const parsed = parsePlist(await readEntryBytes(ipa, plistEntry));
  const root = parsed.root;
  log("Info.plist format: " + parsed.format);
  const gameVersion = root.get("CFBundleShortVersionString");
  const appId = root.get("CFBundleIdentifier");
  const exeName = root.get("CFBundleExecutable");
  if (!gameVersion) throw new Error("CFBundleShortVersionString is missing from the game's Info.plist.");
  if (!appId || !exeName) throw new Error("CFBundleIdentifier or CFBundleExecutable is missing from Info.plist.");
  log("Bundle: id " + appId + " \u00b7 executable " + exeName + " \u00b7 version " + gameVersion + " \u00b7 build " + root.get("CFBundleVersion") + " \u00b7 min iOS " + root.get("MinimumOSVersion"));
  for (const k of TRUE_KEYS) {
    log("Info.plist " + k + ": " + JSON.stringify(root.get(k)) + " -> true");
    root.set(k, true);
  }
  for (const k of LOCATION_KEYS) {
    log("Info.plist " + k + ": " + (root.get(k) === undefined ? "(unset)" : "(was set)") + " -> set");
    root.set(k, LOCATION_TEXT);
  }
  log("Info.plist UIBackgroundModes: " + JSON.stringify(root.get("UIBackgroundModes")) + " -> [\"location\"]");
  root.set("UIBackgroundModes", ["location"]);
  const plistBytes = serializePlist(root, parsed.format);
  log("Info.plist re-serialized: " + plistBytes.length + " bytes");

  const exeEntry = zip.entries.find((e) => e.name === appDir + "/" + exeName);
  if (!exeEntry) throw new Error("Main executable " + exeName + " not found in the app bundle.");

  log("Executable: " + exeEntry.name + " \u00b7 method " + exeEntry.method + " (" + (exeEntry.method === 0 ? "stored" : exeEntry.method === 8 ? "deflate" : "unsupported") + ") \u00b7 " + exeEntry.csize + " compressed / " + exeEntry.usize + " uncompressed bytes");
  progress("Patching executable", 0);
  let exeBlob = null;
  let exeCrc = 0;
  let machInfo;
  if (exeEntry.method === 0) {
    const { start, end } = await dataRange(ipa, exeEntry);
    const src = ipa.slice(start, end);
    machInfo = await patchMachO(async (o, l) => new Uint8Array(await src.slice(o, o + l).arrayBuffer()), DYLIB_REF);
    logMach(machInfo, log);
    checkMach(machInfo, warnings);
    if (machInfo.patches.length) {
      const patches = [...machInfo.patches].sort((a, b) => a.offset - b.offset);
      const parts = [];
      let at = 0;
      for (const p of patches) {
        parts.push(src.slice(at, p.offset), p.bytes);
        at = p.offset + p.bytes.length;
      }
      parts.push(src.slice(at));
      exeBlob = new Blob(parts);
      exeCrc = await crc32OfBlob(exeBlob, (f) => progress("Patching executable", f));
      log("Executable rebuilt from " + parts.length + " parts, " + exeBlob.size + " bytes, crc32 " + (exeCrc >>> 0).toString(16).padStart(8, "0"));
    }
  } else if (exeEntry.method === 8) {
    const raw = await rawBlob(ipa, exeEntry);
    const chunks = [];
    let got = 0;
    await inflateChunks(raw, (c) => {
      chunks.push(c);
      got += c.length;
      progress("Patching executable", Math.min(0.5, (got / Math.max(1, exeEntry.usize)) * 0.5));
    });
    log("Inflated executable: " + chunks.length + " chunks, " + got + " bytes");
    const buf = new ChunkedBuffer(chunks);
    machInfo = await patchMachO(async (o, l) => buf.read(o, l), DYLIB_REF);
    logMach(machInfo, log);
    checkMach(machInfo, warnings);
    if (machInfo.patches.length) {
      for (const p of machInfo.patches) buf.write(p.offset, p.bytes);
      let crc = 0;
      let done = 0;
      for (const c of chunks) {
        crc = crc32(crc, c);
        done += c.length;
        progress("Patching executable", 0.5 + 0.5 * (done / Math.max(1, buf.length)));
      }
      exeCrc = crc;
      exeBlob = new Blob(chunks);
      log("Executable rebuilt from " + chunks.length + " chunks, " + exeBlob.size + " bytes, crc32 " + (exeCrc >>> 0).toString(16).padStart(8, "0"));
    } else log("No Mach-O patches needed, executable left untouched");
  } else throw new Error("Unsupported compression method " + exeEntry.method + " on the main executable.");

  let iap = null;
  let iapStatus = "skipped";
  if (opts.patchIap !== false) {
    const fwEntry = zip.entries.find((e) => e.name === appDir + UNITY_FRAMEWORK);
    if (!fwEntry) {
      iapStatus = "no-framework";
      log("UnityFramework not found in the app bundle, skipping the purchase popup patch");
      warnings.push("UnityFramework was not found, so the launch purchase error popup was not suppressed.");
    } else {
      progress("Patching framework", 0);
      log("Framework: " + fwEntry.name + " \u00b7 method " + fwEntry.method + " \u00b7 " + fwEntry.csize + " compressed / " + fwEntry.usize + " uncompressed bytes");
      const r = await patchIapPopup(ipa, fwEntry, { progress, log });
      iapStatus = r.status;
      if (r.status === "patch") {
        iap = { entry: fwEntry, blob: r.blob, crc: r.crc };
        iapStatus = "patched";
        log("Purchase popup patch applied @ offset " + r.offset + " (0x" + r.offset.toString(16) + "), framework rebuilt to " + r.blob.size + " bytes, crc32 " + (r.crc >>> 0).toString(16).padStart(8, "0"));
      } else if (r.status === "already") log("Purchase popup patch already present, framework left untouched");
      else {
        log("Purchase popup patch not applied: " + r.status + (r.count ? " (" + r.count + " matches)" : ""));
        warnings.push("This game build's purchase code did not match the expected layout (" + r.status + "), so the launch purchase error popup was not suppressed.");
      }
    }
  }

  let appex = null;
  if (opts.embedAppex !== false && payload.appex) {
    log("Extension archive: " + payload.appex.size + " bytes");
    const azip = await readZip(payload.appex);
    const list = azip.entries.filter((e) => !e.isDir && !e.name.startsWith("__MACOSX/") && !e.name.endsWith(".DS_Store") && !e.name.includes("/_CodeSignature/"));
    const infoEntry = list.find((e) => /^[^/]+\.appex\/Info\.plist$/i.test(e.name));
    if (!infoEntry) throw new Error("The extension archive has no <name>.appex/Info.plist.");
    const bundleDir = infoEntry.name.replace(/\/Info\.plist$/i, "");
    const bundleName = bundleDir.replace(/\.appex$/i, "");
    const aParsed = parsePlist(await readEntryBytes(azip.blob, infoEntry));
    const aExe = aParsed.root.get("CFBundleExecutable");
    log("Extension: " + bundleDir + " \u00b7 " + list.length + " files \u00b7 executable " + aExe + " \u00b7 id " + aParsed.root.get("CFBundleIdentifier") + " -> " + appId + "." + bundleName + " \u00b7 plist format " + aParsed.format);
    aParsed.root.set("CFBundleIdentifier", appId + "." + bundleName);
    appex = { azip, list, infoEntry, bundleDir, aExe, infoBytes: serializePlist(aParsed.root, aParsed.format) };
  }

  const dylibDest = appDir + "/Frameworks/" + DYLIB_NAME;
  const dropped = { dylib: 0, signature: 0, plugin: 0 };
  const drop = (e) => {
    if (e.name === dylibDest) { dropped.dylib++; log("Dropping existing " + e.name); return true; }
    if (e.name.startsWith(appDir + "/_CodeSignature/")) { dropped.signature++; return true; }
    if (appex && e.name.startsWith(appDir + "/PlugIns/" + appex.bundleDir + "/")) { dropped.plugin++; return true; }
    return false;
  };

  progress("Writing IPA", 0);
  const w = new ZipWriter({ zip64Threshold: opts.zip64Threshold, forceZip64Directory: opts.forceZip64Directory });
  const sorted = [...zip.entries].sort((a, b) => a.localOffset - b.localOffset);
  let i = 0;
  let copied = 0;
  for (const e of sorted) {
    i++;
    if (drop(e)) continue;
    if (e === plistEntry) { w.addStored(e.name, plistBytes, crc32(0, plistBytes), metaOf(e)); log("Wrote patched " + e.name); }
    else if (e === exeEntry && exeBlob) { w.addStored(e.name, exeBlob, exeCrc, metaOf(e)); log("Wrote patched " + e.name); }
    else if (iap && e === iap.entry) { w.addStored(e.name, iap.blob, iap.crc, metaOf(e)); log("Wrote patched " + e.name); }
    else { w.copyVerbatim(ipa, e); copied++; }
    if (i % 256 === 0) progress("Writing IPA", i / sorted.length);
  }
  log("Copied " + copied + " entries verbatim; dropped " + dropped.signature + " signature files, " + dropped.plugin + " stale plugin files, " + dropped.dylib + " existing dylib");
  const dylibCrc = crc32(0, payload.dylib);
  w.addStored(dylibDest, payload.dylib, dylibCrc, { extAttr: unixAttr(0o755) });
  log("Wrote " + dylibDest + " (" + payload.dylib.length + " bytes, crc32 " + (dylibCrc >>> 0).toString(16).padStart(8, "0") + ", mode 755)");
  if (appex) {
    for (const ae of appex.list) {
      const dest = appDir + "/PlugIns/" + ae.name;
      if (ae === appex.infoEntry) {
        w.addStored(dest, appex.infoBytes, crc32(0, appex.infoBytes), { extAttr: unixAttr(0o644) });
        continue;
      }
      const isExe = appex.aExe && ae.name === appex.bundleDir + "/" + appex.aExe;
      const mode = isExe ? 0o755 : (ae.extAttr >>> 16) & 0o777 || 0o644;
      log("Wrote " + dest + " (method " + ae.method + ", " + ae.usize + " bytes, mode " + mode.toString(8) + ")");
      const raw = await rawBlob(appex.azip.blob, ae);
      w.addEntry(
        { name: dest, method: ae.method, crc: ae.crc, csize: ae.csize, usize: ae.usize, time: ae.time, date: ae.date, extAttr: unixAttr(mode) },
        raw
      );
    }
  } else if (opts.embedAppex !== false) warnings.push("No memory donor extension was supplied, so RamBypass will be unavailable.");
  log("Finalizing zip: " + w.central.length + " central directory entries");
  const blob = w.finish();
  progress("Done", 1);
  return {
    blob,
    gameVersion,
    appId,
    exeName,
    appDir,
    arch: machInfo.slices.map((s) => s.arch),
    alreadyInjected: machInfo.slices.every((s) => s.already),
    embeddedAppex: !!appex,
    iapStatus,
    warnings,
  };
}

function logMach(m, log) {
  log("Mach-O: " + m.slices.length + " slice(s), " + m.patches.length + " patch(es)");
  m.slices.forEach((s, n) => {
    log("  slice " + n + ": " + s.arch + " \u00b7 cryptid " + s.cryptid + " \u00b7 already injected " + s.already + " \u00b7 patches " + s.patches.length);
    for (const p of s.patches) log("    patch @ offset " + p.offset + " (0x" + p.offset.toString(16) + "), " + p.bytes.length + " bytes");
  });
}

function checkMach(m, warnings) {
  for (const s of m.slices) {
    if (s.cryptid !== 0) throw new Error("This IPA is still FairPlay-encrypted (App Store build). Use a decrypted IPA.");
  }
  if (!m.slices.some((s) => s.arch === "arm64")) warnings.push("The main executable has no arm64 slice.");
  if (m.slices.every((s) => s.already)) warnings.push("The executable already loads ZSingularity; the dylib was just replaced.");
}
