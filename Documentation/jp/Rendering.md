# RENDERING
## Render Scale

ゲームのレンダリング解像度のスケールです。

値は 0 から 1.00 までです。ゲーム本体の設定メニューでは、次のプリセット範囲のみが公開されています:

- Low = 0.50
- Medium = 0.75
- High = 1.00

ゲーム中に Render Scale を下げても、メモリ使用量が大幅に減ることはほとんどありません。変更を完全に反映するにはゲームを再起動する必要があります。

## Battle RS 

**Battle Render Scale** の略です。

`isBattle=1` を利用することで戦闘が進行中かどうかを検出し、解像度を指定した値まで下げます。

## AP RS Mult

**Adaptive Performance Render Scale Multiplier** の略です。

これは主に Android (AOS) 版で使用される代替の render scale 方式で、通常の engine render scale pipeline ではなく Unity の Adaptive Performance システムを通じて動作します。

値は 0 から 2.00 までで、Adaptive Performance が本来選択する render scale にこの値を乗算します。

デフォルトの 1.00 以外に設定すると Adaptive Performance が自動的に有効になります。Adaptive Performance が実際に render scale を制御している場合にのみ multiplier が効果を持つためです。

**注: この設定は非常に不安定です。戦闘中にこの値を変更しないでください。変更するとゲームがフリーズします。また、0.00 に設定しないでください。この場合もゲームがフリーズします。**

## Texture MIP

内部的には Texture Mipmap Limit と呼ばれています。

mipmap はメインテクスチャに付随する、事前計算された最適化済みの画像シーケンスです。シーケンス内の各画像は、直前の画像の解像度（幅と高さ）がちょうど半分になっています。エンジンは、現在画面上でテクスチャがどれくらいの大きさで描画されているかに応じて最適なレベルを選ぶため、遠くにある小さなテクスチャがフル解像度の画像をサンプリングする必要がなくなります。

mipmap limit は、生成された mip map level を含む `Texture2D` asset にのみ影響します。また、これらの asset には次のプロパティが必要です:

```
int m_MipMapsStripped = 0
int m_MipCount = 1+
bool m_IgnoreMipmapsLimit = false
bool m_StreamingMipmaps = any*
int m_StreamingMipmapsPriority = 1± 
```

![Mipmap Example](images/Mipmaps_example.png)

必要な値を持つ `Texture2D` asset は非常に少ないため、**この設定の影響を受けるテクスチャもごく一部です。** 特に battle dashboard にある 'chain' と 'battle' ボタンが該当します。

## MSAA

**Multi-Sample Antialiasing** とも呼ばれます。

Unity 固有の、内部的に非表示となっている設定で、Limbus では公開されていません。デフォルト値は 2x です。

**注: 実際に測定可能な効果があるかどうかは、まだ明確ではありません。**

## RT Memoryless

`RenderTextureMemoryless` は、RenderTexture をメインシステム RAM や VRAM にバックアップせずにレンダリングできる最適化機能です。代わりに Unity はレンダリングパス中、テクスチャの内容を GPU の on-tile cache memory 内だけに一時保存し、直後に完全に破棄します。

これは、VRAM の bandwidth と footprint が厳しく制限されているモバイルデバイスで、大幅なメモリ最適化を実現します。

- Off — render texture は memoryless としてマークされません。
- Depth — depth buffer が memoryless としてマークされます。
- MSAA — MSAA resolve buffer が memoryless としてマークされます。
- Depth+MSAA (Both) — depth buffer と MSAA resolve buffer の両方が memoryless としてマークされます。

注: Memoryless RenderTexture は完全に読み取り・書き込み不可です。`Texture2D.ReadPixels()`、`Graphics.CopyTexture()`、compute shaders などの機能は失敗します。

つまり、上記のいずれかの手法に依存する Shaders やその他の Post-processing effects はレンダリングされません。

**完全に反映するにはゲームの再起動が必要です。一部の Textures はこの設定の影響を受けない場合があります。**
