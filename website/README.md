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

The intended URL is `https://vicktor.github.io/nia_/`. Use **Settings → Pages → Deploy from a branch**, branch **`docs/website-and-roadmap`**, folder **`/docs`**. This publishes only the generated site, not repository contents outside `docs/`. After merging this branch into `main`, update the publishing branch and the technical-status link in the template to `main`.

The repository can remain private if its GitHub plan supports Pages for private repositories. The public page itself contains only approved product descriptions and the icon. GitHub currently requires Pro or a qualifying organization/enterprise plan for Pages in a private repository. If it is unavailable, keep the prepared site and enable Pages after the repository becomes public; do not change repository visibility automatically. [GitHub documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

No workflow is needed for branch-based publication. `.nojekyll` keeps the static output unchanged. Branch builds do not require uploading the app, its binaries, logs, models, or local databases.

## Español

Web estática bilingüe, con fuentes del sistema y sin analítica ni dependencias. El catálogo distingue **beta**, **experimental**, **nueva en desarrollo** y **pendiente**. La disponibilidad se describe por separado de las releases publicadas.

Modifica los archivos de `website/`, ejecuta los comandos anteriores y conserva también el resultado de `docs/`. Para publicar, configura GitHub Pages desde la rama `docs/website-and-roadmap`, carpeta `/docs`. Tras integrar la rama en `main`, actualiza la rama de publicación y el enlace al estado técnico de la plantilla.

El inventario contrastado, las carencias y los criterios de aceptación están en [STATUS.md](../STATUS.md). Nia Sync, el servicio residente de PTY y la detección automática de conversaciones **no se implementan al crear esta web**.
