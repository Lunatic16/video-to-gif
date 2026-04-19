#!/usr/bin/env bash
# =============================================================================
# 	   Convert a video file into an animated GIF using FFmpeg			       			      			     
# =============================================================================
# Usage:
#   ./video_to_gif.sh [OPTIONS] input.mp4
#
# Options:
#   -o, --output FILE       Output GIF filename (default: input filename + .gif)
#   -s, --start TIME        Start time (e.g. 00:00:05 or 5) (default: 0)
#   -d, --duration TIME     Duration in seconds (default: full video)
#   -r, --fps FPS           Frames per second (default: 15)
#   -w, --width PX          Output width in pixels (default: 480, -1 = auto)
#   -l, --loop N            Loop count: 0=infinite, 1=once, etc. (default: 0)
#   -q, --quality LEVEL     Quality: low | medium | high (default: medium)
#   -c, --crop WxH+X+Y      Crop region before scaling (e.g. 640x360+0+60)
#   -S, --speed FACTOR      Playback speed multiplier (e.g. 2.0 = 2× faster)
#   -R, --reverse           Reverse the GIF (boomerang effect)
#   -m, --max-size SIZE     Target max file size (e.g. 5M, 500K); auto-reduces
#                           FPS/width until the output fits
#   -p, --preview           Extract a single preview frame (PNG) and exit
#       --force             Overwrite output without prompting
#       --dry-run           Print FFmpeg commands without executing them
#   -h, --help              Show this help message
#
# Requirements:
#   FFmpeg must be installed. Install with:
#     macOS:   brew install ffmpeg
#     Ubuntu:  sudo apt install ffmpeg
#     Fedora:  sudo dnf install ffmpeg
#     Windows: https://ffmpeg.org/download.html
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
FPS=15
WIDTH=480
LOOP=0
QUALITY="medium"
START=""
DURATION=""
OUTPUT=""
INPUT=""
CROP=""
SPEED=""
REVERSE=false
MAX_SIZE=""
PREVIEW=false
FORCE=false
DRY_RUN=false

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helper functions ──────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
  # Print the header block (lines after shebang up to and including the 3rd
  # === delimiter), stripping the leading "# " comment prefix from each line.
  # There are 3 === lines: open, title-wrap close, and block close.
  awk 'NR==1{next} /^# ==/{n++; sub(/^# ?/,""); print; if(n==3) exit; next} {sub(/^# ?/,""); print}' "$0"
  exit 0
}

# ── Cleanup trap (palette + any partial output) ───────────────────────────────
PALETTE=""
cleanup() {
  [[ -n "$PALETTE" && -f "$PALETTE" ]] && rm -f "$PALETTE"
}
trap cleanup EXIT INT TERM

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)    OUTPUT="$2";   shift 2 ;;
    -s|--start)     START="$2";    shift 2 ;;
    -d|--duration)  DURATION="$2"; shift 2 ;;
    -r|--fps)       FPS="$2";      shift 2 ;;
    -w|--width)     WIDTH="$2";    shift 2 ;;
    -l|--loop)      LOOP="$2";     shift 2 ;;
    -q|--quality)   QUALITY="$2";  shift 2 ;;
    -c|--crop)      CROP="$2";     shift 2 ;;
    -S|--speed)     SPEED="$2";    shift 2 ;;
    -R|--reverse)   REVERSE=true;  shift   ;;
    -m|--max-size)  MAX_SIZE="$2"; shift 2 ;;
    -p|--preview)   PREVIEW=true;  shift   ;;
       --force)     FORCE=true;    shift   ;;
       --dry-run)   DRY_RUN=true;  shift   ;;
    -h|--help)      usage ;;
    -*)             error "Unknown option: $1. Run with --help for usage." ;;
    *)              INPUT="$1"; shift ;;
  esac
done

# ── Validate input file ───────────────────────────────────────────────────────
[[ -z "$INPUT" ]] && error "No input file specified. Run with --help for usage."
[[ -f "$INPUT" ]] || error "Input file not found: $INPUT"

# ── Check FFmpeg / ffprobe ────────────────────────────────────────────────────
if ! command -v ffmpeg &>/dev/null; then
  error "FFmpeg is not installed or not in PATH.\n  macOS: brew install ffmpeg\n  Ubuntu: sudo apt install ffmpeg"
fi
if ! command -v ffprobe &>/dev/null; then
  error "ffprobe is not installed. It ships with FFmpeg — reinstall FFmpeg."
fi

# ── FFmpeg version check (best-effort; custom/git builds may not expose semver) ─
FFMPEG_VERSION=$(ffmpeg -version 2>&1 | head -1 | { grep -oE '[0-9]+\.[0-9]+' || true; } | head -1)
if [[ -n "$FFMPEG_VERSION" ]]; then
  FFMPEG_MAJOR=$(echo "$FFMPEG_VERSION" | cut -d. -f1)
  FFMPEG_MINOR=$(echo "$FFMPEG_VERSION" | cut -d. -f2)
  if [[ "$FFMPEG_MAJOR" -lt 2 ]] || { [[ "$FFMPEG_MAJOR" -eq 2 ]] && [[ "$FFMPEG_MINOR" -lt 8 ]]; }; then
    warn "FFmpeg $FFMPEG_VERSION detected. Version 2.8+ is recommended for best quality filters."
  fi
