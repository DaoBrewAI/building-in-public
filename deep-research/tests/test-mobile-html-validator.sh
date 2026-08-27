#!/usr/bin/env bash
set -euo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$plugin_root/skills/deep-research/references/scripts/validate_mobile_html.py"
fixture="$plugin_root/skills/deep-research/examples/mobile-html-report/example-report.html"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

python3 "$validator" "$fixture"

sed 's/<meta name="viewport"[^>]*>//' "$fixture" > "$tmp_dir/no-viewport.html"
if python3 "$validator" "$tmp_dir/no-viewport.html" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted HTML without a responsive viewport\n' >&2
  exit 1
fi

sed 's#</body>#<script>alert(1)</script></body>#' "$fixture" > "$tmp_dir/script.html"
if python3 "$validator" "$tmp_dir/script.html" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted executable script content\n' >&2
  exit 1
fi

sed 's/rel="noopener noreferrer"/rel="noopener"/' "$fixture" > "$tmp_dir/unsafe-link.html"
if python3 "$validator" "$tmp_dir/unsafe-link.html" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted an unsafe target=_blank link\n' >&2
  exit 1
fi

sed 's#</style>#body { background-image: url(https://example.com/tracker.png); }</style>#' \
  "$fixture" > "$tmp_dir/external-css.html"
if python3 "$validator" "$tmp_dir/external-css.html" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted an external CSS asset\n' >&2
  exit 1
fi

sed 's#<head>##; s#</head>##' "$fixture" > "$tmp_dir/no-head.html"
if python3 "$validator" "$tmp_dir/no-head.html" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted HTML without a head element\n' >&2
  exit 1
fi

sed 's#<main>#<main><img alt="tracker" srcset="https://example.com/tracker.png 1x">#' \
  "$fixture" > "$tmp_dir/external-srcset.html"
if python3 "$validator" "$tmp_dir/external-srcset.html" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted an external srcset resource\n' >&2
  exit 1
fi

python3 - "$fixture" "$tmp_dir/csp-in-body.html" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
head_open = source.index("<head>")
head_content = head_open + len("<head>")
head_close = source.index("</head>")
body_open = source.index("<body>")
body_content = body_open + len("<body>")
body_close = source.index("</body>")
rewritten = (
    source[:head_open]
    + "<head></head>\n<body>"
    + source[head_content:head_close]
    + source[body_content:body_close]
    + "</body>\n</html>\n"
)
Path(sys.argv[2]).write_text(rewritten)
PY
if python3 "$validator" "$tmp_dir/csp-in-body.html" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted CSP and semantic metadata outside head\n' >&2
  exit 1
fi

sed 's#<main>#<main><a href="javascript:alert(1)">unsafe</a>#' \
  "$fixture" > "$tmp_dir/unsafe-scheme.html"
if python3 "$validator" "$tmp_dir/unsafe-scheme.html" >/dev/null 2>&1; then
  printf 'FAIL: validator accepted an unsafe anchor scheme\n' >&2
  exit 1
fi

printf 'PASS: mobile HTML validator accepts the canonical fixture and rejects unsafe variants\n'
