#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Check generated page links, assets and bilingual feature coverage."""
import json
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs"


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.ids, self.links, self.features, self.languages = [], [], [], []
        self.headings = 0
        self.feed(path.read_text())

    def handle_starttag(self, tag, pairs):
        attrs = dict(pairs)
        if "id" in attrs:
            self.ids.append(attrs["id"])
        if tag == "html":
            self.languages.append(attrs.get("lang"))
        if tag == "h1":
            self.headings += 1
        if tag == "article" and "data-status" in attrs:
            self.features.append((attrs["id"], attrs["data-status"]))
        if tag == "img":
            assert "alt" in attrs, "Missing image alternative"
        for key in ("href", "src"):
            if key in attrs:
                self.links.append(attrs[key])


content = json.loads((ROOT / "website/content.json").read_text())
expected = [("feature-" + item["id"], item["status"]) for item in content["features"]]
pages = {path: Page(path) for path in OUTPUT.rglob("*.html")}
assert len(pages) == 2, "Expected exactly the two language pages"
checks = 0
for path, page in pages.items():
    assert page.languages == (["en"] if path.parent.name == "en" else ["es"])
    assert page.headings == 1, "Each language needs one main heading"
    assert len(page.ids) == len(set(page.ids)), "Duplicate element IDs"
    assert page.features == expected, "Missing or inconsistent translated feature/status"
    for link in page.links:
        url = urlsplit(link)
        if url.scheme or url.netloc:
            assert url.scheme == "https", f"Unexpected external scheme: {link}"
            continue
        target = (path.parent / unquote(url.path)).resolve() if url.path else path
        if target.is_dir():
            target /= "index.html"
        assert target.is_relative_to(OUTPUT), f"Published asset outside docs/: {link}"
        assert target.is_file(), f"Missing local target: {link}"
        if url.fragment:
            assert target in pages and unquote(url.fragment) in pages[target].ids, f"Broken fragment: {link}"
        checks += 1
assert (OUTPUT / "assets/nia-icon.png").read_bytes() == (ROOT / "assets/nia-icon.png").read_bytes()
assert (OUTPUT / ".nojekyll").is_file()
print(f"Checked two languages, {len(expected)} features per language, {checks} local links/assets and the original icon")
