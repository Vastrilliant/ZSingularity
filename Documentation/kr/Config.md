# CONFIG
## LZ4HC compression on dispatch

번들을 Transcoder pipeline에 업로드하기 전에 LZ4HC로 압축하여 대역폭을 절약합니다. 이 설정을 사용하면 번들 업로드마다 상당한 RAM을 사용하므로, 메모리 문제로 충돌하는 경우 비활성화하세요.

## Enable Nightly Builds

ZSingularity가 메인 저장소의 releases 대신 새로운 Nightly 빌드를 확인하도록 합니다.

**참고: Nightly Builds를 실행할 경우 불안정성 문제가 발생할 수 있습니다.**
