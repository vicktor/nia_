# nia_ website / Web de nia_

Static, bilingual site for GitHub Pages. No package installation, analytics, external fonts, cookies or browser credentials. The original application icon is copied unchanged. The terminal illustration uses invented project data and is labeled as an illustration.

## Edit and build

Edit `website/content.json` (Spanish/English copy, feature inventory and status), `website/template.html`, `website/style.css` and `website/site.js`.

```sh
python3 scripts/build-website.py
python3 scripts/check-website.py
node --check website/site.js
python3 -m http.server 8765 --bind 127.0.0.1 --directory docs
```

Open `http://127.0.0.1:8765/` (Spanish) or `/en/` (English). Commit the generated `docs/` files with their sources. Core content and disclosure controls work without JavaScript; JavaScript only adds feature filtering. Reduced motion and keyboard focus are supported.

## GitHub Pages

Publication is intentionally deferred until the owner makes `nia_` public. On 2026-11-23 GitHub returned HTTP 422 because the current plan does not support Pages for this private repository. No Pages site or separate public repository was created.

The intended URL is `https://vicktor.github.io/nia_/`. Once the owner has made the repository public:

1. Merge [PR #22](https://github.com/vicktor/nia_/pull/22) into `main`, if it has not been merged already.
2. Open **Settings → Pages → Build and deployment**.
3. Choose **Deploy from a branch**, branch **`main`**, folder **`/docs`**, and save.
4. Wait for the Pages build to complete and open the published URL above; check both `/` and `/en/`.

This publishes only the generated site, not repository contents outside `docs/`. Future site updates are published when generated files are committed to `main`.

The repository can remain private if its GitHub plan supports Pages for private repositories. The public page itself contains only approved product descriptions and the icon. GitHub currently requires Pro or a qualifying organization/enterprise plan for Pages in a private repository. If it is unavailable, keep the prepared site and enable Pages after the repository becomes public; do not change repository visibility automatically. [GitHub documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

No workflow is needed for branch-based publication. `.nojekyll` keeps the static output unchanged. Branch builds do not require uploading the app, its binaries, logs, models, or local databases.

## Español

Web estática bilingüe, con fuentes del sistema y sin analítica ni dependencias. El catálogo distingue **beta**, **experimental**, **nueva en desarrollo** y **pendiente**. La disponibilidad se describe por separado de las releases publicadas.

Modifica los archivos de `website/`, ejecuta los comandos anteriores y conserva también el resultado de `docs/`.

**La publicación queda aplazada por decisión del propietario hasta que nia_ sea público.** GitHub rechazó activar Pages con HTTP 422 por las limitaciones del plan actual. No se ha creado un sitio Pages ni otro repositorio público.

Cuando el repositorio sea público, integra la PR #22 en `main` y configura **Settings → Pages → Deploy from a branch → main → /docs → Save**. Al terminar el build, comprueba `https://vicktor.github.io/nia_/` y su versión `/en/`. Los cambios posteriores se publicarán al actualizar `docs/` en `main`.

El inventario contrastado, las carencias y los criterios de aceptación están en [STATUS.md](../STATUS.md). Nia Sync, el servicio residente de PTY y la detección automática de conversaciones **no se implementan al crear esta web**.
