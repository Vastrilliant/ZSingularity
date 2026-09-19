# MODS
The Mods section is a local library of "mod folders" — each folder holds the modded files you've imported, along with their processing status, and is where you dispatch/install/restore them from.

To access this feature, you must fork the Transcoder Proxy repository. 

[https://github.com/vastrilliant/transcoder-proxy/](https://github.com/vastrilliant/transcoder-proxy/)

To use this, you must also need to provide a PAT (personal access token), see [personal access token](Auth.md#personal-access-token)

## Load Mods

Import modded bundles taken from your mod library of choice. [NexusMods](https://www.nexusmods.com/games/limbuscompany) is recommended.

Supported Formats: 
`__data` unity asset bundles 
`.assets.bank` FMOD Sound Bank 
`Lunartique` .zip archives 
`Carra2` archives 
`Localize` .json files (custom announcers) 
Localization packs (full translations, as a folder or a .zip)

Every entry's info panel starts with a `Kind:` line telling you which of these it is.

### Localization mods

- **Localize .json files** must start with `dataList`. You'll be asked which language folder (`en`, `jp`, `kr`) to place them in; the matching language prefix (`EN_`, `JP_` or `KR_`) is prepended to each file's name (replacing any other prefix it already has), and the file replaces the game's file of that name inside the folder. It is rejected if no such file exists there.
- **Localization packs** replace an entire language folder. A folder is treated as a pack when it contains at least two of the game's localization subfolders (`BattleAnnouncerDlg`, `BgmLyrics`, `EGOVoiceDig`, `PersonalityVoiceDlg`, `RPGSystem`, `StoryData`). A .zip is accepted only if it holds nothing but the pack folder.

The original files are backed up before anything is swapped, and **Restore Originals** puts them back.

## Processing

- **Unity AssetBundles** usually can't be installed as-is — they're normally built for a different platform's texture compression, so the game won't load them until they're re-encoded. Click the upload button to dispatch it to the repo for transcoding.

## The Transcoder pipeline

Transcoding a bundle sends it to the GitHub repository configured under [Auth](Auth.md), where a GitHub Actions workflow re-encodes its textures into the format chosen under [Config → Transcode Format](Config.md).

Once a run finishes successfully, the tweak downloads the processed bundle and installs it in place of the original — the original stock bundle is backed up first (via `ZTranscoderInstaller`) so it can be restored later. Processed bundles already sitting in the configured repo from an earlier dispatch can also be listed and reinstalled directly, without re-running the Transcoder workflow.
