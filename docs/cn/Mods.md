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

Unity asset bundle 会在设备上通过 astcenc + Metal compute 混合方案进行处理，并重新打包以适配 iOS
