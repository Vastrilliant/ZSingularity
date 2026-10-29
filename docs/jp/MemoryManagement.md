# メモリ管理
## Entitlements

iOS アプリには、より多くのメモリを使用できるようにする entitlement が 2 つあります。

`com.apple.developer.kernel.increased-memory-limit` は、アプリが iOS にメモリの増加を要求できるようにします。**この entitlement は、メモリが 4GB 未満の iPhone では効果がありません。**

`com.apple.developer.kernel.extended-virtual-addressing` は 64 ビットの仮想アドレス空間を有効にし、アプリがはるかに大きなアドレス領域をマップできるようにします。

この entitlement 自体は物理メモリを**増やしません**が、巨大なデータチャンクを複数同時にマップする必要があるアプリにとって非常に重要です。仮想アドレスの範囲を広げることで、アドレス空間の断片化によるメモリ割り当ての失敗を防ぎます。

この entitlement は有料の Apple Developer アカウントでのみ利用できます。

## Extend Memory Usage

app extension を利用することで、ZS は IL2CPP のマネージドヒープと malloc のメモリ領域を、独立したメモリ制限を持つ app extension に再配置できます。

これにより、アプリは事実上 Apple のメモリ制限を回避でき、メモリが 3GB 程度の iPhone でもほぼ問題なくゲームを動作させられます。

追加の App ID の登録が必要になる点にご注意ください。

## Redirect minimum

再配置する IL2CPP マネージドメモリ領域を絞り込みます。しきい値を低くするとより多くのメモリが再配置されますが、安定性が低下する可能性があります。

## Memory Cleanup

アイドル状態のキャッシュ済みランタイムオブジェクトを解放することで、ゲームが使用しなくなったメモリを解放します。

対象：
* アイドルなプールインスタンス
* キャッシュされた asset
* 未使用のカメラ render target
* 戦闘ポートレート
* 戦闘 VFX エフェクト
* フォールバック用テキストマテリアルおよびその他の内部キャッシュ

その後、`GC.Collect()` を 2 回実行します。

実行中は一瞬ラグが発生することがあります。
