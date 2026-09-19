# MODS
Mods 섹션은 "mod folders"의 로컬 라이브러리입니다. 각 폴더에는 가져온 mod 파일과 처리 상태가 저장되며, 여기에서 mod를 전송/설치/복원할 수 있습니다.

이 기능을 사용하려면 Transcoder Proxy 저장소를 fork해야 합니다.

[https://github.com/vastrilliant/transcoder-proxy/](https://github.com/vastrilliant/transcoder-proxy/)

또한 이를 사용하려면 PAT (personal access token)를 제공해야 합니다. 자세한 내용은 [personal access token](Auth.md#personal-access-token)을 참고하세요.

## Load Mods

원하는 mod 라이브러리에서 가져온 modded bundle을 불러옵니다. [NexusMods](https://www.nexusmods.com/games/limbuscompany)를 권장합니다.

지원 형식:
`__data` unity asset bundles
`.assets.bank` FMOD Sound Bank
`Lunartique` .zip archives
`Carra2` archives

곧 지원 예정:
`Localize` .json files (translation mods, custom announcers 등)

## Processing

- **Unity AssetBundles**는 일반적으로 그대로 설치할 수 없습니다. 보통 다른 플랫폼의 텍스처 압축 방식으로 빌드되어 있기 때문에 다시 인코딩하지 않으면 게임이 로드하지 못합니다. 업로드 버튼을 눌러 repo로 보내고 transcoding을 진행하세요.

## The Transcoder pipeline

bundle을 transcoding하면 [Auth](Auth.md)에 설정된 GitHub 저장소로 전송되며, GitHub Actions workflow가 [Config → Transcode Format](Config.md)에서 선택한 형식으로 텍스처를 다시 인코딩합니다.

실행이 성공적으로 끝나면 tweak가 처리된 bundle을 다운로드하여 원본 대신 설치합니다. 원본 stock bundle은 먼저 `ZTranscoderInstaller`를 통해 백업되므로 나중에 복원할 수 있습니다.
