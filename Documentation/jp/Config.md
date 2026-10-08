# CONFIG
## LZ4HC compression on dispatch

Transcoder pipeline にアップロードする前にバンドルを LZ4HC で圧縮し、帯域幅を節約します。この設定を使用すると、バンドルを1つアップロードするたびにかなりの RAM を消費します。メモリ不足によるクラッシュが発生している場合は無効にしてください。

## Enable Nightly Builds

ZSingularity がメインリポジトリの releases ではなく、新しい Nightly ビルドを確認するようにします。

**注: Nightly Builds の実行時には不安定な問題が発生する可能性があります。**
