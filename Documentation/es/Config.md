# CONFIG
## Transcode Format

El formato de textura de salida al que [Transcoder pipeline](Mods.md#the-transcode-pipeline) vuelve a codificar las texturas de los AssetBundle modificados. Opciones:

- `ASTC_RGBA_4x4` — comprimido, el menor tamaño de bloque de las opciones ASTC y el mejor equilibrio entre calidad y tamaño entre los formatos comprimidos.
- `ASTC_RGBA_6x6` — **el códec predeterminado que Limbus Company utiliza en iOS**.
- `ASTC_RGBA_8x8` — comprimido, el mayor tamaño de bloque ASTC, el menor tamaño de archivo y la mayor pérdida de calidad.
- `RGBA32` — sin compresión, máxima fidelidad y mayor tamaño de archivo.
- `ETC2` — comprimido, una alternativa a ASTC.

**NOTA: usar códecs de mayor calidad aumentará enormemente el uso de memoria.**

ASTC es el formato de textura comprimida compatible de forma nativa con Apple en iOS. Los bloques pequeños (4x4) conservan más detalle a cambio de un archivo mayor, mientras que los bloques grandes (8x8) reducen más el archivo pero suavizan los detalles finos.

## LZ4HC compression on dispatch

Comprime los bundles con LZ4HC antes de subirlos al Transcoder pipeline para ahorrar ancho de banda. Esta configuración consume una cantidad considerable de RAM por cada subida de bundle; desactívala si tienes crashes debido a problemas de memoria.

## Enable Nightly Builds

Hace que ZSingularity busque nuevos builds Nightly en lugar de releases en el repositorio principal.

**NOTA: espera problemas de inestabilidad al ejecutar Nightly Builds.**
