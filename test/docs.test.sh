#!/usr/bin/env bash
# Test: documentation is complete, placeholder-free, and internally linked.
set -uo pipefail

fail=0
note() { echo "  FAIL  $1"; fail=1; }

REQUIRED="README.md LICENSE docs/architecture.md docs/decisions.md docs/findings.md docs/setup-windows.md docs/extending.md docs/comparison.md docs/providers.md"
for f in $REQUIRED; do
  [ -s "$f" ] || note "missing or empty: $f"
done

if grep -rInE '\b(TBD|TODO|FIXME|XXX)\b' README.md docs/ --exclude-dir=superpowers >/dev/null 2>&1; then
  grep -rInE '\b(TBD|TODO|FIXME|XXX)\b' README.md docs/ --exclude-dir=superpowers
  note "placeholder markers found"
fi

# Every relative markdown link must resolve, relative to the file that contains it.
broken=0
for src in README.md $(find docs -name '*.md' -not -path 'docs/superpowers/*'); do
  for link in $(grep -oE '\]\([^)]+\)' "$src" | sed -E 's/^\]\(//; s/\)$//; s/#.*$//'); do
    case "$link" in http*|mailto:*|"") continue ;; esac
    if [ ! -e "$(dirname "$src")/$link" ]; then
      echo "  FAIL  broken link in $src -> $link"
      broken=1
    fi
  done
done
[ "$broken" -eq 0 ] || fail=1

[ "$fail" -eq 0 ] && echo "  PASS  documentation complete"
exit $fail
