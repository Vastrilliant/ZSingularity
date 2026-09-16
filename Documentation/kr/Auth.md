# AUTH
[Transcoder pipeline](Mods.md#the-transcoder-pipeline)에서 사용하는 GitHub 저장소의 인증입니다. 변환 워크플로를 실행하고 이미 처리된 번들을 저장 및 제공하는 데 사용됩니다.

## owner/repo

`owner/repo` 형식의 대상 저장소입니다 (예: `yourname/your-repo`).

## Personal Access Token

GitHub Personal Access Token (`github_pat_XXXX…` 또는 `ghp_XXXX…`)이 필요합니다. ZSingularity가 저장소와 상호작용하려면 이 토큰을 제공해야 합니다.

![Personal Access Token Example](images/PAT_example.png)

개인 액세스 토큰을 만들려면 GitHub 계정 설정 > developer settings > Personal Access Tokens로 이동합니다.

fine-grained, repo-scoped 토큰을 생성합니다.

transcoder proxy 저장소를 선택합니다. 설정 방법은 [Mods](mods.md#personal-access-token)를 참고하세요.

![PAT Repository example](images/PAT-Permissions_example2.png)

토큰의 만료 날짜를 지정하세요. 보안을 위해 유한한 기간을 설정하는 것이 권장되며, 신경 쓰지 않는다면 만료되지 않도록 설정할 수도 있습니다.

다음 권한을 토큰에 할당합니다:

- `Contents (Read / Write)`
- `Actions (Read / Write)`

![PAT Permissions Example](images/PAT-Permissions_example.png)

Personal Access Token은 안전한 곳에 저장하세요. 한 번 설정하면 다시 확인할 수 없습니다.

**참고: 이 토큰을 누구와도 공유하지 마세요. 토큰을 잃어버렸거나 Personal Access Token이 유출되었다면 즉시 토큰을 교체하세요.**

![PAT Token Example](images/PAT-Token_example.png)
