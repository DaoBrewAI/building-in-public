#!/usr/bin/env python3
"""Fail-closed static validation for a canonical Deep Research HTML report."""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import urlparse


EXPECTED_CSP = (
    "default-src 'none'; script-src 'none'; connect-src 'none'; "
    "style-src 'unsafe-inline'; img-src data: blob:; font-src data:; "
    "media-src data: blob:; worker-src 'none'; child-src 'none'; "
    "object-src 'none'; frame-src 'none'; manifest-src 'none'; "
    "base-uri 'none'; form-action 'none'"
)
REQUIRED_HEADINGS = (
    "# Executive Summary",
    "# Conclusions",
    "# Decision Status",
    "# Sources",
)
FORBIDDEN_TAGS = {
    "script",
    "iframe",
    "frame",
    "object",
    "embed",
    "form",
    "base",
    "area",
}


class ContractParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.errors: list[str] = []
        self.ids: set[str] = set()
        self.report_ids: list[str] = []
        self.charsets: list[str] = []
        self.viewports: list[str] = []
        self.csps: list[str] = []
        self.tag_starts: dict[str, int] = {}
        self.tag_ends: dict[str, int] = {}
        self.doctype_count = 0
        self.style_count = 0
        self.in_head = False
        self.in_body = False
        self.in_graphify_template = False
        self.graphify_text: list[str] = []
        self.csp_in_head = False
        self.template_in_head = False
        self.style_in_head = False
        self.charset_in_head: list[bool] = []
        self.viewport_in_head: list[bool] = []
        self.report_id_in_head: list[bool] = []
        self.source_placeholder_links = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        attr_map = {key.lower(): (value or "") for key, value in attrs}
        self.tag_starts[tag] = self.tag_starts.get(tag, 0) + 1

        if self.in_graphify_template:
            self.errors.append(
                f"graphify-source must be plain text; nested <{tag}> is forbidden"
            )

        if tag == "head":
            self.in_head = True
        elif tag == "body":
            self.in_body = True
        elif tag == "style":
            self.style_count += 1
            self.style_in_head = self.style_in_head or self.in_head

        if tag in FORBIDDEN_TAGS:
            self.errors.append(f"forbidden <{tag}> element")
        for name in attr_map:
            if name.startswith("on"):
                self.errors.append(f"forbidden event-handler attribute {name}")

        element_id = attr_map.get("id")
        if element_id:
            if element_id in self.ids:
                self.errors.append(f"duplicate id: {element_id}")
            self.ids.add(element_id)

        if tag == "meta":
            if "charset" in attr_map:
                self.charsets.append(attr_map["charset"].lower())
                self.charset_in_head.append(self.in_head)
            name = attr_map.get("name", "").lower()
            if name == "viewport":
                self.viewports.append(attr_map.get("content", "").lower())
                self.viewport_in_head.append(self.in_head)
            if name == "report-id":
                self.report_ids.append(attr_map.get("content", "").strip())
                self.report_id_in_head.append(self.in_head)
            if attr_map.get("http-equiv", "").lower() == "content-security-policy":
                self.csps.append(attr_map.get("content", ""))
                self.csp_in_head = self.in_head
            if attr_map.get("http-equiv", "").lower() == "refresh":
                self.errors.append("meta refresh is forbidden")

        if tag == "template" and attr_map.get("id") == "graphify-source":
            self.in_graphify_template = True
            self.template_in_head = self.in_head

        if tag == "link":
            self.errors.append("linked resources are not self-contained")

        if tag in {"img", "audio", "video", "source"} and "src" in attr_map:
            source = attr_map["src"].strip().lower()
            if source and not source.startswith(("data:", "blob:")):
                self.errors.append(f"external media source is not self-contained: {source}")
        if attr_map.get("srcset", "").strip():
            self.errors.append("srcset is forbidden in a self-contained report")
        if tag == "video" and attr_map.get("poster", "").strip():
            poster = attr_map["poster"].strip().lower()
            if not poster.startswith(("data:", "blob:")):
                self.errors.append(f"external video poster is not self-contained: {poster}")

        if tag == "a":
            href = attr_map.get("href", "")
            if "ping" in attr_map:
                self.errors.append("anchor ping is forbidden")
            if any(character.isspace() or ord(character) < 32 for character in href):
                self.errors.append("anchor href contains whitespace or control characters")
            is_placeholder = href == "__REPORT_SOURCE_URL__"
            parsed = urlparse(href)
            is_external = parsed.scheme.lower() in {"http", "https"}
            if is_external or is_placeholder or attr_map.get("target", "").lower() == "_blank":
                rel = set(attr_map.get("rel", "").lower().split())
                if not {"noopener", "noreferrer"}.issubset(rel):
                    self.errors.append(
                        "external and target=_blank links must use "
                        'rel="noopener noreferrer"'
                    )
            if is_placeholder:
                self.source_placeholder_links += 1
                if not self.in_body:
                    self.errors.append("report source placeholder must be inside <body>")
                if attr_map.get("target", "").lower() != "_blank":
                    self.errors.append("report source placeholder must use target=_blank")
            if is_placeholder or not href or href.startswith("#"):
                pass
            elif parsed.scheme.lower() in {"http", "https", "mailto"}:
                pass
            elif parsed.scheme:
                self.errors.append(f"unsupported link scheme: {parsed.scheme}")
            else:
                self.errors.append(
                    "anchor href must be a fragment or an absolute http(s)/mailto URL"
                )
        else:
            for reference_name in ("href", "xlink:href"):
                reference = attr_map.get(reference_name, "").strip().lower()
                if reference and not reference.startswith(("#", "data:", "blob:")):
                    self.errors.append(
                        f"external <{tag}> {reference_name} is not self-contained"
                    )

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        self.tag_ends[tag] = self.tag_ends.get(tag, 0) + 1
        if self.in_graphify_template:
            if tag == "template":
                self.in_graphify_template = False
            else:
                self.errors.append(
                    f"graphify-source must be plain text; nested </{tag}> is forbidden"
                )
        if tag == "head":
            self.in_head = False
        elif tag == "body":
            self.in_body = False

    def handle_data(self, data: str) -> None:
        if self.in_graphify_template:
            self.graphify_text.append(data)

    def handle_decl(self, decl: str) -> None:
        if decl.strip().lower() == "doctype html":
            self.doctype_count += 1


