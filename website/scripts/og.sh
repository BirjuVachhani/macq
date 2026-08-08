#!/usr/bin/env bash
#
# Render scripts/og.html to public/og.png at 1200x630 with headless Chrome.
#
# Only needed when the OG card's copy or design changes. The PNG is committed,
# so a plain `npm run build` never has to run this.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/og.html"
OUTPUT="$SCRIPT_DIR/../public/og.png"

CANDIDATES=(
	"${CHROME:-}"
	"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
	"/Applications/Chromium.app/Contents/MacOS/Chromium"
	"/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
	"$(command -v google-chrome || true)"
	"$(command -v chromium || true)"
)

CHROME_BIN=""
for candidate in "${CANDIDATES[@]}"; do
	if [ -n "$candidate" ] && [ -x "$candidate" ]; then
		CHROME_BIN="$candidate"
		break
	fi
done

if [ -z "$CHROME_BIN" ]; then
	echo "error: no Chrome or Chromium found. Set CHROME=/path/to/chrome and retry." >&2
	exit 1
fi

"$CHROME_BIN" \
	--headless \
	--disable-gpu \
	--hide-scrollbars \
	--force-device-scale-factor=1 \
	--window-size=1200,630 \
	--screenshot="$OUTPUT" \
	"file://$SOURCE" >/dev/null 2>&1

echo "wrote $(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
