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

Unity の asset bundle は、astcenc と Metal compute のハイブリッドでデバイス上で処理され、iOS で動作するように再パッケージされます
