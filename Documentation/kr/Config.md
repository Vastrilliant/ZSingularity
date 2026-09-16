# CONFIG
## Transcode Format

[Transcoder pipeline](Mods.md#the-transcode-pipeline)이 modded AssetBundle 텍스처를 다시 인코딩할 때 사용하는 출력 텍스처 형식입니다. 옵션:

- `ASTC_RGBA_4x4` — 압축 형식 중 ASTC에서 가장 작은 블록 크기이며, 압축 형식 가운데 품질 대비 용량 효율이 가장 좋습니다.

- `ASTC_RGBA_6x6` — **Limbus Company가 iOS에서 사용하는 기본 코덱**입니다.

- `ASTC_RGBA_8x8` — 압축 형식 중 가장 큰 ASTC 블록 크기로, 파일 크기가 가장 작지만 품질 손실이 가장 큽니다.

- `RGBA32` — 비압축 형식으로, 충실도가 가장 높고 파일 크기도 가장 큽니다.

- `ETC2` — 압축 형식이며 ASTC의 대안입니다.

**참고: 더 높은 품질의 코덱을 사용하면 메모리 사용량이 급격히 증가합니다.**

ASTC는 iOS에서 기본 지원되는 Apple의 압축 텍스처 형식입니다. 작은 블록 크기(4x4)는 더 많은 디테일을 유지하는 대신 파일이 커지고, 큰 블록 크기(8x8)는 파일을 더 줄이는 대신 세밀한 디테일이 부드러워집니다.

## FModManifest zeroing

**ZSingularity**는 FMOD가 manifest를 검증하기 위해 일반적으로 수행하는 네트워크 호출을 무효화합니다. 이를 통해 교체된 사운드 뱅크가 체크섬 불일치로 인해 로드되지 않는 문제를 방지합니다. 이 설정을 비활성화하면 해당 패치가 해제되고 FMOD의 원래 manifest 검증이 복원됩니다.

**새 업데이트를 다운로드할 때는 반드시 이 설정을 비활성화해야 합니다.**

## LZ4HC compression on dispatch

번들을 Transcoder pipeline에 업로드하기 전에 LZ4HC로 압축하여 대역폭을 절약합니다. 이 설정을 사용하면 번들 업로드마다 상당한 RAM을 사용하므로, 메모리 문제로 충돌하는 경우 비활성화하세요.

## Enable Nightly Builds

ZSingularity가 메인 저장소의 releases 대신 새로운 Nightly 빌드를 확인하도록 합니다.

**참고: Nightly Builds를 실행할 경우 불안정성 문제가 발생할 수 있습니다.**
