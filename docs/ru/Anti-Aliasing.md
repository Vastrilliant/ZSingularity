# ANTI-ALIASING
## AA Mode

**Anti-Aliasing Mode** — внутренне скрытая настройка, специфичная для Unity. Доступны четыре пресета:

- None
- FXAA (Fast Approximate AA)
- SMAA (Subpixel Morphological AA)
- TAA (Temporal AA)

AA Mode **не оказывает заметного влияния на производительность.**

## AA Quality

Определяет качество выбранного режима Anti-Aliasing.

Имеет значение только когда AA Mode установлен не в None: чем выше уровень качества, тем больше samples/passes использует выбранный режим и тем выше пропорциональная нагрузка на GPU.

## Dithering

Dithering — намеренно добавляемый шум, который рандомизирует ошибку квантования и предотвращает появление крупных паттернов, таких как цветовые полосы, на текстурах, затронутых AA.

![Dithering Example](images/Dithering_example.png)