fi

# ── Numeric argument validation ───────────────────────────────────────────────
[[ "$FPS"  =~ ^[0-9]+$          ]] || error "--fps must be a positive integer (got: $FPS)"
[[ "$LOOP" =~ ^[0-9]+$          ]] || error "--loop must be a non-negative integer (got: $LOOP)"
[[ "$WIDTH" =~ ^-?[0-9]+$       ]] || error "--width must be an integer or -1 for auto (got: $WIDTH)"
if [[ -n "$SPEED" ]]; then
  [[ "$SPEED" =~ ^[0-9]*\.?[0-9]+$ ]] || error "--speed must be a positive number (got: $SPEED)"
fi
if [[ -n "$DURATION" ]]; then
  [[ "$DURATION" =~ ^[0-9]*\.?[0-9]+$ ]] || error "--duration must be a positive number in seconds (got: $DURATION)"
fi

# ── Parse --max-size into bytes ───────────────────────────────────────────────
MAX_BYTES=0
if [[ -n "$MAX_SIZE" ]]; then
  SUFFIX="${MAX_SIZE: -1}"
  NUM="${MAX_SIZE%?}"
  [[ "$NUM" =~ ^[0-9]+$ ]] || error "--max-size format must be a number followed by K, M, or G (e.g. 5M)"
  case "${SUFFIX^^}" in
    K) MAX_BYTES=$(( NUM * 1024 )) ;;
    M) MAX_BYTES=$(( NUM * 1024 * 1024 )) ;;
    G) MAX_BYTES=$(( NUM * 1024 * 1024 * 1024 )) ;;
    *) error "--max-size suffix must be K, M, or G (got: $SUFFIX)" ;;
  esac
fi

# ── Derive output name ────────────────────────────────────────────────────────
if [[ -z "$OUTPUT" ]]; then
  BASENAME="${INPUT%.*}"
  OUTPUT="${BASENAME}.gif"
fi

# ── Overwrite protection ──────────────────────────────────────────────────────
if [[ -f "$OUTPUT" ]] && [[ "$FORCE" == false ]] && [[ "$DRY_RUN" == false ]]; then
  read -r -p "$(echo -e "${YELLOW}[WARN]${NC}  '$OUTPUT' already exists. Overwrite? [y/N] ")" CONFIRM
  [[ "${CONFIRM,,}" == "y" ]] || { info "Aborted."; exit 0; }
fi

# ── Quality → palette settings ────────────────────────────────────────────────
case "$QUALITY" in
  low)    MAX_COLORS=64;  DITHER="bayer:bayer_scale=5" ;;
  medium) MAX_COLORS=128; DITHER="bayer:bayer_scale=3" ;;
  high)   MAX_COLORS=256; DITHER="floyd_steinberg"      ;;
  *)      error "Invalid quality level '$QUALITY'. Use: low, medium, high" ;;
esac

# ── Build optional FFmpeg time flags ──────────────────────────────────────────
TIME_FLAGS=""
[[ -n "$START"    ]] && TIME_FLAGS+="-ss $START "
[[ -n "$DURATION" ]] && TIME_FLAGS+="-t $DURATION "

# ── Build video filter chain ──────────────────────────────────────────────────
build_vf() {
  local filters=()

  # 1. Crop (before scale so we work on raw pixels)
  if [[ -n "$CROP" ]]; then
    # Accept WxH+X+Y or W:H:X:Y
    local crop_ffmpeg
    crop_ffmpeg=$(echo "$CROP" | sed 's/x/:/;s/+/:/g')
    filters+=("crop=${crop_ffmpeg}")
  fi

  # 2. Speed (setpts adjusts presentation timestamps)
  if [[ -n "$SPEED" ]]; then
    local pts
    pts=$(awk "BEGIN {printf \"%.6f\", 1/$SPEED}")
    filters+=("setpts=${pts}*PTS")
  fi

  # 3. Scale
  filters+=("scale=${WIDTH}:-2:flags=lanczos")   # -2 ensures even height

  # 4. Reverse
  [[ "$REVERSE" == true ]] && filters+=("reverse")

  # Join with commas
  local IFS=','
  echo "${filters[*]}"
}

VF=$(build_vf)

