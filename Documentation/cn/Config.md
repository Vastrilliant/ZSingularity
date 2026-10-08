# CONFIG
## LZ4HC compression on dispatch

在上传到 Transcoder pipeline 之前使用 LZ4HC 压缩 bundle，以节省带宽。此设置会在每次上传 bundle 时消耗大量 RAM；如果因内存问题发生崩溃，请将其禁用。

## Enable Nightly Builds

让 ZSingularity 检查主仓库中的新 Nightly 构建，而不是 releases。

**注意: 运行 Nightly Builds 时可能会出现不稳定问题。**
