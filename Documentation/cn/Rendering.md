# RENDERING
## Render Scale

游戏的渲染分辨率比例。

取值范围为 0 到 1.00。游戏自身的设置菜单只提供以下预设范围:

- Low = 0.50
- Medium = 0.75
- High = 1.00

请注意，在游戏运行过程中降低 Render Scale 很少会带来明显的内存减少；必须重启游戏才能完全生效。

## Battle RS 

**Battle Render Scale** 的缩写。

通过 `isBattle=1`，ZSingularity 可以检测战斗是否正在进行，并将分辨率降低到指定值。

## AP RS Mult

**Adaptive Performance Render Scale Multiplier** 的缩写。

这是一种替代的 render scale 方法，主要用于 Android (AOS) 版本。它通过 Unity 的 Adaptive Performance 系统工作，而不是普通的引擎 render scale pipeline。

取值范围为 0 到 2.00，并将该值乘到 Adaptive Performance 原本自行选择的 render scale 上。

将其设置为默认值 1.00 以外的任何值都会自动启用 Adaptive Performance，因为 multiplier 只有在 Adaptive Performance 正在主动控制 render scale 时才有效。

**注意: 此设置极不稳定。不要在战斗中修改此值，否则游戏会冻结；也不要将其设置为 0.00，这同样会导致游戏冻结。**

## Texture MIP

内部称为 Texture Mipmap Limit。

mipmap 是随主纹理附带的一组预计算优化图像。序列中的每张后续图像，其分辨率（宽和高）都恰好是前一张的一半。引擎会根据纹理当前在屏幕上的绘制大小选择最合适的级别，因此远处或较小的纹理不需要采样完整分辨率的图像。

mipmap limit 只影响包含生成 mip map level 的 `Texture2D` asset；这些 asset 还必须具有以下属性:

```
int m_MipMapsStripped = 0
int m_MipCount = 1+
bool m_IgnoreMipmapsLimit = false
bool m_StreamingMipmaps = any*
int m_StreamingMipmapsPriority = 1± 
```

![Mipmap Example](images/Mipmaps_example.png)

具有所需值的 `Texture2D` asset 非常少，因此**只有少数纹理会受到此设置影响**，其中最明显的是 battle dashboard 中的 'chain' 和 'battle' 按钮。

## MSAA

也称为 **Multi-Sample Antialiasing**。

这是 Unity 专用的内部隐藏设置，Limbus 没有公开此设置。默认值为 2x。

**注意: 目前仍不清楚此设置在实际使用中是否有可测量的影响。**

## RT Memoryless

`RenderTextureMemoryless` 是一种优化功能，可以在不将 RenderTexture 备份到主系统 RAM 或 VRAM 的情况下进行渲染。Unity 会在渲染过程中将纹理内容暂时存放在 GPU 的 on-tile cache memory 中，并在渲染完成后立即完全丢弃数据。

这能为移动设备提供巨大的内存优化，因为移动设备的 VRAM bandwidth 和 footprint 都受到严格限制。

- Off — 不会将任何 render textures 标记为 memoryless。
- Depth — 将 depth buffer 标记为 memoryless。
- MSAA — 将 MSAA resolve buffer 标记为 memoryless。
- Depth+MSAA (Both) — 同时将 depth buffer 和 MSAA resolve buffer 标记为 memoryless。

注意: Memoryless RenderTexture 完全不可读写；`Texture2D.ReadPixels()`、`Graphics.CopyTexture()` 和 compute shaders 等功能都会失败。

这意味着依赖上述任何技术的 Shaders 和其他 Post-processing effects 都不会被渲染。

**需要重启游戏才能完全生效，部分 Textures 可能不受此设置影响。**