# ── FFmpeg runner (respects --dry-run) ───────────────────────────────────────
run_ffmpeg() {
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} ffmpeg $*"
  else
    # shellcheck disable=SC2086
    ffmpeg "$@"
  fi
}

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Video → GIF Converter${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
info "Input:    $INPUT"
info "Output:   $OUTPUT"
info "FPS:      $FPS"
info "Width:    ${WIDTH}px"
info "Quality:  $QUALITY (${MAX_COLORS} colors)"
[[ -n "$CROP"     ]] && info "Crop:     $CROP"
[[ -n "$SPEED"    ]] && info "Speed:    ${SPEED}×"
[[ "$REVERSE" == true ]] && info "Reverse:  yes (boomerang)"
[[ -n "$START"    ]] && info "Start:    $START"
[[ -n "$DURATION" ]] && info "Duration: ${DURATION}s"
[[ -n "$MAX_SIZE" ]] && info "Max size: $MAX_SIZE"
[[ "$DRY_RUN" == true ]] && warn "Dry-run mode — no files will be written."
echo ""

# ── Preview mode ──────────────────────────────────────────────────────────────
if [[ "$PREVIEW" == true ]]; then
  PREVIEW_FILE="${OUTPUT%.gif}_preview.png"
  SEEK="${START:-0}"
  info "Preview mode — extracting one frame at ${SEEK}s..."
  run_ffmpeg -v warning -ss "$SEEK" -i "$INPUT" \
    -vf "$VF" \
    -vframes 1 -y "$PREVIEW_FILE"
  if [[ "$DRY_RUN" == false ]]; then
    success "Preview saved: $PREVIEW_FILE"
    # Report dimensions via ffprobe
    DIMS=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height -of csv=p=0 "$PREVIEW_FILE" 2>/dev/null || echo "unknown")
    info "Dimensions: ${DIMS/,/×} px"
  fi
  exit 0
fi

# ── Core conversion function ──────────────────────────────────────────────────
do_convert() {
  local fps="$1" width="$2"
  local vf

  # Rebuild VF with potentially adjusted fps/width for auto-resize loop
  vf=$(WIDTH="$width" build_vf)

  PALETTE=$(mktemp /tmp/palette_XXXXXX.png)

  info "Step 1/2 — Generating optimized color palette  (fps=${fps}, width=${width}px)..."
  # shellcheck disable=SC2086
  run_ffmpeg -v warning $TIME_FLAGS -i "$INPUT" \
    -vf "${vf},palettegen=max_colors=${MAX_COLORS}:stats_mode=diff" \
    -y "$PALETTE"
  [[ "$DRY_RUN" == false ]] && success "Palette created."

  info "Step 2/2 — Rendering GIF..."
  # shellcheck disable=SC2086
  run_ffmpeg -v warning $TIME_FLAGS -i "$INPUT" -i "$PALETTE" \
    -lavfi "${vf} [x]; [x][1:v] paletteuse=dither=${DITHER}" \
    -r "$fps" \
    -loop "$LOOP" \
    -y "$OUTPUT"
}

# ── Auto-resize loop for --max-size ──────────────────────────────────────────
if [[ "$MAX_BYTES" -gt 0 ]]; then
  CURRENT_FPS="$FPS"
  CURRENT_WIDTH="$WIDTH"
  ATTEMPT=0
  MAX_ATTEMPTS=6

  while true; do
    ATTEMPT=$(( ATTEMPT + 1 ))
    [[ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]] && {
      warn "Could not shrink below $MAX_SIZE after $MAX_ATTEMPTS attempts."
      warn "Keeping last output as-is."
      break
    }

    do_convert "$CURRENT_FPS" "$CURRENT_WIDTH"

    if [[ "$DRY_RUN" == true ]]; then
      info "(Dry-run: skipping size check loop)"
      break
    fi

    ACTUAL_BYTES=$(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT")
    ACTUAL_HUMAN=$(du -sh "$OUTPUT" | cut -f1)

    if [[ "$ACTUAL_BYTES" -le "$MAX_BYTES" ]]; then
      info "Size ${ACTUAL_HUMAN} is within limit $MAX_SIZE ✓"
      break
    fi

    warn "Size ${ACTUAL_HUMAN} exceeds $MAX_SIZE — reducing quality..."

    # Reduction strategy: alternate between dropping FPS and shrinking width
    if (( ATTEMPT % 2 == 1 )); then
      CURRENT_FPS=$(( CURRENT_FPS > 5 ? CURRENT_FPS - 3 : CURRENT_FPS ))
      info "  → Reduced FPS to ${CURRENT_FPS}"
    else
      CURRENT_WIDTH=$(( CURRENT_WIDTH > 120 ? CURRENT_WIDTH - 80 : CURRENT_WIDTH ))
      info "  → Reduced width to ${CURRENT_WIDTH}px"
    fi
  done
else
  do_convert "$FPS" "$WIDTH"
fi

# ── Report results ────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
  echo ""
  success "Dry-run complete — no files written."
  echo ""
  exit 0
fi

if [[ -f "$OUTPUT" ]]; then
  SIZE=$(du -sh "$OUTPUT" | cut -f1)

  # Get actual output dimensions via ffprobe
  DIMS=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=p=0 "$OUTPUT" 2>/dev/null || echo "unknown")
  DIMS_FMT="${DIMS/,/×}"

  echo ""
  success "GIF created successfully!"
  echo -e "  ${BOLD}File:${NC}       $OUTPUT"
  echo -e "  ${BOLD}Size:${NC}       $SIZE"
  echo -e "  ${BOLD}Dimensions:${NC} ${DIMS_FMT} px"
  echo ""
else
  error "Conversion failed — output file was not created."
fi
