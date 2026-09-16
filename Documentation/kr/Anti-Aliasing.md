# ANTI-ALIASING
## AA Mode

**Anti-Aliasing Mode**은 Unity 전용의 내부적으로 숨겨진 설정입니다. 네 가지 프리셋이 있습니다:

- None

- FXAA (Fast Approximate AA)

- SMAA (Subpixel Morphological AA)

- TAA (Temporal AA)

AA Mode는 **눈에 띄는 성능 영향을 주지 않습니다.**

## AA Quality

현재 선택된 Anti-Aliasing 모드의 품질을 결정합니다.

AA Mode가 None이 아닌 경우에만 적용됩니다. 품질 단계가 높을수록 선택된 모드에서 사용하는 샘플/패스가 많아지며, 그에 비례해 GPU 비용도 증가합니다.

## Dithering

Dithering은 양자화 오차를 무작위화하기 위해 의도적으로 적용하는 노이즈입니다. 이를 통해 AA의 영향을 받는 텍스처에서 색상 밴딩과 같은 대규모 패턴이 나타나는 것을 방지합니다.

![Dithering Example](images/Dithering_example.png)
