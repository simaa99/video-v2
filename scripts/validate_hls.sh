#!/usr/bin/env bash
#
# QA validation gate for HLS output bundles.
#
# Usage:
#   ./scripts/validate_hls.sh <slug>   # validate one bundle: hls/<slug>/
#   ./scripts/validate_hls.sh --all    # validate every bundle under hls/
#
# Checks, in order, for each slug:
#   1. hls/<slug>/master.m3u8 exists, is non-empty, and starts with #EXTM3U.
#   2. hls/<slug>/poster.jpg exists and decodes as a valid image.
#   3. Every rendition playlist referenced by master.m3u8 exists.
#   4. Every rendition playlist references at least one segment_*.ts file.
#   5. Every referenced segment file exists and is non-zero size.
#   6. The first and last segment of every rendition decode cleanly (catches
#      truncated/corrupt output from an interrupted or partially-failed encode).
#   7. Every rendition of the same slug has the same segment count (this is
#      what makes clean ABR switching possible -- a mismatch means keyframe
#      alignment broke for at least one rung).
#
# Written for bash 3.2 (macOS's default /bin/bash) as well as modern bash in
# CI -- no associative arrays, no mapfile, to match the rest of scripts/.
#
# Single-slug mode exits 0 and prints "VALID" on success, or exits 1 and
# prints every failure found (does not stop at the first one). --all mode
# runs every slug, prints a per-slug summary line, and exits 1 if any slug
# failed -- useful as a whole-repo health check, e.g. after a bulk migration
# or as a periodic CI job independent of any single transcode run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

validate_one() {
  local SLUG="$1"
  local DIR="$ROOT_DIR/hls/$SLUG"
  local MASTER="$DIR/master.m3u8"
  local FAILURES=()
  local RUNG_NAMES=()
  local RUNG_SEG_COUNTS=()

  if [ ! -d "$DIR" ]; then
    echo "FAIL: hls/$SLUG does not exist"
    return 1
  fi

  # --- 1. master.m3u8 ---
  if [ ! -s "$MASTER" ]; then
    FAILURES+=("master.m3u8 missing or empty")
  else
    head -1 "$MASTER" | grep -q '^#EXTM3U' || FAILURES+=("master.m3u8 does not start with #EXTM3U")
  fi

  # --- 2. poster.jpg ---
  local POSTER="$DIR/poster.jpg"
  if [ ! -s "$POSTER" ]; then
    FAILURES+=("poster.jpg missing or empty")
  else
    ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$POSTER" >/dev/null 2>&1 \
      || FAILURES+=("poster.jpg does not decode as a valid image")
  fi

  # --- 3-6. renditions + segments ---
  if [ -s "$MASTER" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in \#*) continue ;; esac
      local RUNG_PLAYLIST="$DIR/$line"
      local RUNG_NAME
      RUNG_NAME="$(dirname "$line")"
      if [ ! -s "$RUNG_PLAYLIST" ]; then
        FAILURES+=("$RUNG_NAME: rendition playlist missing or empty ($line)")
        continue
      fi

      local SEG_LIST
      SEG_LIST=$(grep -E '^segment_[0-9]+\.ts$' "$RUNG_PLAYLIST" || true)
      if [ -z "$SEG_LIST" ]; then
        FAILURES+=("$RUNG_NAME: playlist references zero segments")
        continue
      fi
      local SEG_COUNT
      SEG_COUNT=$(echo "$SEG_LIST" | wc -l | tr -d ' ')
      RUNG_NAMES+=("$RUNG_NAME")
      RUNG_SEG_COUNTS+=("$SEG_COUNT")

      local FIRST_SEG="" LAST_SEG="" seg f
      while IFS= read -r seg; do
        f="$DIR/$RUNG_NAME/$seg"
        [ -s "$f" ] || FAILURES+=("$RUNG_NAME/$seg: missing or zero-byte")
        [ -z "$FIRST_SEG" ] && FIRST_SEG="$f"
        LAST_SEG="$f"
      done <<< "$SEG_LIST"

      for f in "$FIRST_SEG" "$LAST_SEG"; do
        [ -n "$f" ] && [ -s "$f" ] || continue
        ffmpeg -v error -i "$f" -f null - >/dev/null 2>&1 \
          || FAILURES+=("$RUNG_NAME/$(basename "$f"): fails to decode cleanly")
      done
    done < <(grep -v '^#' "$MASTER")
  fi

  # --- 7. segment count consistency across renditions ---
  if [ "${#RUNG_NAMES[@]}" -gt 1 ]; then
    local REF_COUNT="${RUNG_SEG_COUNTS[0]}" REF_RUNG="${RUNG_NAMES[0]}" i=1
    while [ "$i" -lt "${#RUNG_NAMES[@]}" ]; do
      if [ "${RUNG_SEG_COUNTS[$i]}" != "$REF_COUNT" ]; then
        FAILURES+=("segment count mismatch: $REF_RUNG=$REF_COUNT vs ${RUNG_NAMES[$i]}=${RUNG_SEG_COUNTS[$i]} (breaks clean ABR switching)")
      fi
      i=$((i+1))
    done
  fi

  if [ "${#FAILURES[@]}" -eq 0 ]; then
    local SUMMARY="" i=0
    while [ "$i" -lt "${#RUNG_NAMES[@]}" ]; do
      SUMMARY="$SUMMARY ${RUNG_NAMES[$i]}=${RUNG_SEG_COUNTS[$i]}"
      i=$((i+1))
    done
    echo "VALID: hls/$SLUG (${#RUNG_NAMES[@]} rendition(s):$SUMMARY segments)"
    return 0
  else
    echo "INVALID: hls/$SLUG"
    local f
    for f in "${FAILURES[@]}"; do
      echo "  - $f"
    done
    return 1
  fi
}

if [ $# -lt 1 ]; then
  echo "Usage: $0 <slug> | $0 --all" >&2
  exit 1
fi

if [ "$1" = "--all" ]; then
  OVERALL=0
  COUNT=0
  for dir in "$ROOT_DIR"/hls/*/; do
    [ -d "$dir" ] || continue
    slug="$(basename "$dir")"
    COUNT=$((COUNT+1))
    validate_one "$slug" || OVERALL=1
  done
  echo ""
  if [ "$OVERALL" -eq 0 ]; then
    echo "ALL VALID: $COUNT video(s) checked"
  else
    echo "FAILURES FOUND across $COUNT video(s) checked -- see above"
  fi
  exit "$OVERALL"
else
  validate_one "$1"
  exit $?
fi
