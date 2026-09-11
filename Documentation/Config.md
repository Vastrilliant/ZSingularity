# CONFIG
## Transcode Format

The output texture format the [Transcoder pipeline](Mods.md#the-transcode-pipeline) re-encodes modded AssetBundle textures into. Options:

- `ASTC_RGBA_4x4` — compressed, smallest block size of the ASTC options, best quality-per-byte trade-off of the compressed formats
 
- `ASTC_RGBA_6x6` — the **default** codec limbus company uses for iOS 
 
- `ASTC_RGBA_8x8` — compressed, largest ASTC block size, smallest file size, most quality loss
 
- `RGBA32` — uncompressed, highest fidelity, largest file size
 
- `ETC2` — compressed, an alternative to ASTC

**NOTE: Using codecs of higher quality will skyrocket your memory usage**

ASTC is Apple's natively supported compressed texture format on iOS; smaller block sizes (4x4) keep more detail at the cost of a larger file, while larger block sizes (8x8) shrink the file further but soften fine detail.

## FModManifest zeroing

**ZSingularity** zeroes out the network call FMOD normally uses to validate its manifest, so that swapped-in sound banks load without tripping a checksum mismatch. Disabling this toggle disarms that patch and restores FMOD's original manifest validation.

**You must disable this setting when downloading new updates**

## LZ4HC compression on dispatch

Compresses bundles into LZ4HC before being uploaded to the Transcoder pipeline to save on bandwidth. Using this setting will consume a significant amount of RAM per bundle upload - disable this if you’re crashing due to memory issues

## Enable Nightly Builds

ZSingularity will check for any new Nightly builds instead of releases in the main repository 

**NOTE: Expect instability issues when running Nighly Builds**
