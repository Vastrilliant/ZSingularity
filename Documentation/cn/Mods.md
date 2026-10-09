# MODS
Mods 部分是一个本地的“mod 文件夹”库。每个文件夹都包含你导入的 mod 文件及其处理状态，并可从这里派发、安装或恢复。

## 加载 Mods

从你喜欢的 mod 库导入修改后的 bundle。推荐使用 [NexusMods](https://www.nexusmods.com/games/limbuscompany)。

支持的格式：
`__data` Unity AssetBundle
`.assets.bank` FMOD Sound Bank
`Lunartique` .zip 压缩包
`Carra2` 存档
`*.json` 本地化文件
`translation` 翻译包

## 处理

- **Unity AssetBundle** 通常不能直接安装。它们通常使用其他平台的纹理压缩方式构建，因此必须重新编码后游戏才能加载。现在 tweak 会直接在设备上转码符合条件的 bundle。

## 转码流程

设备端转码器会读取导入的 bundle 和游戏原始 bundle，匹配对应的 assets，并将需要的纹理重新编码为 ASTC 6x6。不再需要 GitHub 仓库、PAT 或远程 workflow。

转码完成后，处理后的 bundle 会立即替换原文件并安装。原始 bundle 会先由 `ZTranscoderInstaller` 备份，以便之后恢复。

