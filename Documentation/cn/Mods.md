# MODS
Mods 部分是一个本地 "mod folders" 库。每个文件夹都包含你导入的 mod 文件及其处理状态，你可以从这里发送、安装或恢复它们。

要使用此功能，你必须 fork Transcoder Proxy 仓库。

[https://github.com/vastrilliant/transcoder-proxy/](https://github.com/vastrilliant/transcoder-proxy/)

你还需要提供 PAT (personal access token)。请参阅 [personal access token](Auth.md#personal-access-token)。

## Load Mods

导入从你选择的 mod 库中获取的 modded bundle。推荐使用 [NexusMods](https://www.nexusmods.com/games/limbuscompany)。

支持格式:
`__data` unity asset bundles
`.assets.bank` FMOD Sound Bank
`Lunartique` .zip archives
`Carra2` archives
`*.json` localization files 
`translation` packages

## Processing

- **Unity AssetBundles** 通常不能直接安装。它们通常是针对其他平台的纹理压缩方式构建的，因此在重新编码之前游戏无法加载它们。点击上传按钮，将其发送到 repo 进行 transcoding。

## The Transcoder pipeline

对 bundle 进行 transcoding 会将其发送到 [Auth](Auth.md) 中配置的 GitHub 仓库，GitHub Actions workflow 会根据 [Config → Transcode Format](Config.md) 中选择的格式重新编码其纹理。

运行成功后，tweak 会下载处理后的 bundle 并替换原始 bundle 进行安装。原始 stock bundle 会先通过 `ZTranscoderInstaller` 备份，因此之后可以恢复。
