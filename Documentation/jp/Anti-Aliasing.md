# ANTI-ALIASING
## AA Mode

**Anti-Aliasing Mode** は Unity 固有の、内部的に非表示となっている設定です。4つのプリセットがあります:

- None

- FXAA (Fast Approximate AA)

- SMAA (Subpixel Morphological AA)

- TAA (Temporal AA)

AA Mode に**目立ったパフォーマンスへの影響はありません。**

## AA Quality

現在選択されている Anti-Aliasing モードの品質を決定します。

これは AA Mode が None 以外に設定されている場合にのみ影響します。品質ティアが高いほど、選択したモードが使用するサンプル/パスが増え、それに比例して GPU コストも高くなります。

## Dithering

Dithering は、量子化誤差をランダム化するために意図的に適用されるノイズです。これにより、AA の影響を受けるテクスチャで色のバンディングなどの大規模なパターンが発生するのを防ぎます。

![Dithering Example](images/Dithering_example.png)
