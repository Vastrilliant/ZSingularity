# MODS
Mods 섹션은 로컬 "mod 폴더" 라이브러리입니다. 각 폴더에는 가져온 mod 파일과 처리 상태가 저장되며, 여기에서 배포, 설치 및 복원을 수행할 수 있습니다.

## Mods 불러오기

사용하는 mod 라이브러리에서 수정된 bundle을 가져옵니다. [NexusMods](https://www.nexusmods.com/games/limbuscompany)를 권장합니다.

지원 형식:
`__data` Unity AssetBundle
`.assets.bank` FMOD Sound Bank
`Lunartique` .zip 아카이브
`Carra2` 아카이브
`*.json` 로컬라이제이션 파일
`translation` 패키지

## 처리

- **Unity AssetBundle**은 일반적으로 그대로 설치할 수 없습니다. 다른 플랫폼용 텍스처 압축으로 만들어지는 경우가 많아 게임에서 로드하려면 다시 인코딩해야 합니다. 이제 tweak은 지원되는 bundle을 기기에서 직접 트랜스코딩합니다.

## 트랜스코더 파이프라인

온디바이스 트랜스코더는 가져온 bundle과 게임의 원본 bundle을 읽고 관련 asset을 매칭한 뒤 필요한 텍스처를 ASTC 6x6으로 다시 인코딩합니다. GitHub 저장소, PAT 또는 원격 workflow가 필요하지 않습니다.

트랜스코딩이 끝나면 처리된 bundle은 즉시 원본 대신 설치됩니다. 원본 bundle은 나중에 복원할 수 있도록 `ZTranscoderInstaller`가 먼저 백업합니다.

