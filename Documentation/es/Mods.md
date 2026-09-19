# MODS
La sección Mods es una biblioteca local de "mod folders". Cada carpeta contiene los archivos mod que has importado junto con su estado de procesamiento, y desde aquí puedes enviarlos, instalarlos o restaurarlos.

Para acceder a esta función, debes hacer fork del repositorio Transcoder Proxy.

[https://github.com/vastrilliant/transcoder-proxy/](https://github.com/vastrilliant/transcoder-proxy/)

También debes proporcionar un PAT (personal access token). Consulta [personal access token](Auth.md#personal-access-token).

## Load Mods

Importa bundles modificados obtenidos de la biblioteca de mods que elijas. Se recomienda [NexusMods](https://www.nexusmods.com/games/limbuscompany).

Formatos compatibles:
`__data` unity asset bundles
`.assets.bank` FMOD Sound Bank
`Lunartique` .zip archives
`Carra2` archives

Próximamente:
`Localize` .json files (translation mods, custom announcers, etc.)

## Processing

- **Unity AssetBundles** normalmente no pueden instalarse tal cual. Suelen estar creados con una compresión de texturas destinada a otra plataforma, por lo que el juego no podrá cargarlos hasta que se vuelvan a codificar. Pulsa el botón de subida para enviarlos al repo y hacer transcoding.

## The Transcoder pipeline

Hacer transcoding de un bundle lo envía al repositorio de GitHub configurado en [Auth](Auth.md), donde un workflow de GitHub Actions vuelve a codificar sus texturas en el formato elegido en [Config → Transcode Format](Config.md).

Cuando una ejecución termina correctamente, el tweak descarga el bundle procesado y lo instala en lugar del original. El stock bundle original se respalda primero mediante `ZTranscoderInstaller`, para poder restaurarlo posteriormente.
