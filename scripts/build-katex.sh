#!/usr/bin/env bash
# Build app/DshIOS/Math/KaTeX: KaTeX for the formulas SwiftMath cannot typeset
# (Views/MathFormula.swift). The version is the one the web version renders with,
# so a formula looks the same in both.
#
# The output is committed, so neither a local build nor Xcode Cloud runs this.
# Run it to move to another KaTeX: change the version, rebuild, update
# THIRD_PARTY_NOTICES.md, and look at the formulas in `-dshOpen timeline`.
#
# Only the woff2 fonts are kept (WebKit reads them), and the stylesheet points at
# them without the `fonts/` folder: the app's resources sit in one flat folder.
set -euo pipefail
katex="0.18.7"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/app/DshIOS/Math/KaTeX"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

npm install --silent --no-audit --no-fund --ignore-scripts --prefix "$work" "katex@$katex" >/dev/null
dist="$work/node_modules/katex/dist"
rm -rf "$out"
mkdir -p "$out"
cp "$dist/katex.min.js" "$out/katex.min.js"
cp "$dist/fonts/"*.woff2 "$out/"
# `url(fonts/X.woff2) format("woff2"),url(fonts/X.woff) …,url(fonts/X.ttf) …` → `url(X.woff2) format("woff2")`
node -e '
  const fs = require("fs");
  const css = fs.readFileSync(process.argv[1], "utf8")
    .replace(/url\(fonts\/([^)]+\.woff2)\) format\("woff2"\)(,url\([^)]+\) format\("[^"]+"\))*/g, "url($1) format(\"woff2\")");
  if (/fonts\//.test(css)) throw new Error("a font the stylesheet still loads from fonts/");
  fs.writeFileSync(process.argv[2], css);
' "$dist/katex.min.css" "$out/katex.min.css"
ls -l "$out" | awk 'NR > 1 { total += $5 } END { print "katex: " NR - 1 " files, " total " bytes" }'
