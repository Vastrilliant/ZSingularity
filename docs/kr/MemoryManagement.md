# 메모리 관리
## Entitlements

iOS 앱에는 더 많은 메모리를 사용할 수 있게 해 주는 entitlement가 두 가지 있습니다.

`com.apple.developer.kernel.increased-memory-limit`은 앱이 iOS에 더 많은 메모리를 요청할 수 있게 합니다. **이 entitlement는 메모리가 4GB 미만인 iPhone에서는 효과가 없습니다.**

`com.apple.developer.kernel.extended-virtual-addressing`은 64비트 가상 주소 공간을 활성화하여 앱이 훨씬 더 큰 주소 할당을 매핑할 수 있게 합니다.

이 entitlement 자체가 물리 메모리를 늘려 주는 것은 **아니지만**, 여러 개의 거대한 데이터 청크를 동시에 매핑해야 하는 애플리케이션에는 매우 중요합니다. 가상 주소 범위를 넓혀 주소 공간 단편화로 인한 메모리 할당 실패를 방지합니다.

이 entitlement는 유료 Apple 개발자 계정에서만 사용할 수 있습니다.

## Extend Memory Usage

app extension을 활용하여 ZS는 IL2CPP 관리형 힙과 malloc 메모리 영역을 별도의 메모리 제한을 가진 app extension으로 재할당할 수 있습니다.

이를 통해 앱이 사실상 Apple의 메모리 제한을 우회할 수 있어, 메모리가 3GB 정도인 iPhone에서도 대체로 게임을 정상적으로 실행할 수 있습니다.

추가 App ID 등록이 필요하다는 점에 유의하세요.

## Redirect minimum

재할당할 IL2CPP 관리형 메모리 영역을 필터링합니다. 임계값이 낮을수록 더 많은 메모리가 재할당되지만 안정성이 떨어질 수 있습니다.

## Memory Cleanup

유휴 상태의 캐시된 런타임 오브젝트를 해제하여 게임이 더 이상 사용하지 않는 메모리를 확보합니다.

대상:
* 유휴 풀 인스턴스
* 캐시된 asset
* 사용하지 않는 카메라 render target
* 전투 초상화
* 전투 VFX 이펙트
* 대체 텍스트 머티리얼 및 기타 내부 캐시

그 후 `GC.Collect()`를 두 번 실행합니다.

실행 중 잠깐 렉이 발생할 수 있습니다.
