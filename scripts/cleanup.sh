#!/usr/bin/env bash
#
# Finds stray/orphaned files in this repo:
#   1. Raw video files sitting directly inside hls/ (should only ever contain
#      per-slug HLS bundles, e.g. hls/jewely-home.mp4 was left behind by a
#      manual upload and never cleaned up).
#   2. Source files in sources/ that have no corresponding hls/<slug>/master.m3u8
#      (either never converted, or the slug doesn't match the filename).
#
# Default mode is dry-run: it only reports what it finds. Pass --force to
# actually move stray hls/*.mp4 files into sources/ (nothing is ever deleted
# by this script -- deleting raw masters is a separate, deliberate decision).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

echo "== Stray video files directly under hls/ (should be in sources/) =="
found_stray=0
while IFS= read -r -d '' f; do
  found_stray=1
  rel="${f#"$ROOT_DIR"/}"
  echo "  $rel"
  if [ "$FORCE" -eq 1 ]; then
    dest="$ROOT_DIR/sources/$(basename "$f")"
    mv -n "$f" "$dest"
    echo "    -> moved to sources/$(basename "$f")"
  fi
done < <(find "$ROOT_DIR/hls" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mov" \) -print0)
[ "$found_stray" -eq 0 ] && echo "  none found"

echo
echo "== Source files in sources/ with no matching hls/<slug>/master.m3u8 =="
found_orphan=0
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  name="${base%.*}"
  slug=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')
  if [ ! -f "$ROOT_DIR/hls/$slug/master.m3u8" ]; then
    found_orphan=1
    echo "  sources/$base  (expected hls/$slug/master.m3u8)"
  fi
done < <(find "$ROOT_DIR/sources" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mov" \) -print0)
[ "$found_orphan" -eq 0 ] && echo "  none found"

if [ "$FORCE" -ne 1 ] && { [ "$found_stray" -eq 1 ] || [ "$found_orphan" -eq 1 ]; }; then
  echo
  echo "Re-run with --force to move stray hls/*.mp4 files into sources/."
  echo "Orphaned sources/ files are only listed -- convert them with scripts/convert_hls.sh or delete manually."
fi
