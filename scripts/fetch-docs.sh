#!/bin/bash
#
# Download the current Lead Router user manual and API reference for YOUR key.
#
#   bash scripts/fetch-docs.sh
#
# Reads LEADROUTER_API_KEY (from the environment, else from .env), asks theleadrouter.com for the documents
# that match the key's type (System, Partner or Buyer), and saves them in
# docs/live/ (which is never committed). Re-running only downloads what changed.
# Then builds docs/live/index.md, a short map of both (scripts/build-docs-index.sh).
#
# Exit codes: 0 = docs are current, 1 = could not refresh (the message says why).
# Runs on macOS's stock /bin/bash 3.2.

set -euo pipefail

BASE_URL="${LEADROUTER_BASE_URL:-https://theleadrouter.com}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"
OUT_DIR="$ROOT/docs/live"

KEY="${LEADROUTER_API_KEY:-}"
if [ -z "$KEY" ]; then
  if [ ! -f "$ENV_FILE" ]; then
    echo "No .env file. Copy .env.example to .env and paste your API key (README.md, Step 4)." >&2
    exit 1
  fi
  KEY="$(grep -E '^LEADROUTER_API_KEY=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
fi
case "$KEY" in
  ""|paste-your-key-here)
    echo "LEADROUTER_API_KEY in .env is empty. Paste your System API key there (README.md, Step 4)." >&2
    exit 1 ;;
  pk_*)
    echo "The key in .env starts with pk_ (a posting key). Make a System key instead (README.md, Step 1)." >&2
    exit 1 ;;
esac

mkdir -p "$OUT_DIR"
FAILED=0

# fetch <api path> <file name>
fetch() {
  local api="$1" name="$2"
  local dest="$OUT_DIR/$name" etag_file="$OUT_DIR/.$name.etag"
  local tmp="$dest.download" hdr="$dest.headers" code
  local etag=""
  if [ -f "$dest" ] && [ -s "$etag_file" ]; then etag="$(tr -d '"' < "$etag_file")"; fi

  # Headers go in a curl config read from stdin so the key never appears in the process list.
  if ! code="$( {
        printf 'header = "Authorization: Bearer %s"\n' "$KEY"
        if [ -n "$etag" ]; then printf 'header = "If-None-Match: \\"%s\\""\n' "$etag"; fi
      } | curl -sS --max-time 120 -K - -D "$hdr" -o "$tmp" -w '%{http_code}' "$BASE_URL$api")"; then
    echo "Could not reach $BASE_URL (are you online?)." >&2
    rm -f "$tmp" "$hdr"; FAILED=1; return
  fi

  case "$code" in
    200)
      mv -f "$tmp" "$dest"
      grep -i '^etag:' "$hdr" | tail -1 | cut -d' ' -f2- | tr -d '\r' > "$etag_file" || true
      echo "Updated $name" ;;
    304)
      echo "$name is already current" ;;
    401)
      echo "The API key was not accepted (expired, revoked or mistyped). Make a new System key (README.md, Step 1)." >&2
      rm -f "$tmp" "$hdr"; exit 1 ;;
    403)
      echo "This key cannot read the documentation ($(cat "$tmp" 2>/dev/null | head -c 200)). Use a System key." >&2
      FAILED=1 ;;
    *)
      echo "Downloading $name failed with HTTP $code. Try again in a few minutes." >&2
      FAILED=1 ;;
  esac
  rm -f "$tmp" "$hdr"
}

fetch /api/v1/docs/manual manual.md
fetch /api/v1/docs/openapi openapi.yaml

# Rebuild the map whenever both documents exist, so older copies stay searchable too.
if [ -s "$OUT_DIR/manual.md" ] && [ -s "$OUT_DIR/openapi.yaml" ]; then
  bash "$ROOT/scripts/build-docs-index.sh" || FAILED=1
fi

if [ "$FAILED" = 1 ]; then
  if [ -f "$OUT_DIR/manual.md" ]; then echo "Older copies are still in docs/live/." >&2; fi
  exit 1
fi
echo "Docs are in docs/live/. Start with docs/live/index.md; it says where to look in manual.md and openapi.yaml."
