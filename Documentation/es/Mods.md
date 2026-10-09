# MODS
La sección Mods es una biblioteca local de "carpetas de mods". Cada carpeta contiene los archivos del mod que has importado, junto con su estado de procesamiento, y es desde ahí donde se envían, instalan o restauran.

## Cargar mods

Importa bundles modificados desde tu biblioteca de mods preferida. Se recomienda [NexusMods](https://www.nexusmods.com/games/limbuscompany).

Formatos compatibles: 
`__data` bundles de Unity 
`.assets.bank` bancos de sonido FMOD 
`Lunartique` archivos .zip 
`Carra2` archivos 
`*.json` archivos de localización 
`translation` paquetes

## Procesamiento

- **Unity AssetBundles** normalmente no pueden instalarse tal cual. Suelen estar construidos con una compresión de texturas de otra plataforma, por lo que el juego no los cargará hasta que se vuelvan a codificar. El tweak ahora transcodifica los bundles compatibles directamente en el dispositivo.

## Flujo del transcodificador

El transcodificador local lee el bundle importado y el bundle original del juego, relaciona los assets correspondientes y vuelve a codificar las texturas necesarias a ASTC 6x6. No se necesita un repositorio de GitHub, un PAT ni un flujo de trabajo remoto.

Cuando termina la transcodificación, el bundle procesado se instala inmediatamente en lugar del original. El bundle original se respalda primero mediante `ZTranscoderInstaller` para poder restaurarlo más tarde.

