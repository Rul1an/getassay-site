#!/usr/bin/env python3
"""Pin the host scoping and inline hashes of the static-site security headers."""

from __future__ import annotations

import base64
import hashlib
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def parse_header_rules(raw: str) -> dict[str, dict[str, str]]:
    rules: dict[str, dict[str, str]] = {}
    current: str | None = None
    for line in raw.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            current = line.strip()
            rules[current] = {}
            continue
        if current is None or ":" not in line:
            raise AssertionError(f"invalid _headers line: {line!r}")
        name, value = line.strip().split(":", 1)
        rules[current][name.lower()] = value.strip()
    return rules


def inline_hash(html: str, tag: str) -> str:
    bodies = re.findall(rf"<{tag}\b[^>]*>(.*?)</{tag}>", html, re.DOTALL | re.IGNORECASE)
    assert len(bodies) == 1, f"expected exactly one inline {tag}, found {len(bodies)}"
    digest = hashlib.sha256(bodies[0].encode()).digest()
    return "'sha256-" + base64.b64encode(digest).decode() + "'"


def main() -> None:
    rules = parse_header_rules((ROOT / "_headers").read_text())
    html = (ROOT / "index.html").read_text()

    for pattern in (
        "https://:project.pages.dev/*",
        "https://:version.:project.pages.dev/*",
    ):
        assert rules.get(pattern, {}).get("x-robots-tag") == "noindex", (
            f"{pattern} must carry X-Robots-Tag: noindex"
        )

    assert "x-robots-tag" not in rules["/*"], "the custom domain must remain indexable"
    assert "content-security-policy" not in rules["/*"], (
        "CSP must not apply to install.sh or other non-HTML assets"
    )

    root_csp = rules.get("/", {}).get("content-security-policy")
    html_csp = rules.get("/*.html", {}).get("content-security-policy")
    assert root_csp and root_csp == html_csp, "root and HTML routes must share one CSP"

    required = {
        "default-src 'none'",
        "base-uri 'none'",
        "connect-src 'none'",
        "font-src 'self'",
        "form-action 'none'",
        "frame-ancestors 'none'",
        "img-src 'self' data:",
        "media-src 'self'",
        "object-src 'none'",
        f"script-src {inline_hash(html, 'script')}",
        f"style-src {inline_hash(html, 'style')}",
        "upgrade-insecure-requests",
        "worker-src 'none'",
    }
    actual = {directive.strip() for directive in root_csp.split(";") if directive.strip()}
    assert actual == required, f"CSP drift:\nmissing={required - actual}\nextra={actual - required}"
    assert "'unsafe-inline'" not in root_csp and "'unsafe-eval'" not in root_csp

    print("site headers contract: pass")


if __name__ == "__main__":
    main()
