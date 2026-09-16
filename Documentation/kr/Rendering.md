# RENDERING
## Render Scale

게임의 렌더링 해상도 배율입니다.

값의 범위는 0에서 1.00입니다. 게임 자체의 설정 메뉴에서는 다음과 같은 일부 프리셋만 제공합니다:

- Low = 0.50
- Medium = 0.75
- High = 1.00

게임 중간에 Render Scale을 낮춰도 메모리가 크게 줄어드는 경우는 드뭅니다. 변경 사항이 완전히 적용되려면 게임을 재시작해야 합니다.

## Battle RS 

**Battle Render Scale**의 약어입니다.

`isBattle=1`을 활용하여 전투가 진행 중인지 감지하고, 원하는 값으로 해상도를 낮춥니다.

## AP RS Mult

**Adaptive Performance Render Scale Multiplier**의 약어입니다.

이는 주로 Android (AOS) 포트에서 사용되는 대체 render scale 방식입니다. 일반적인 engine render scale pipeline이 아니라 Unity의 Adaptive Performance 시스템을 통해 동작합니다.

값의 범위는 0에서 2.00이며, Adaptive Performance가 자체적으로 선택했을 render scale에 이 값을 곱합니다.

기본값인 1.00 이외의 값으로 설정하면 Adaptive Performance가 자동으로 활성화됩니다. Adaptive Performance가 실제로 render scale을 제어하지 않는 한 multiplier는 효과가 없기 때문입니다.

**참고: 이 설정은 매우 불안정합니다. 전투 중에는 이 값을 변경하지 마세요. 변경하면 게임이 멈춥니다. 또한 값을 0.00으로 설정하지 마세요. 이 경우에도 게임이 멈춥니다.**

## Texture MIP

내부적으로 Texture Mipmap Limit이라고 알려져 있습니다.

mipmap은 기본 텍스처와 함께 사용되는 미리 계산된 최적화 이미지 시퀀스입니다. 시퀀스의 각 다음 이미지는 이전 이미지의 해상도(너비와 높이)가 정확히 절반입니다. 엔진은 현재 화면에서 텍스처가 얼마나 크게 그려지는지에 따라 가장 적절한 레벨을 선택하므로, 멀리 있거나 작은 텍스처가 전체 해상도 이미지를 샘플링할 필요가 없습니다.

mipmap limit은 생성된 mip map level을 포함하는 `Texture2D` asset에만 영향을 줍니다. 해당 asset은 다음 속성도 가져야 합니다:

```
int m_MipMapsStripped = 0
int m_MipCount = 1+
bool m_IgnoreMipmapsLimit = false
bool m_StreamingMipmaps = any*
int m_StreamingMipmapsPriority = 1± 
```

![Mipmap Example](images/Mipmaps_example.png)

필요한 값을 가진 `Texture2D` asset은 매우 적기 때문에 **이 설정의 영향을 받는 텍스처도 일부에 불과합니다.** 대표적으로 battle dashboard에 있는 'chain' 및 'battle' 버튼이 있습니다.

## MSAA

**Multi-Sample Antialiasing**이라고도 합니다.

Unity 전용의 내부적으로 숨겨진 설정이며 Limbus에서는 노출하지 않습니다. 기본값은 2x입니다.

**참고: 실제로 측정 가능한 효과가 있는지는 아직 명확하지 않습니다.**

## RT Memoryless

`RenderTextureMemoryless`는 RenderTexture를 main system RAM 또는 VRAM에 백업하지 않고 렌더링할 수 있도록 하는 최적화 기능입니다. 대신 Unity는 렌더링 패스 동안 텍스처 내용을 GPU의 on-tile cache memory 안에만 임시로 저장하고, 작업이 끝난 직후 데이터를 완전히 폐기합니다.

이는 VRAM bandwidth와 footprint가 제한적인 모바일 기기에서 매우 큰 메모리 최적화 효과를 제공합니다.

- Off — 어떤 render texture도 memoryless로 표시되지 않습니다.
- Depth — depth buffer가 memoryless로 표시됩니다.
- MSAA — MSAA resolve buffer가 memoryless로 표시됩니다.
- Depth+MSAA (Both) — depth buffer와 MSAA resolve buffer 모두 memoryless로 표시됩니다.

참고: Memoryless RenderTexture는 완전히 읽거나 쓸 수 없습니다. `Texture2D.ReadPixels()`, `Graphics.CopyTexture()` 및 compute shader와 같은 기능은 실패합니다.

따라서 위 기술 중 하나에 의존하는 Shader 및 기타 Post-processing effect는 렌더링되지 않습니다.

**완전히 적용하려면 게임을 재시작해야 하며, 일부 Texture는 이 설정의 영향을 받지 않을 수 있습니다.**
