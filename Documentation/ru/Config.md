# CONFIG
## LZ4HC compression on dispatch

Сжимает bundle в LZ4HC перед отправкой в Transcoder pipeline, экономя пропускную способность. Эта настройка потребляет значительный объём RAM при загрузке каждого bundle; отключите её, если у вас происходят сбои из-за нехватки памяти.

## Enable Nightly Builds

Заставляет ZSingularity проверять новые Nightly-сборки вместо releases в основном репозитории.

**ПРИМЕЧАНИЕ: при использовании Nightly Builds возможны проблемы с нестабильностью.**
