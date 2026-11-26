#!/bin/bash
#
# Build a small map of the downloaded docs so an assistant can find the right
# few lines without reading the whole files.
#
#   bash scripts/build-docs-index.sh
#
# Reads docs/live/manual.md and docs/live/openapi.yaml (downloaded by
# scripts/fetch-docs.sh) and writes:
#   docs/live/index.md             — short, meant to be read whole: the manual's
#                                    sections, the API areas, and how to look things up
#   docs/live/manual-sections.tsv  — one row per manual heading (## to ######), meant
#                                    to be searched: start, end, level, section, heading
#   docs/live/api-endpoints.tsv    — one row per endpoint, meant to be searched:
#                                    start, end (lines in openapi.yaml), method, path,
#                                    area, summary
#
# Exit codes: 0 = index built, 1 = could not build it (the message says why).
# Runs on macOS's stock /bin/bash 3.2 and awk.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${LEADROUTER_DOCS_DIR:-$ROOT/docs/live}"
MANUAL="$DIR/manual.md"
SPEC="$DIR/openapi.yaml"
OUTPUTS="index.md manual-sections.tsv api-endpoints.tsv"

TMP_SECTIONS="$DIR/.manual-sections.tsv.tmp"
TMP_TSV="$DIR/.api-endpoints.tsv.tmp"
TMP_INDEX="$DIR/.index.md.tmp"
trap 'rm -f "$TMP_SECTIONS" "$TMP_TSV" "$TMP_INDEX"' EXIT

# On failure, remove any previous map: its line numbers would point into the wrong
# places of freshly downloaded documents.
fail() {
  for f in $OUTPUTS; do rm -f "$DIR/$f"; done
  echo "Cannot build the docs index: $1" >&2
  exit 1
}

for f in "$MANUAL" "$SPEC"; do
  [ -s "$f" ] || fail "$f is missing or empty. Run scripts/fetch-docs.sh first."
done

