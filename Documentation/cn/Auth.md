# AUTH
用于 [Transcoder pipeline](Mods.md#the-transcoder-pipeline) 的 GitHub 仓库身份验证，同时用于运行转码工作流以及存储/提供已经处理的 bundle。

## owner/repo

目标仓库，格式为 `owner/repo`（例如 `yourname/your-repo`）。

## Personal Access Token

需要 GitHub Personal Access Token（`github_pat_XXXX…` 或 `ghp_XXXX…`），ZSingularity 需要它来与仓库进行交互。

![Personal Access Token Example](images/PAT_example.png)

要获取自己的 Personal Access Token，请进入 GitHub 账户设置 > developer settings > Personal Access Tokens。

生成一个 fine-grained、repo-scoped token。

选择你的 transcoder proxy repo，设置方法请参阅 [Mods](mods.md#personal-access-token)。

![PAT Repository example](images/PAT-Permissions_example2.png)

为 token 设置过期日期。出于安全考虑，建议设置有限的有效期；如果不介意，也可以设置为永不过期。

为 token 分配以下权限:

- `Contents (Read / Write)`
- `Actions (Read / Write)`

![PAT Permissions Example](images/PAT-Permissions_example.png)

请将 Personal Access Token 保存在安全的位置。完成配置后，你将无法再次查看它。

**注意: 不要与任何人分享此 token。如果丢失 Personal Access Token 或 token 已泄露，请立即轮换 token。**

![PAT Token Example](images/PAT-Token_example.png)