def validate(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    errors: list[str] = []

    parser = ContractParser()
    parser.feed(text)
    parser.close()
    errors.extend(parser.errors)

    if parser.doctype_count != 1:
        errors.append("exactly one HTML5 doctype is required")

    for structural_tag in ("html", "head", "body"):
        if parser.tag_starts.get(structural_tag, 0) != 1:
            errors.append(f"exactly one <{structural_tag}> element is required")
        if parser.tag_ends.get(structural_tag, 0) != 1:
            errors.append(f"exactly one </{structural_tag}> closing tag is required")
    lowered = text.lower()
    structural_positions = (
        lowered.find("<html"),
        lowered.find("<head>"),
        lowered.find("</head>"),
        lowered.find("<body>"),
        lowered.find("</body>"),
        lowered.rfind("</html>"),
    )
    if not all(
        left >= 0 and left < right
        for left, right in zip(structural_positions, structural_positions[1:])
    ):
        errors.append("html, head, and body elements must use canonical document order")

    if parser.charsets != ["utf-8"]:
        errors.append("exactly one UTF-8 charset declaration is required")
    if parser.charset_in_head != [True]:
        errors.append("the UTF-8 charset declaration must be inside <head>")
    viewport_parts = (
        set(part.strip() for part in parser.viewports[0].split(","))
        if len(parser.viewports) == 1
        else set()
    )
    if not {"width=device-width", "initial-scale=1"}.issubset(viewport_parts):
        errors.append("responsive viewport must declare width=device-width and initial-scale=1")
    if parser.viewport_in_head != [True]:
        errors.append("the responsive viewport meta must be inside <head>")
    if len(parser.report_ids) != 1 or not parser.report_ids[0]:
        errors.append("exactly one non-empty report-id meta is required")
    elif not re.fullmatch(r"[A-Za-z0-9._-]{3,128}", parser.report_ids[0]):
        errors.append("report-id contains unsupported characters")
    if parser.report_id_in_head != [True]:
        errors.append("the report-id meta must be inside <head>")
    if parser.csps != [EXPECTED_CSP]:
        errors.append("the exact restrictive Deep Research CSP is required once")
    if not parser.csp_in_head:
        errors.append("the CSP meta must be inside <head>")
    if parser.style_count < 1:
        errors.append("at least one inline <style> is required")
    if not parser.style_in_head:
        errors.append("inline presentation CSS must be inside <head>")

    template_open = '<template id="graphify-source">'
    if text.count(template_open) != 1 or text.count("</template>") != 1:
        errors.append("exactly one graphify-source template is required")
    else:
        csp_index = text.find("Content-Security-Policy")
        template_index = text.find(template_open)
        template_close = text.find("</template>")
        style_index = text.find("<style")
        if not (0 <= csp_index < template_index < template_close < style_index):
            errors.append("CSP, graphify-source template, and style must appear in that order")
        if not parser.template_in_head:
            errors.append("graphify-source template must be inside <head>")
        if template_close >= 16000:
            errors.append("graphify-source template must close before character 16000")
        semantic_text = "".join(parser.graphify_text).strip()
        if len(semantic_text) < 200:
            errors.append("graphify-source is too short to preserve key report semantics")
        for heading in REQUIRED_HEADINGS:
            if not re.search(rf"(?m)^{re.escape(heading)}\s*$", semantic_text):
                errors.append(f"graphify-source template is missing {heading}")

    if text.count("__REPORT_SOURCE_URL__") > 1:
        errors.append("at most one report source placeholder is allowed")
    if parser.source_placeholder_links != text.count("__REPORT_SOURCE_URL__"):
        errors.append("report source placeholder must be used only as a body anchor href")
    if re.search(r"@import\b", text, flags=re.IGNORECASE):
        errors.append("CSS @import is not self-contained")
    if re.search(r"url\(\s*['\"]?(?:https?:)?//", text, flags=re.IGNORECASE):
        errors.append("external CSS URL is not self-contained")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("html", type=Path)
    args = parser.parse_args()

    try:
        errors = validate(args.html)
    except (OSError, UnicodeError) as exc:
        print(f"FAIL: cannot read {args.html}: {exc}", file=sys.stderr)
        return 1

    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1

    print(f"PASS: canonical mobile HTML contract: {args.html}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
