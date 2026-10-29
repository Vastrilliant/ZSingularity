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

Unity asset bundles are processed on-device with an astcenc + metal compute hybrid and repackaged to work for iOS
