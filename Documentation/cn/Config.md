# CONFIG
## Transcode Format

[Transcoder pipeline](Mods.md#the-transcode-pipeline) 重新编码 modded AssetBundle 纹理时使用的输出纹理格式。选项:

- `ASTC_RGBA_4x4` — 压缩格式中 ASTC 最小的块大小，在压缩格式中提供最佳的质量/文件大小平衡。
- `ASTC_RGBA_6x6` — **Limbus Company 在 iOS 上使用的默认编解码器**。
- `ASTC_RGBA_8x8` — 最大的 ASTC 块大小，文件最小，但质量损失也最大。
- `RGBA32` — 未压缩，保真度最高，文件最大。
- `ETC2` — 压缩格式，是 ASTC 的一种替代方案。

**注意: 使用更高质量的编解码器会让内存使用量急剧增加。**

ASTC 是 Apple 在 iOS 上原生支持的压缩纹理格式。较小的块大小（4x4）能保留更多细节，但文件更大；较大的块大小（8x8）能进一步缩小文件，但会使细节变得柔和。

## LZ4HC compression on dispatch

在上传到 Transcoder pipeline 之前使用 LZ4HC 压缩 bundle，以节省带宽。此设置会在每次上传 bundle 时消耗大量 RAM；如果因内存问题发生崩溃，请将其禁用。

## Enable Nightly Builds

让 ZSingularity 检查主仓库中的新 Nightly 构建，而不是 releases。

**注意: 运行 Nightly Builds 时可能会出现不稳定问题。**
