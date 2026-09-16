# MODS
Mods セクションは "mod folders" のローカルライブラリです。各フォルダにはインポートした mod ファイルと処理状態が保存され、ここから mod の送信・インストール・復元を行います。

この機能を使用するには、Transcoder Proxy リポジトリを fork する必要があります。

[https://github.com/vastrilliant/transcoder-proxy/](https://github.com/vastrilliant/transcoder-proxy/)

また、PAT (personal access token) を提供する必要があります。詳しくは [personal access token](Auth.md#personal-access-token) を参照してください。

## Load Mods

任意の mod ライブラリから取得した modded bundle をインポートします。[NexusMods](https://www.nexusmods.com/games/limbuscompany) を推奨します。

対応形式:
`__data` unity asset bundles
`.assets.bank` FMOD Sound Bank
`Lunartique` .zip archives
`Carra2` archives

近日対応予定:
`Localize` .json files (translation mods、custom announcers など)

## Processing

- **Unity AssetBundles** は通常、そのままではインストールできません。別のプラットフォーム向けのテクスチャ圧縮でビルドされていることが多いため、再エンコードしないとゲームがロードできません。アップロードボタンを押して repo に送信し、transcoding を行ってください。

## The Transcoder pipeline

bundle を transcoding すると、[Auth](Auth.md) で設定された GitHub リポジトリへ送信され、GitHub Actions workflow が [Config → Transcode Format](Config.md) で選択した形式へテクスチャを再エンコードします。

実行が正常に完了すると、tweak が処理済み bundle をダウンロードし、元の bundle の代わりにインストールします。元の stock bundle は `ZTranscoderInstaller` を通じて先にバックアップされるため、後で復元できます。以前の dispatch ですでに設定済み repo に存在する処理済み bundle は、Transcoder workflow を再実行せずに直接一覧表示して再インストールすることもできます。
