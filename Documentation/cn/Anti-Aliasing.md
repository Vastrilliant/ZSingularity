# ANTI-ALIASING
## AA Mode

**Anti-Aliasing Mode** 是 Unity 专用的内部隐藏设置，共有四种预设:

- None
- FXAA (Fast Approximate AA)
- SMAA (Subpixel Morphological AA)
- TAA (Temporal AA)

AA Mode **不会对性能产生明显影响。**

## AA Quality

决定当前所选 Anti-Aliasing 模式的质量。

只有在 AA Mode 设置为 None 以外的选项时才会生效。质量等级越高，所选模式使用的采样/处理通道越多，GPU 开销也会按比例增加。

## Dithering

Dithering 是一种有意加入的噪声，用于随机化量化误差，防止受 AA 影响的纹理出现色带等大范围图案。

![Dithering Example](images/Dithering_example.png)
