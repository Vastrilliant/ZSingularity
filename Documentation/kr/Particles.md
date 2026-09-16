# PARTICLES
## Alignment

파티클 효과가 카메라와 월드에 대해 어떤 방향으로 배치될지 결정합니다:

- 0 = View
- 1 = World
- 2 = Local
- 3 = Facing
- 4 = Default

`4 = Default`는 정렬을 원래 상태로 복원합니다.

## Render Mode

파티클을 어떻게 렌더링할지 결정합니다.

참고: 각 particle system에는 일반적으로 개별 렌더링 모드가 있습니다. 이 설정은 선택한 모드를 게임의 모든 particle system에 강제로 적용하여 각각의 원래 설정을 덮어씁니다.

- 0 = Billboard
- 1 = Stretched Billboard
- 2 = Horizontal Billboard
- 3 = Vertical Billboard
- 4 = Mesh
- 5 = None
- 6 = Default

`5 = None`은 모든 particle effect를 비활성화합니다.

`6 = Default`는 모든 particle effect를 원래 상태로 복원합니다.

## Sort Mode

파티클이 서로에 대해 어떤 순서로 정렬되고 그려질지 결정합니다:

- 0 = None
- 1 = Distance
- 2 = Oldest Front
- 3 = Youngest Front

## Min Size & Max Size

파티클 효과가 렌더링될 수 있는 최소 및 최대 크기를 화면 높이의 비율(0–1)로 결정합니다.

참고: Min Size를 파티클의 의도된 크기보다 크게 설정하면 예상치 못한 문제가 발생할 수 있습니다.

## Freeform Stretching

파티클이 이동 방향과 독립적으로 자유롭게 늘어날 수 있는지 결정합니다.

**참고: Stretched Billboard render mode를 사용하는 particle system에서만 시각적인 효과가 나타납니다.**

## Max Count Cap

하나의 장면에 동시에 존재할 수 있는 최대 파티클 수를 결정합니다. 활성화하면 particle count가 설정된 제한을 초과하는 모든 particle system의 수를 해당 제한까지 줄입니다.
