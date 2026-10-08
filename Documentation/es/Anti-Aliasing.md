# ANTI-ALIASING
## AA Mode

**Anti-Aliasing Mode** es una configuración interna y oculta específica de Unity. Tiene cuatro preajustes:

- None
- FXAA (Fast Approximate AA)
- SMAA (Subpixel Morphological AA)
- TAA (Temporal AA)

AA Mode **no tiene un impacto notable en el rendimiento.**

## AA Quality

Determina la calidad del modo Anti-Aliasing seleccionado actualmente.

Solo importa cuando AA Mode está configurado en algo distinto de None: cuanto mayor sea el nivel de calidad, más samples/passes utilizará el modo seleccionado y mayor será el coste proporcional para la GPU.

## Dithering

Dithering es una forma de ruido aplicada intencionalmente para aleatorizar el error de cuantización y evitar patrones a gran escala, como el color banding, en texturas afectadas por AA.

![Dithering Example](images/Dithering_example.png)
