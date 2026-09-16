# AUTH
Аутентификация GitHub-репозитория, используемого [Transcoder pipeline](Mods.md#the-transcoder-pipeline), как для запуска workflow транскодирования, так и для хранения и выдачи уже обработанных bundle.

## owner/repo

Целевой репозиторий в формате `owner/repo` (например, `yourname/your-repo`).

## Personal Access Token

Вам потребуется GitHub Personal Access Token (`github_pat_XXXX…` или `ghp_XXXX…`), чтобы ZSingularity мог взаимодействовать с вашим репозиторием.

![Personal Access Token Example](images/PAT_example.png)

Чтобы получить собственный Personal Access Token, откройте настройки аккаунта GitHub > developer settings > Personal Access Tokens.

Создайте fine-grained, repo-scoped token.

Выберите transcoder proxy repo. Инструкции по настройке см. в разделе [Mods](mods.md#personal-access-token).

![PAT Repository example](images/PAT-Permissions_example2.png)

Укажите срок действия token. Для большей безопасности рекомендуется использовать конечный срок в днях; при желании можно установить отсутствие срока действия.

Назначьте token следующие разрешения:

- `Contents (Read / Write)`
- `Actions (Read / Write)`

![PAT Permissions Example](images/PAT-Permissions_example.png)

Храните Personal Access Token в безопасном месте. После настройки вы больше не сможете его просмотреть.

**ПРИМЕЧАНИЕ: не передавайте этот token кому-либо. Если вы потеряли Personal Access Token или он был скомпрометирован, немедленно выполните его ротацию.**

![PAT Token Example](images/PAT-Token_example.png)
