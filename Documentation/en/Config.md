# CONFIG
## LZ4HC compression on dispatch

Compresses bundles into LZ4HC before being uploaded to the Transcoder pipeline to save on bandwidth. Using this setting will consume a significant amount of RAM per bundle upload - disable this if you’re crashing due to memory issues

## Enable Nightly Builds

ZSingularity will check for any new Nightly builds instead of releases in the main repository 

**NOTE: Expect instability issues when running Nightly Builds**
