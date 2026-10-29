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

Unity asset bundle은 astcenc + Metal compute 하이브리드 방식으로 기기에서 처리되며, iOS에서 동작하도록 다시 패키징됩니다
