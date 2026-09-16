# RENDERING
## Render Scale

La escala de resolución de renderizado del juego.

Sus valores van de 0 a 1.00. El menú de ajustes del propio juego solo expone estos preajustes:

- Low = 0.50
- Medium = 0.75
- High = 1.00

Ten en cuenta que reducir Render Scale durante una partida rara vez produce una reducción significativa de memoria; debes reiniciar el juego para que el cambio surta efecto por completo.

## Battle RS 

Abreviatura de **Battle Render Scale**.

Mediante `isBattle=1`, ZSingularity puede detectar cuándo hay un combate activo y reducir la resolución al valor deseado.

## AP RS Mult

Abreviatura de **Adaptive Performance Render Scale Multiplier**.

Es un método alternativo de render scale utilizado principalmente por el port Android (AOS) del juego. Funciona mediante el sistema Adaptive Performance de Unity en lugar del engine render scale pipeline normal.

Sus valores van de 0 a 2.00 y multiplican el render scale que Adaptive Performance elegiría por sí mismo.

Establecerlo en cualquier valor distinto de su valor predeterminado 1.00 activa automáticamente Adaptive Performance, ya que el multiplier no tiene efecto a menos que Adaptive Performance esté controlando activamente el render scale.

**NOTA: esta configuración es extremadamente inestable. No cambies este valor durante un combate, ya que congelará el juego. Tampoco lo establezcas en 0.00, ya que también congelará el juego.**

## Texture MIP

Conocido internamente como Texture Mipmap Limit.

Un mipmap es una secuencia optimizada y precalculada de imágenes que acompaña a una textura principal. Cada imagen posterior de la secuencia tiene exactamente la mitad de la resolución (ancho y alto) de la anterior. El motor elige el nivel que mejor se adapta al tamaño actual con el que se dibuja la textura en pantalla, de modo que las texturas lejanas o pequeñas no necesitan muestrear una imagen a resolución completa.

El mipmap limit solo afecta a assets `Texture2D` que contienen mip map levels generados; además, esos assets deben tener las siguientes propiedades:

```
int m_MipMapsStripped = 0
int m_MipCount = 1+
bool m_IgnoreMipmapsLimit = false
bool m_StreamingMipmaps = any*
int m_StreamingMipmapsPriority = 1± 
```

![Mipmap Example](images/Mipmaps_example.png)

Muy pocos assets `Texture2D` tienen los valores necesarios, **por lo que solo algunas texturas se ven afectadas por esta configuración**, especialmente los botones 'chain' y 'battle' del battle dashboard.

## MSAA

También conocido como **Multi-Sample Antialiasing**.

Es una configuración interna y oculta específica de Unity que Limbus no expone. Su valor predeterminado es 2x.

**NOTA: todavía no está claro si esta configuración tiene algún efecto medible en la práctica.**

## RT Memoryless

`RenderTextureMemoryless` es una función de optimización que permite renderizar en un RenderTexture sin respaldarlo en la RAM principal del sistema ni en la VRAM. En su lugar, Unity almacena temporalmente el contenido de la textura únicamente en la on-tile cache memory de la GPU durante el render pass y descarta completamente los datos justo después.

Esto proporciona una gran optimización de memoria en dispositivos móviles, donde el VRAM bandwidth y el footprint están muy limitados.

- Off — ningún render texture se marca como memoryless.
- Depth — el depth buffer se marca como memoryless.
- MSAA — el MSAA resolve buffer se marca como memoryless.
- Depth+MSAA (Both) — tanto el depth buffer como el MSAA resolve buffer se marcan como memoryless.

NOTA: los Memoryless RenderTextures son completamente ilegibles e inmodificables; funciones como `Texture2D.ReadPixels()`, `Graphics.CopyTexture()` y compute shaders fallarán.

Esto significa que los Shaders y otros Post-processing effects que dependan de cualquiera de las técnicas anteriores no se renderizarán.

**Es necesario reiniciar el juego para que surta efecto por completo; algunas Textures pueden no verse afectadas por esta configuración.**
