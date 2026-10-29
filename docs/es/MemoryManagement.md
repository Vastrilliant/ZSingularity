# GESTIÓN DE MEMORIA
## Entitlements

Una app de iOS puede tener dos entitlements que le permiten usar más memoria.

`com.apple.developer.kernel.increased-memory-limit` permite que la app solicite más memoria a iOS. **Este entitlement no tiene efecto en iPhones con menos de 4GB de memoria.**

`com.apple.developer.kernel.extended-virtual-addressing` habilita espacios de direcciones virtuales de 64 bits, lo que permite a la app mapear asignaciones de direcciones mucho más grandes.

Aunque este entitlement por sí solo **no** aumenta la memoria física, es fundamental para las aplicaciones que necesitan mapear varios bloques de datos enormes de forma simultánea. Al ampliar los límites de direcciones virtuales, evita que las asignaciones de memoria fallen por la fragmentación del espacio de direcciones.

Este entitlement solo está disponible para cuentas de desarrollador de Apple de pago.

## Extender el uso de memoria

Mediante app extensions, ZS puede reasignar los heaps administrados de IL2CPP y las regiones de memoria malloc a una app extension, que tiene un límite de memoria independiente.

Esto permite a la app saltarse las restricciones de memoria de Apple, de modo que iPhones con apenas 3GB de memoria puedan ejecutar el juego casi con normalidad.

Ten en cuenta que esto requiere registrar un App ID adicional.

## Mínimo de redirección

Filtra qué regiones de memoria administrada de IL2CPP se reasignan. Los umbrales más bajos reasignarán más memoria, pero pueden afectar a la estabilidad.

## Limpieza de memoria

Libera la memoria que el juego ya no usa liberando objetos en caché inactivos.

Entre ellos:
* instancias en pool inactivas
* assets en caché
* render targets de cámara sin usar
* retratos de combate
* efectos VFX de combate
* materiales de texto de respaldo y otras cachés internas

Después ejecuta `GC.Collect()` dos veces.

Espera un breve pico de lag al ejecutarlo.
