# AUTH
[Transcoder pipeline](Mods.md#the-transcoder-pipeline) で使用する GitHub リポジトリの認証です。トランスコード用ワークフローの実行と、処理済みバンドルの保存・提供の両方に使用されます。

## owner/repo

`owner/repo` 形式の対象リポジトリです（例: `yourname/your-repo`）。

## Personal Access Token

GitHub Personal Access Token（`github_pat_XXXX…` または `ghp_XXXX…`）が必要です。ZSingularity がリポジトリとやり取りするために、このトークンを提供する必要があります。

![Personal Access Token Example](images/PAT_example.png)

Personal Access Token を取得するには、GitHub アカウント設定 > developer settings > Personal Access Tokens に移動します。

fine-grained、repo-scoped のトークンを生成します。

transcoder proxy repo を選択します。セットアップ方法については [Mods](mods.md#personal-access-token) を参照してください。

![PAT Repository example](images/PAT-Permissions_example2.png)

トークンに有効期限を設定します。セキュリティのため、有限の日数を設定することが推奨されます。気にしない場合は有効期限なしにすることもできます。

次の権限をトークンに割り当てます:

- `Contents (Read / Write)`
- `Actions (Read / Write)`

![PAT Permissions Example](images/PAT-Permissions_example.png)

Personal Access Token は安全な場所に保存してください。一度設定すると、再び表示することはできません。

**注: このトークンを誰とも共有しないでください。Personal Access Token を紛失した場合や漏洩した場合は、直ちにトークンをローテーションしてください。**

![PAT Token Example](images/PAT-Token_example.png)
