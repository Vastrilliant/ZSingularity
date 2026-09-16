# AUTH
Autenticación para el repositorio de GitHub utilizado por [Transcoder pipeline](Mods.md#the-transcoder-pipeline), tanto para ejecutar el workflow de transcodificación como para almacenar y servir bundles ya procesados.

## owner/repo

El repositorio de destino, en formato `owner/repo` (por ejemplo, `yourname/your-repo`).

## Personal Access Token

Necesitarás un GitHub Personal Access Token (`github_pat_XXXX…` o `ghp_XXXX…`) para que ZSingularity pueda interactuar con tu repositorio.

![Personal Access Token Example](images/PAT_example.png)

Para obtener tu propio Personal Access Token, ve a la configuración de tu cuenta de GitHub > developer settings > Personal Access Tokens.

Genera un token fine-grained y repo-scoped.

Selecciona tu transcoder proxy repo; consulta [Mods](mods.md#personal-access-token) para saber cómo configurarlo.

![PAT Repository example](images/PAT-Permissions_example2.png)

Asigna una fecha de expiración al token. Es recomendable usar un número finito de días por seguridad; si no te importa, puedes configurarlo sin expiración.

Asigna al token estos permisos:

- `Contents (Read / Write)`
- `Actions (Read / Write)`

![PAT Permissions Example](images/PAT-Permissions_example.png)

Guarda tu Personal Access Token en un lugar seguro. Una vez configurado, no podrás volver a verlo.

**NOTA: NO compartas este token con nadie. Si pierdes tu Personal Access Token o se ve comprometido, rótalo inmediatamente.**

![PAT Token Example](images/PAT-Token_example.png)
