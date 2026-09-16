# PARTICLES
## Alignment

Determina cómo se orientan los efectos de partículas respecto a la cámara y al mundo:

- 0 = View
- 1 = World
- 2 = Local
- 3 = Facing
- 4 = Default

`4 = Default` restaura alignment a su estado original.

## Render Mode

Determina cómo se renderizan las partículas.

NOTA: cada particle system normalmente tiene su propio modo de renderizado. Esta configuración fuerza el modo seleccionado en todos los particle system del juego, sobrescribiendo el que tuviera originalmente cada uno.

- 0 = Billboard
- 1 = Stretched Billboard
- 2 = Horizontal Billboard
- 3 = Vertical Billboard
- 4 = Mesh
- 5 = None
- 6 = Default

`5 = None` desactiva todos los particle effects.

`6 = Default` restaura cada particle effect a su estado original.

## Sort Mode

Determina cómo se ordenan y dibujan las partículas entre sí:

- 0 = None
- 1 = Distance
- 2 = Oldest Front
- 3 = Youngest Front

## Min Size & Max Size

Determina el tamaño mínimo y máximo con el que pueden renderizarse los particle effects, como una fracción de la altura de la pantalla (0–1).

NOTA: aumentar Min Size por encima del tamaño previsto de una partícula puede producir consecuencias imprevistas.

## Freeform Stretching

Determina si las partículas pueden estirarse libremente de forma independiente a su dirección de desplazamiento.

**NOTA: solo tiene un efecto visible en particle system que utilicen Stretched Billboard render mode.**

## Max Count Cap

Determina el número máximo de partículas que pueden existir simultáneamente en una sola escena. Al activarlo, cualquier particle system cuyo particle count supere el límite configurado será reducido hasta ese límite.
