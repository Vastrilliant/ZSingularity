# PARTICLES
## Alignment

パーティクルエフェクトがカメラおよびワールドに対してどのように向くかを決定します:

- 0 = View
- 1 = World
- 2 = Local
- 3 = Facing
- 4 = Default

`4 = Default` は alignment を元の状態へ戻します。

## Render Mode

パーティクルをどのようにレンダリングするかを決定します。

注: 通常、各 particle system には個別のレンダリングモードがあります。この設定を使用すると、選択したモードがゲーム内のすべての particle system に強制適用され、それぞれが元々持っていた設定を上書きします。

- 0 = Billboard
- 1 = Stretched Billboard
- 2 = Horizontal Billboard
- 3 = Vertical Billboard
- 4 = Mesh
- 5 = None
- 6 = Default

`5 = None` はすべての particle effect を無効にします。

`6 = Default` はすべての particle effect を元の状態へ戻します。

## Sort Mode

パーティクル同士の相対的な並び順と描画順を決定します:

- 0 = None
- 1 = Distance
- 2 = Oldest Front
- 3 = Youngest Front

## Min Size & Max Size

パーティクルエフェクトが描画される最小サイズと最大サイズを、画面の高さに対する割合（0–1）として決定します。

注: Min Size をパーティクル本来のサイズより大きくすると、予期しない問題が発生する可能性があります。

## Freeform Stretching

パーティクルを移動方向とは独立して自由に引き伸ばせるかどうかを決定します。

**注: Stretched Billboard render mode を使用する particle system でのみ視覚的な効果があります。**

## Max Count Cap

1つのシーンに同時に存在できるパーティクルの最大数を決定します。有効にすると、particle count が設定した上限を超える particle system は、その上限までクランプされます。