# ── Manual: headings (## to ######) with line ranges ──────────────────────────
# Headings inside ``` code blocks are not headings; "{#anchor}" suffixes are dropped.
# A heading's range ends where the next heading of the same or a higher level begins.
MANUAL_LINES="$(wc -l < "$MANUAL" | tr -d ' ')"
if ! awk -v total="$MANUAL_LINES" '
  function clean(x) { sub(/^#+ /, "", x); sub(/[ \t]*\{#[^}]*\}[ \t]*$/, "", x); gsub(/\t/, " ", x); return x }
  # Close every open heading at level >= lvl, ending at line end.
  function close_from(lvl, end,   l) {
    for (l = 6; l >= lvl; l--) if (start[l]) { print start[l] "\t" end "\t" l "\t" sec "\t" title[l]; start[l] = 0 }
  }
  /^```/ { fence = !fence; next }
  fence { next }
  /^#{1,6} / {
    lvl = index($0, " ") - 1
    close_from(lvl < 2 ? 2 : lvl, NR - 1)
    if (lvl == 1) { sec = ""; next }
    if (lvl == 2) {
      sec = clean($0)
      if (sec == "Table of Contents") { sec = ""; next }
    }
    if (sec == "") next
    start[lvl] = NR; title[lvl] = clean($0)
  }
  END {
    if (fence) exit 2
    close_from(2, total)
  }
' "$MANUAL" | sort -t "$(printf '\t')" -k1,1n -k3,3n > "$TMP_SECTIONS"; then
  fail "manual.md has a code block that is never closed, so its headings cannot be trusted. Search it directly."
fi

SECTION_COUNT="$(awk -F'\t' '$3 == 2' "$TMP_SECTIONS" | wc -l | tr -d ' ')"
[ "$SECTION_COUNT" -gt 0 ] || fail "found no '## ' sections in manual.md. Its format may have changed; search it directly."

# ── API: one row per operation ────────────────────────────────────────────────
# Relies on the generated spec's fixed layout: paths at 2-space indent, methods at
# 4, an operation's tags/summary at 6, tag names at 8. An operation ends where the
# next operation, path or top-level key begins.
awk -v Q="'" '
  function unq(x) { gsub("^[\"" Q "]|[\"" Q "]$", "", x); return x }
  function flush(end) {
    if (method != "") {
      gsub(/\t/, " ", summary)
      print mline "\t" end "\t" toupper(method) "\t" path "\t" tag "\t" summary
    }
    method = ""; tag = ""; summary = ""; intags = 0
  }
  /^paths:[ \t]*$/ { inpaths = 1; next }
  inpaths && /^[^ ]/ { flush(NR - 1); inpaths = 0 }
  !inpaths { next }
  /^  [^ ]/ {
    flush(NR - 1)
    path = $0; sub(/^  /, "", path); sub(/:[ \t]*$/, "", path); path = unq(path)
    next
  }
  /^    (get|put|post|patch|delete|head|options|trace):[ \t]*$/ {
    flush(NR - 1)
    method = $1; sub(/:$/, "", method); mline = NR
    next
  }
  method == "" { next }
  /^      tags:[ \t]*$/ { intags = 1; next }
  intags && /^        - / {
    if (tag == "") { tag = $0; sub(/^        - /, "", tag); tag = unq(tag) }
    next
  }
  /^      [^ ]/ { intags = 0 }
  /^      summary:/ { summary = $0; sub(/^      summary:[ \t]*/, "", summary); summary = unq(summary) }
  END { flush(NR) }
' "$SPEC" > "$TMP_TSV"

ENDPOINT_COUNT="$(wc -l < "$TMP_TSV" | tr -d ' ')"
# Cross-check against an independent signal: every operation in the generated spec
# carries exactly one operationId, at whatever indent. If the layout changes so the
# parser above misses operations, the two counts disagree and this fails loudly
# instead of producing a quietly incomplete index.
EXPECTED="$(awk '/^paths:[ \t]*$/{p=1;next} p&&/^[^ ]/{p=0} p&&/^ +operationId:/{n++} END{print n+0}' "$SPEC")"
if [ "$ENDPOINT_COUNT" -eq 0 ] || [ "$ENDPOINT_COUNT" -ne "$EXPECTED" ]; then
  fail "read $ENDPOINT_COUNT endpoints from openapi.yaml but expected $EXPECTED. Its format may have changed; search it directly."
fi

# ── index.md ──────────────────────────────────────────────────────────────────
{
  echo "# Docs index"
  echo
  echo "Built $(date -u '+%Y-%m-%d %H:%M UTC') from manual.md ($MANUAL_LINES lines) and openapi.yaml ($ENDPOINT_COUNT endpoints)."
  echo "Never read manual.md or openapi.yaml whole. Use these maps to read only the lines you need."
  echo
  echo "## How to look things up"
  echo
  echo "- **How do I… / what does X mean?** Search the manual's headings: \`grep -i <word> docs/live/manual-sections.tsv\`."
  echo "  Columns: start line, end line, level (2 = section, 3-6 = subsection), section, heading. Pick the narrowest matching row and read only those lines of \`docs/live/manual.md\`."
  printf '%s\n' "  To list one section's subsections: \`awk -F'\t' '\$4==\"Contracts\"' docs/live/manual-sections.tsv\`."
  echo "- **Which endpoint does X?** Search \`docs/live/api-endpoints.tsv\` by path or summary, e.g. \`grep -i 'contract' docs/live/api-endpoints.tsv | grep -i pause\`."
  echo "  Columns: start line, end line (in openapi.yaml), method, path, area, summary. Read only that line range of \`docs/live/openapi.yaml\`."
  echo "- **What fields does an object have?** For \`\$ref: \"#/components/schemas/Name\"\`, run \`grep -n '^    Name:' docs/live/openapi.yaml\` and read from there."
  echo "- Only call endpoints listed in api-endpoints.tsv. If nothing matches, say so instead of guessing."
  echo
  echo "## User manual sections"
  echo
  awk -F'\t' '$3 == 2 { print "- " $4 }' "$TMP_SECTIONS"
  echo
  echo "## API areas (endpoints per area)"
  echo
  cut -f5 "$TMP_TSV" | sed 's/^$/(no area)/' | sort | uniq -c | sort -k2 \
    | awk '{ n = $1; $1 = ""; sub(/^ /, ""); print "- " $0 " — " n }'
} > "$TMP_INDEX"

mv -f "$TMP_SECTIONS" "$DIR/manual-sections.tsv"
mv -f "$TMP_TSV" "$DIR/api-endpoints.tsv"
mv -f "$TMP_INDEX" "$DIR/index.md"
echo "Built docs/live/index.md ($SECTION_COUNT manual sections, $ENDPOINT_COUNT endpoints)."
