# DEBUG

La sección Debug es un visor en tiempo real del `stdout`/`stderr` del propio proceso: el mismo flujo al que escriben todas las llamadas `NSLog`; el registro del propio tweak se escribe en este flujo mediante la macro `ZLog`. No genera líneas de log por sí mismo; captura y muestra las que ya existen.

Este método alternativo es necesario para evitar que los logs se corrompan al leer NSLogs directamente en iOS18+.

## Syslog

La captura funciona redirigiendo los descriptores de archivo `stdout` y `stderr` del proceso a una tubería, lo que permite leer cada línea escrita en cuanto aparece. Los descriptores originales se conservan y cada línea se vuelve a escribir en ellos inmediatamente después de ser leída, por lo que abrir el visor no cambia el comportamiento normal de logging del proceso. Cualquier otra herramienta que lea `stdout`/`stderr`, como una consola del dispositivo o un debugger, seguirá viendo la misma salida.

## Debug mode

Mantener pulsado **Syslog** durante aproximadamente un segundo lo cambia al modo **Debug**. La vista de logs se limita a las líneas que contienen la etiqueta de log propia de este tweak, filtrando los logs del juego y cualquier otra cosa que comparta el `stdout`/`stderr` del proceso. Así, solo se muestran los mensajes producidos por este tweak.

## Blacklisted keywords

El campo **Blacklist keywords** permite silenciar por completo determinadas líneas ruidosas en lugar de simplemente dejarlas pasar. Introduce uno o más términos separados por comas y pulsa return para añadirlos. Cada término se compara como una subcadena sin distinguir mayúsculas y minúsculas con cada línea del log.

Un término en la lista negra:

- Impide que cualquier línea coincidente futura entre en el buffer.
- Elimina inmediatamente las líneas ya almacenadas que coincidan en cuanto se añade el término; no se limita a filtrar nuevas salidas.
- Se mantiene entre relanzamientos, junto con las demás configuraciones del tweak, hasta que se elimine.
