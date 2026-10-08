# MODS
Mods セクションはローカルの「mod フォルダ」ライブラリです。各フォルダにはインポートした mod ファイルと処理状態が保存され、ここから派生処理、インストール、復元を行えます。

## Mod の読み込み

利用している mod ライブラリから改造済み bundle をインポートします。[NexusMods](https://www.nexusmods.com/games/limbuscompany) を推奨します。

対応形式：
`__data` Unity AssetBundle
`.assets.bank` FMOD Sound Bank
`Lunartique` .zip アーカイブ
`Carra2` アーカイブ
`*.json` ローカライズファイル
`translation` パッケージ

## 処理

- **Unity AssetBundle** は通常そのままではインストールできません。別プラットフォーム向けのテクスチャ圧縮で作られていることが多いため、ゲームで読み込むには再エンコードが必要です。現在は対応する bundle をデバイス上で直接トランスコードします。

## トランスコードの流れ

デバイス上のトランスコーダーがインポートされた bundle とゲーム標準の bundle を読み込み、対応する asset を照合して必要なテクスチャを ASTC 6x6 に再エンコードします。GitHub リポジトリ、PAT、リモート workflow は不要です。

トランスコードが完了すると、処理済み bundle は元のファイルの代わりに直ちにインストールされます。元の bundle は後で復元できるよう `ZTranscoderInstaller` により先にバックアップされます。

