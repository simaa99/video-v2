#!/usr/bin/env bash
#
# Production HLS conversion script.
#
# Usage:
#   ./scripts/convert_hls.sh <input.mp4> <slug> [--presets=1080p,720p,480p] [--force]
#
# Examples:
#   ./scripts/convert_hls.sh sources/fin3.mp4 fin3
#   ./scripts/convert_hls.sh sources/ring.MP4 ring --presets=720p,480p
#
# Output: hls/<slug>/{master.m3u8, poster.jpg, <rung>/index.m3u8, <rung>/segment_NNN.ts}
#
# Fixes vs. the previous script:
#   - Forces keyframes at exact segment boundaries (-force_key_frames + -g + -sc_threshold 0)
#     so every rendition cuts at the same timestamps. The old script let libx264 place
#     keyframes wherever it wanted, which produced 2s-14s segments in the existing
#     hls/*/v0/index.m3u8 files -- that breaks clean ABR switching and predictable seeking.
#   - Uses capped-CRF (CRF + maxrate/bufsize) instead of plain CRF, so each rung has a
#     bandwidth ceiling the player can actually rely on for ABR decisions.
#   - Never upscales: rungs above the source resolution are skipped automatically.
#   - Rebuilds the output directory from scratch (rm -rf) so a re-run never leaves stale
#     segments from a previous encode mixed in with new ones.
#   - Consistent segment_NNN.ts naming (previous videos are a mix of seg000.ts and
#     segment_000.ts depending on which script era produced them).
#   - Generates a poster.jpg thumbnail.
#   - Slugifies the output directory name so it is always a safe, predictable URL path.
set -euo pipefail

for bin in ffmpeg ffprobe; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Error: $bin not found in PATH. Install ffmpeg (brew install ffmpeg)." >&2; exit 1; }
done

if [ $# -lt 2 ]; then
  echo "Usage: $0 <input_file> <slug> [--presets=1080p,720p,480p] [--force]" >&2
  exit 1
fi

INPUT_FILE="$1"
RAW_SLUG="$2"
shift 2

PRESETS="1080p,720p,480p"
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --presets=*) PRESETS="${arg#--presets=}" ;;
    --force) FORCE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

[ -f "$INPUT_FILE" ] || { echo "Error: input file not found: $INPUT_FILE" >&2; exit 1; }

# Slugify: lowercase, spaces/underscores -> hyphen, strip anything not [a-z0-9-]
SLUG=$(echo "$RAW_SLUG" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')
[ -n "$SLUG" ] || { echo "Error: slug is empty after sanitization" >&2; exit 1; }
if [ "$SLUG" != "$RAW_SLUG" ]; then
  echo "Note: slug sanitized to '$SLUG' (was '$RAW_SLUG')"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/hls/$SLUG"
SEGMENT_DURATION=6   # Apple's current HLS Authoring Guidelines recommend 6s for VOD

if [ -d "$OUTPUT_DIR" ] && [ "$FORCE" -ne 1 ]; then
  read -r -p "Output dir hls/$SLUG already exists. Overwrite? [y/N] " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Aborted."; exit 1; }
fi
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# --- Probe source ---
SRC_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$INPUT_FILE")
SRC_WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$INPUT_FILE")
SRC_FPS_RAW=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$INPUT_FILE")
SRC_FPS=$(awk -F'/' '{ if ($2==0) print 30; else printf "%.0f", $1/$2 }' <<< "$SRC_FPS_RAW")
DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT_FILE")

GOP=$(( SRC_FPS * SEGMENT_DURATION ))
FORCE_KF="expr:gte(t,n_forced*${SEGMENT_DURATION})"

echo "Source: ${SRC_WIDTH}x${SRC_HEIGHT} @ ${SRC_FPS}fps, ${DURATION}s"

# rung name:height:video_bitrate:maxrate:bufsize:audio_bitrate
RUNG_TABLE=(
  "1080p:1080:5000k:5350k:7500k:128k"
  "720p:720:2800k:3000k:4200k:128k"
  "480p:480:1400k:1500k:2100k:96k"
  "360p:360:800k:850k:1200k:96k"
)

IFS=',' read -ra WANTED <<< "$PRESETS"

declare -a INCLUDED=()
for rung in "${RUNG_TABLE[@]}"; do
  IFS=':' read -r NAME HEIGHT VB MAXRATE BUFSIZE AB <<< "$rung"
  wanted=0
  for w in "${WANTED[@]}"; do [ "$w" = "$NAME" ] && wanted=1; done
  [ "$wanted" -eq 1 ] || continue
  if [ "$HEIGHT" -gt "$SRC_HEIGHT" ]; then
    echo "Skipping $NAME: source is only ${SRC_HEIGHT}p (would require upscaling)"
    continue
  fi
  INCLUDED+=("$rung")
done

if [ "${#INCLUDED[@]}" -eq 0 ]; then
  # Source is smaller than every requested rung: encode one rendition at source size.
  INCLUDED=("original:${SRC_HEIGHT}:2800k:3000k:4200k:128k")
fi

# --- Encode each rung ---
for rung in "${INCLUDED[@]}"; do
  IFS=':' read -r NAME HEIGHT VB MAXRATE BUFSIZE AB <<< "$rung"
  OUT="$OUTPUT_DIR/$NAME"
  mkdir -p "$OUT"
  echo "Encoding $NAME (target height ${HEIGHT}px, video ${VB}, audio ${AB})..."
  ffmpeg -y -i "$INPUT_FILE" \
    -vf "scale=trunc(oh*a/2)*2:${HEIGHT},format=yuv420p" \
    -c:v libx264 -profile:v high -crf 20 -preset fast \
    -b:v "$VB" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -force_key_frames "$FORCE_KF" \
    -c:a aac -b:a "$AB" -ac 2 \
    -hls_time "$SEGMENT_DURATION" -hls_playlist_type vod \
    -hls_flags independent_segments \
    -hls_segment_filename "$OUT/segment_%03d.ts" \
    -loglevel error -stats \
    "$OUT/index.m3u8"
done

# --- Thumbnail (poster) ---
POSTER_TS=$(awk -v d="$DURATION" 'BEGIN { t = d*0.1; if (t < 0.5) t = 0.5; if (t > 5) t = 5; print t }')
ffmpeg -y -ss "$POSTER_TS" -i "$INPUT_FILE" -vframes 1 -vf "scale=640:-2" -loglevel error "$OUTPUT_DIR/poster.jpg"

# --- Derive the real avc1 CODECS string per rung from the encoded output ---
# Rather than hardcoding a profile/level guess, read back what libx264 actually
# wrote. avc1.PPCCLL = profile_idc (hex) + constraint_flags (hex) + level_idc (hex).
# We always request -profile:v high, so constraint_flags is 00; profile_idc/level
# are still read from the real stream so this never drifts from reality.
profile_to_idc_hex() {
  case "$1" in
    "Constrained Baseline"|"Baseline") echo "42" ;;
    "Main")                            echo "4d" ;;
    "Extended")                        echo "58" ;;
    "High")                            echo "64" ;;
    "High 10")                         echo "6e" ;;
    "High 4:2:2")                      echo "7a" ;;
    "High 4:4:4 Predictive")           echo "f4" ;;
    *)                                 echo "64" ;;  # fallback: what we always request
  esac
}

