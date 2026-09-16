# MODS
Раздел Mods — это локальная библиотека "mod folders". Каждая папка содержит импортированные mod-файлы и их статус обработки; отсюда их можно отправлять, устанавливать и восстанавливать.

Для использования этой функции необходимо fork-нуть репозиторий Transcoder Proxy.

[https://github.com/vastrilliant/transcoder-proxy/](https://github.com/vastrilliant/transcoder-proxy/)

Также потребуется PAT (personal access token). См. [personal access token](Auth.md#personal-access-token).

## Load Mods

Импортирует modded bundle из выбранной вами библиотеки модов. Рекомендуется [NexusMods](https://www.nexusmods.com/games/limbuscompany).

Поддерживаемые форматы:
`__data` unity asset bundles
`.assets.bank` FMOD Sound Bank
`Lunartique` .zip archives
`Carra2` archives

Скоро:
`Localize` .json files (translation mods, custom announcers и т. д.)

## Processing

- **Unity AssetBundles** обычно нельзя установить как есть. Они обычно собраны с использованием сжатия текстур для другой платформы, поэтому игра не сможет загрузить их до повторного кодирования. Нажмите кнопку загрузки, чтобы отправить bundle в repo для transcoding.

## The Transcoder pipeline

Transcoding bundle отправляет его в GitHub-репозиторий, настроенный в [Auth](Auth.md), где GitHub Actions workflow перекодирует его текстуры в формат, выбранный в [Config → Transcode Format](Config.md).

После успешного завершения запуска tweak загружает обработанный bundle и устанавливает его вместо оригинала. Исходный stock bundle сначала сохраняется через `ZTranscoderInstaller`, чтобы его можно было восстановить позже. Обработанные bundle, уже находящиеся в настроенном repo после предыдущего dispatch, также можно сразу просматривать и устанавливать без повторного запуска Transcoder workflow.
