# PARTICLES
## Alignment

决定粒子效果相对于摄像机和世界的朝向:

- 0 = View
- 1 = World
- 2 = Local
- 3 = Facing
- 4 = Default

`4 = Default` 会将 alignment 恢复到原始状态。

## Render Mode

决定粒子的渲染方式。

注意: 每个 particle system 通常都有自己的独立渲染模式。此设置会将选定模式强制应用到游戏中的每个 particle system，覆盖它们原本的设置。

- 0 = Billboard
- 1 = Stretched Billboard
- 2 = Horizontal Billboard
- 3 = Vertical Billboard
- 4 = Mesh
- 5 = None
- 6 = Default

`5 = None` 会禁用所有 particle effect。

`6 = Default` 会将所有 particle effect 恢复到原始状态。

## Sort Mode

决定粒子彼此之间的排序和绘制方式:

- 0 = None
- 1 = Distance
- 2 = Oldest Front
- 3 = Youngest Front

## Min Size & Max Size

决定粒子效果允许渲染的最小和最大尺寸，以屏幕高度的比例（0–1）表示。

注意: 将 Min Size 提高到粒子原本的尺寸以上可能导致不可预期的结果。

## Freeform Stretching

决定粒子是否可以独立于移动方向进行自由拉伸。

**注意: 只有使用 Stretched Billboard render mode 的 particle system 才会产生可见效果。**

## Max Count Cap

决定单个场景中同时允许存在的最大粒子数量。启用后，任何 particle count 超过配置上限的 particle system 都会被限制到该上限。
