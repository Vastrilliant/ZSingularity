# CONFIG
## LZ4HC compression on dispatch

Comprime los bundles con LZ4HC antes de subirlos al Transcoder pipeline para ahorrar ancho de banda. Esta configuración consume una cantidad considerable de RAM por cada subida de bundle; desactívala si tienes crashes debido a problemas de memoria.

## Enable Nightly Builds

Hace que ZSingularity busque nuevos builds Nightly en lugar de releases en el repositorio principal.

**NOTA: espera problemas de inestabilidad al ejecutar Nightly Builds.**
