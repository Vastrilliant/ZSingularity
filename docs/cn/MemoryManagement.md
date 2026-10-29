# 内存管理
## Entitlements

iOS 应用可以拥有两个允许其使用更多内存的 entitlement。

`com.apple.developer.kernel.increased-memory-limit` 允许应用向 iOS 请求更多内存。**该 entitlement 对内存小于 4GB 的 iPhone 无效。**

`com.apple.developer.kernel.extended-virtual-addressing` 启用 64 位虚拟地址空间，使应用能够映射大得多的地址分配。

虽然该 entitlement 本身**不会**增加物理内存，但对于需要同时映射多个巨大数据块的应用至关重要。通过扩大虚拟地址范围，它可以避免内存分配因地址空间碎片化而失败。

该 entitlement 仅适用于付费的 Apple 开发者账号。

## Extend Memory Usage

借助 app extension，ZS 可以将 IL2CPP 托管堆和 malloc 内存区域重新分配到拥有独立内存限制的 app extension 中。

这实际上让应用绕过了 Apple 的内存限制，使内存低至 3GB 的 iPhone 也能基本正常运行游戏。

请注意，这需要额外注册一个 App ID。

## Redirect minimum

筛选需要重新分配的 IL2CPP 托管内存区域。阈值越低，重新分配的内存越多，但可能会影响稳定性。

## Memory Cleanup

通过释放空闲的缓存运行时对象，来释放游戏不再使用的内存。

包括：
* 空闲的池化实例
* 缓存的 asset
* 未使用的相机 render target
* 战斗立绘
* 战斗 VFX 特效
* 备用文本材质及其他内部缓存

随后会运行两次 `GC.Collect()`。

运行时会出现短暂的卡顿。
