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

Los asset bundles de Unity se procesan en el dispositivo con un híbrido de astcenc + Metal compute y se reempaquetan para que funcionen en iOS
