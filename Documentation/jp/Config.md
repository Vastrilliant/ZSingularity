# CONFIG
## Transcode Format

[Transcoder pipeline](Mods.md#the-transcode-pipeline) が modded AssetBundle のテクスチャを再エンコードするときに使用する出力テクスチャ形式です。オプション:

- `ASTC_RGBA_4x4` — 圧縮された ASTC オプションの中で最小のブロックサイズで、圧縮形式では品質と容量のバランスが最も優れています。

- `ASTC_RGBA_6x6` — **Limbus Company が iOS で使用するデフォルトのコーデック**です。

- `ASTC_RGBA_8x8` — 最大の ASTC ブロックサイズを持つ圧縮形式で、ファイルサイズが最小ですが、品質低下が最も大きくなります。

- `RGBA32` — 非圧縮で、忠実度が最も高く、ファイルサイズも最大です。

- `ETC2` — 圧縮形式で、ASTC の代替です。

**注: より高品質なコーデックを使用すると、メモリ使用量が急激に増加します。**

ASTC は iOS がネイティブにサポートする Apple の圧縮テクスチャ形式です。小さいブロックサイズ（4x4）はファイルサイズが大きくなる代わりに詳細を多く保持し、大きいブロックサイズ（8x8）は細かなディテールを柔らかくする代わりにファイルサイズをさらに小さくします。

## FModManifest zeroing

**ZSingularity** は、FMOD が manifest の検証に通常使用するネットワーク呼び出しを無効化します。これにより、差し替えたサウンドバンクがチェックサム不一致によってロードに失敗するのを防ぎます。この設定を無効にすると、そのパッチが解除され、FMOD 本来の manifest 検証が復元されます。

**新しいアップデートをダウンロードするときは、この設定を必ず無効にしてください。**

## LZ4HC compression on dispatch

Transcoder pipeline にアップロードする前にバンドルを LZ4HC で圧縮し、帯域幅を節約します。この設定を使用すると、バンドルを1つアップロードするたびにかなりの RAM を消費します。メモリ不足によるクラッシュが発生している場合は無効にしてください。

## Enable Nightly Builds

ZSingularity がメインリポジトリの releases ではなく、新しい Nightly ビルドを確認するようにします。

**注: Nightly Builds の実行時には不安定な問題が発生する可能性があります。**