# --- Master playlist ---
{
  echo "#EXTM3U"
  echo "#EXT-X-VERSION:6"
  echo "#EXT-X-INDEPENDENT-SEGMENTS"
  for rung in "${INCLUDED[@]}"; do
    IFS=':' read -r NAME HEIGHT VB MAXRATE BUFSIZE AB <<< "$rung"
    RUNG_WIDTH=$(awk -v w="$SRC_WIDTH" -v h="$SRC_HEIGHT" -v th="$HEIGHT" 'BEGIN { rw = int(w*th/h/2)*2; print rw }')
    VB_NUM=$(echo "$MAXRATE" | tr -d 'k')
    AB_NUM=$(echo "$AB" | tr -d 'k')
    BANDWIDTH=$(( (VB_NUM + AB_NUM) * 1000 ))

    SEG0="$OUTPUT_DIR/$NAME/segment_000.ts"
    # head -1: some muxed .ts files report the same video stream once per
    # MPEG-TS program, which duplicates ffprobe's output for an identical value.
    PROFILE_NAME=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile -of csv=p=0 "$SEG0" 2>/dev/null | head -1)
    LEVEL_RAW=$(ffprobe -v error -select_streams v:0 -show_entries stream=level -of csv=p=0 "$SEG0" 2>/dev/null | head -1)
    [ -n "$PROFILE_NAME" ] || PROFILE_NAME="High"
    [[ "$LEVEL_RAW" =~ ^[0-9]+$ ]] || LEVEL_RAW=40
    PROFILE_HEX=$(profile_to_idc_hex "$PROFILE_NAME")
    LEVEL_HEX=$(printf '%02x' "$LEVEL_RAW")
    CODECS="avc1.${PROFILE_HEX}00${LEVEL_HEX},mp4a.40.2"

    echo "#EXT-X-STREAM-INF:BANDWIDTH=${BANDWIDTH},RESOLUTION=${RUNG_WIDTH}x${HEIGHT},FRAME-RATE=${SRC_FPS}.000,CODECS=\"${CODECS}\""
    echo "${NAME}/index.m3u8"
  done
} > "$OUTPUT_DIR/master.m3u8"

echo "Done: hls/$SLUG/master.m3u8"

# --- Self-validate before declaring success ---
if ! "$SCRIPT_DIR/validate_hls.sh" "$SLUG"; then
  echo "Error: generated output for '$SLUG' failed validation (see above). Not marking as done." >&2
  exit 1
fi
