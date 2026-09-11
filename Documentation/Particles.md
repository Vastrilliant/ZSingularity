# PARTICLES
## Alignment

Determines how particle effects are oriented relative to the camera and the world:

- 0 = View
- 1 = World
- 2 = Local
- 3 = Facing
- 4 = Default 

`4 = Default` restores alignment to its original state.

## Render Mode

Determines how particles are rendered.

NOTE: each particle system normally has its own individual rendering mode, this setting will force apply the selected mode to every particle system in the game, overriding whatever each one was originally set to.

- 0 = Billboard
- 1 = Stretched Billboard
- 2 = Horizontal Billboard
- 3 = Vertical Billboard
- 4 = Mesh
- 5 = None 
- 6 = Default 

`5 = None` disables every single particle effect.

`6 = Default` restores every particle effect to its original state.

## Sort Mode

Determines how particles are sorted and drawn relative to one another:

- 0 = None
- 1 = Distance
- 2 = Oldest Front
- 3 = Youngest Front

## Min Size & Max Size

Determines the minimum and maximum size particle effects are allowed to render at, as a fraction of screen height (0–1).

NOTE: raising Min Size above a particle's intended size may lead to unforeseen consequences.

## Freeform Stretching

Determines whether particles are allowed to be freely stretched independently of their travel direction.

**NOTE: this only has a visible effect on particle systems using the Stretched Billboard render mode.**

## Max Count Cap

Determines the maximum number of particles allowed to exist in a single scene at once. When enabled, any particle system whose particle count exceeds the configured cap will have it clamped down to that cap.