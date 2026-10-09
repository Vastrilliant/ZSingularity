# MODS
The Mods section is a local library of "mod folders" — each folder holds the modded files you have imported, along with their processing status, and is where you dispatch/install/restore them from.

## Load Mods

Import modded bundles taken from your mod library of choice. [NexusMods](https://www.nexusmods.com/games/limbuscompany) is recommended.

Supported Formats: 
`__data` unity asset bundles 
`.assets.bank` FMOD Sound Bank 
`Lunartique` .zip archives 
`Carra2` archives 
`*.json` localization files 
`translation` packages

## Processing

- **Unity AssetBundles** usually can't be installed as-is — they're normally built for a different platform's texture compression, so the game won't load them until they're re-encoded. The tweak now transcodes eligible bundles locally on-device.

## The Transcoder pipeline

The on-device transcoder reads the imported bundle and the game's stock bundle, matches the relevant assets, and re-encodes the required textures to ASTC 6x6. No GitHub repository, PAT, or remote workflow is required.

Once transcoding finishes, the processed bundle is installed immediately in place of the original. The original stock bundle is backed up first (via `ZTranscoderInstaller`) so it can be restored later.

