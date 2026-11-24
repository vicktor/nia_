#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Build the bilingual, dependency-free GitHub Pages site in docs/."""
import json
import shutil
from html import escape
from pathlib import Path
from string import Template

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "website"
OUTPUT = ROOT / "docs"
STATUSES = ("beta", "experimental", "development", "planned")


def build():
    content = json.loads((SOURCE / "content.json").read_text())
    template = Template((SOURCE / "template.html").read_text())
    features = content["features"]
    identifiers = [feature["id"] for feature in features]
    if len(set(identifiers)) != len(identifiers):
        raise ValueError("Duplicate feature identifiers")
    if any(feature["status"] not in STATUSES for feature in features):
        raise ValueError("Unknown feature status")
    (OUTPUT / "assets").mkdir(parents=True, exist_ok=True)
    for name in ("style.css", "site.js"):
        shutil.copyfile(SOURCE / name, OUTPUT / "assets" / name)
    shutil.copyfile(ROOT / "assets/nia-icon.png", OUTPUT / "assets/nia-icon.png")
    (OUTPUT / ".nojekyll").write_text("")
    for language in ("es", "en"):
        page = content[language]
        values = {key: escape(value, quote=True) for key, value in page.items() if isinstance(value, str)}
        # Only these authored headings allow a tiny, reviewed HTML vocabulary.
        for key in ("heroTitle", "introTitle", "continuityTitle", "ctaTitle"):
            values[key] = values[key].replace("&lt;br&gt;", "<br>").replace("&lt;span&gt;", "<span>").replace("&lt;/span&gt;", "</span>")
        values["assetPath"] = "../assets/" if language == "en" else "assets/"
        values["canonical"] = "https://vicktor.github.io/nia_/" + ("en/" if language == "en" else "")
        values["ogLocale"] = "en_US" if language == "en" else "es_ES"
        values["filters"] = "".join(
            f'<button type="button" data-filter="{status}" aria-pressed="{str(status == "all").lower()}">{escape(page[status])}</button>'
            for status in ("all", *STATUSES)
        )
        cards = []
        for feature in features:
            title, summary, detail = map(escape, feature[language])
            status = feature["status"]
            identifier = escape(feature["id"], quote=True)
            cards.append(f'<article class="feature" id="feature-{identifier}" data-status="{status}"><p class="badge {status}">{escape(page[status])}</p><h3>{title}</h3><p>{summary}</p><details><summary>{escape(page["details"])}</summary><p>{detail}</p></details></article>')
        values["features"] = "\n".join(cards)
        values["roadmap"] = "".join(f'<article><h3>{escape(title)}</h3><p>{escape(body)}</p></article>' for title, body in page["roadmapItems"])
        values["faqs"] = "".join(f'<details><summary>{escape(title)}</summary><p>{escape(body)}</p></details>' for title, body in page["faqs"])
        destination = OUTPUT / "en" if language == "en" else OUTPUT
        destination.mkdir(parents=True, exist_ok=True)
        (destination / "index.html").write_text(template.substitute(values))
    (OUTPUT / "robots.txt").write_text("User-agent: *\nAllow: /\nSitemap: https://vicktor.github.io/nia_/sitemap.xml\n")
    (OUTPUT / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://vicktor.github.io/nia_/</loc></url><url><loc>https://vicktor.github.io/nia_/en/</loc></url></urlset>\n')
    print(f"Built Spanish and English pages with {len(features)} features each in {OUTPUT}")


if __name__ == "__main__":
    build()
