#!/usr/bin/env bash
# =============================================================================
# Convert a video file into an animated GIF using FFmpeg
# =============================================================================
# Usage:
# ./video_to_gif.sh [OPTIONS] input.mp4 [... inputN.mp4]
#
# Options:
# -o, --output FILE       Output GIF filename (default: input filename + .gif)
# -s, --start TIME        Start time (e.g. 00:00:05 or 5) (default: 0)
# -d, --duration TIME     Duration in seconds (default: full video)
# -r, --fps FPS           Frames per second (default: 15)
# -w, --width PX          Output width in pixels (default: 480, -1 = auto)
# -l, --loop N            Loop count: 0=infinite, 1=once, etc. (default: 0)
# -q, --quality LEVEL     Quality: low | medium | high (default: medium)
# --stats-mode MODE       Palette stats mode: diff | full (default: diff)
# -c, --crop WxH+X+Y      Crop region before scaling (e.g. 640x360+0+60)
# -S, --speed FACTOR      Playback speed multiplier (e.g. 2.0 = 2× faster)
# -R, --reverse           Reverse the GIF (boomerang effect)
# -m, --max-size SIZE     Target max file size (e.g. 5M, 500K); auto-reduces
#                         FPS/width until the output fits
# -p, --preview           Extract a single preview frame (PNG) and exit
# -C, --compare           Generate comparison GIFs (low/medium/high quality)
# -O, --optimize          Post-process with gifsicle if available
# --no-progress           Disable progress indicator
# --progress-full         Show full progress bar (default: simple)
# --force                 Overwrite output without prompting
# --dry-run               Print FFmpeg commands without executing them
# -h, --help              Show this help message
#
# Requirements:
# FFmpeg 3.0+ is required. Install with:
#   macOS: brew install ffmpeg gifsicle
#   Ubuntu: sudo apt install ffmpeg gifsicle
#   Fedora: sudo dnf install ffmpeg gifsicle
#   Windows: https://ffmpeg.org/download.html + https://www.lcdf.org/gifsicle/
#
# Optional: gifsicle (for better optimization)
# Optional: bc (for better float math)
#
# Config file: ~/.config/video_to_gif/config
# =============================================================================

set -euo pipefail

shopt -s nullglob 2>/dev/null || true

# -- Config file path ----------------------------------------------------------
CONFIG_DIR="${HOME}/.config/video_to_gif"
CONFIG_FILE="${CONFIG_DIR}/config"

# -- Defaults ------------------------------------------------------------------
FPS=15
WIDTH=480
LOOP=0
QUALITY="medium"
STATS_MODE="diff"
START=""
DURATION=""
OUTPUT=""
CROP=""
SPEED=""
REVERSE=false
MAX_SIZE=""
PREVIEW=false
COMPARE=false
OPTIMIZE=false
PROGRESS_MODE="simple"
FORCE=false
DRY_RUN=false
INTERRUPTED=false
INPUTS=()

# -- Colors --------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# -- Helper functions ----------------------------------------------------------
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
progress() { echo -e "${DIM}[PROGRESS]${NC} $*"; }

# -- Config file loading -----------------------------------------------------
load_config() {
	if [[ -f "$CONFIG_FILE" ]]; then
		while IFS='=' read -r key value; do
			[[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
			key=$(echo "$key" | tr -d '[:space:]')
			value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*//' -e $'s/^["\']]//' -e $'s/["\']$//')
			case "$key" in
				fps) FPS="$value" ;;
				width) WIDTH="$value" ;;
				loop) LOOP="$value" ;;
				quality) QUALITY="$value" ;;
				stats_mode) STATS_MODE="$value" ;;
				optimize) [[ "$value" == "true" || "$value" == "1" ]] && OPTIMIZE=true ;;
				progress) PROGRESS_MODE="$value" ;;
			esac
		done < "$CONFIG_FILE"
	fi
}

# -- FFmpeg capability detection ---------------------------------------------
detect_ffmpeg_caps() {
	local caps_file="${TMP_DIR}/ffmpeg_caps.txt"
	FFMPEG_HAS_LANCZOS=false
	FFMPEG_HAS_PALETTEGEN=false
	FFMPEG_HAS_PALETTEUSE=false
	FFMPEG_HAS_PROGRESS=false
	FFMPEG_HAS_SETPTS=false
	FFMPEG_HAS_REVERSE=false
	FFMPEG_HAS_PALETTE_BASE=false
	FFMPEG_HAS_GIF_ENCODER=false

	if ffmpeg -hide_banner -filters 2>/dev/null > "$caps_file"; then
		grep -q "lanczos" "$caps_file" && FFMPEG_HAS_LANCZOS=true
		grep -q "setpts" "$caps_file" && FFMPEG_HAS_SETPTS=true
		grep -q "reverse" "$caps_file" && FFMPEG_HAS_REVERSE=true
	fi

	if ffmpeg -hide_banner -pix_fmts 2>/dev/null | grep -q "pal8"; then
		FFMPEG_HAS_PALETTE_BASE=true
	fi

	if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "gif"; then
		FFMPEG_HAS_GIF_ENCODER=true
	fi

	# Check for progress support (FFmpeg 4.0+)
	if ffmpeg -hide_banner -help 2>&1 | grep -q "progress"; then
		FFMPEG_HAS_PROGRESS=true
	fi

	# Validate palette filters
	ffmpeg -filters > "${TMP_DIR}/filters.txt" 2>&1
	if grep -q "palettegen" "${TMP_DIR}/filters.txt"; then
		FFMPEG_HAS_PALETTEGEN=true
	fi
	if grep -q "paletteuse" "${TMP_DIR}/filters.txt"; then
		FFMPEG_HAS_PALETTEUSE=true
	fi

	if [[ "$FFMPEG_HAS_LANCZOS" != true ]]; then
		warn "FFmpeg lacks lanczos scaling - using bicubic"
	fi
	if [[ "$FFMPEG_HAS_PALETTEGEN" != true ]] || [[ "$FFMPEG_HAS_PALETTEUSE" != true ]]; then
		error "FFmpeg missing palettegen/paletteuse filters. Need FFmpeg 2.8+"
	fi
}

# -- Input validation ---------------------------------------------------------
validate_inputs() {
	local input="$1"

	# Check file exists and is readable
	[[ -f "$input" ]] || error "Input file not found: $input"
	[[ -r "$input" ]] || error "Input file not readable: $input"

	# Check for video stream
	if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
		-of csv=p=0 "$input" 2>/dev/null | grep -q "video"; then
		error "Input file has no video stream: $input"
	fi

	# Check file size for memory warning (>500MB)
	local filesize
	filesize=$(stat -c%s "$input" 2>/dev/null || stat -f%z "$input" 2>/dev/null || echo 0)
	if [[ $filesize -gt 524288000 ]]; then
		warn "Large input file detected"
		info "Consider using -d to limit duration or -w to reduce width"
	fi
}

# -- Validate speed value -----------------------------------------------------
validate_speed() {
	if [[ -n "$SPEED" ]]; then
		if ! [[ "$SPEED" =~ ^[0-9]+\.?[0-9]*$ ]]; then
			error "--speed must be a positive number. got: $SPEED"
		fi
		local speed_zero
		speed_zero=$(echo "$SPEED == 0" | bc 2>/dev/null) || speed_zero="0"
		if [[ "$speed_zero" -eq 1 ]]; then
			error "--speed must be a positive number. got: $SPEED"
		fi
	fi
}

usage() {
	awk 'NR==1{next} /^# ==/{n++; sub(/^# ?/,""); print; if(n==3) exit; next} {sub(/^# ?/,""); print}' "$0"
	exit 0
}

# -- Cleanup trap setup --------------------------------------------------------
TMP_DIR=$(mktemp -d)
PROGRESS_PIPE="${TMP_DIR}/progress_pipe"

cleanup() {
	rm -rf "$TMP_DIR"
}

interrupt_handler() {
	INTERRUPTED=true
	echo -e "\n${YELLOW}[WARN]${NC} Interrupted by user"
	# Don't delete partial output on SIGINT
	cleanup
	exit 130
}

trap cleanup EXIT

trap interrupt_handler INT TERM

# -- Load config before parsing args -------------------------------------------
load_config

# -- Argument parsing ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
		-o|--output) OUTPUT="$2"; shift 2 ;;
		-s|--start) START="$2"; shift 2 ;;
		-d|--duration) DURATION="$2"; shift 2 ;;
		-r|--fps) FPS="$2"; shift 2 ;;
		-w|--width) WIDTH="$2"; shift 2 ;;
		-l|--loop) LOOP="$2"; shift 2 ;;
		-q|--quality) QUALITY="$2"; shift 2 ;;
		--stats-mode) STATS_MODE="$2"; shift 2 ;;
		-c|--crop) CROP="$2"; shift 2 ;;
		-S|--speed) SPEED="$2"; shift 2 ;;
		-R|--reverse) REVERSE=true; shift ;;
		-m|--max-size) MAX_SIZE="$2"; shift 2 ;;
		-p|--preview) PREVIEW=true; shift ;;
		-C|--compare) COMPARE=true; shift ;;
		-O|--optimize) OPTIMIZE=true; shift ;;
		--no-progress) PROGRESS_MODE="none"; shift ;;
		--progress-full) PROGRESS_MODE="full"; shift ;;
		--force) FORCE=true; shift ;;
		--dry-run) DRY_RUN=true; shift ;;
		-h|--help) usage ;;
		-*) error "Unknown option: $1. Run with --help for usage." ;;
		*) INPUTS+=("$1"); shift ;;
	esac
done

# -- Check for FFmpeg / ffprobe --------------------------------------------------
if ! command -v ffmpeg &>/dev/null; then
	error "FFmpeg not installed.\n macOS: brew install ffmpeg\n Ubuntu: sudo apt install ffmpeg"
fi
if ! command -v ffprobe &>/dev/null; then
	error "ffprobe not found. Ships with FFmpeg - reinstall FFmpeg."
fi

# -- FFmpeg version check --------------------------------------------------------
FFMPEG_VERSION=$(ffmpeg -version 2>&1 | head -1 | { grep -oE '[0-9]+\.[0-9]+' || true; } | head -1)
if [[ -n "$FFMPEG_VERSION" ]]; then
	FFMPEG_MAJOR=$(echo "$FFMPEG_VERSION" | cut -d. -f1)
	FFMPEG_MINOR=$(echo "$FFMPEG_VERSION" | cut -d. -f2)
	if [[ "$FFMPEG_MAJOR" -lt 2 ]] || { [[ "$FFMPEG_MAJOR" -eq 2 ]] && [[ "$FFMPEG_MINOR" -lt 8 ]]; }; then
		warn "FFmpeg $FFMPEG_VERSION detected. Version 2.8+ recommended."
	fi
fi

# -- Detect FFmpeg capabilities -------------------------------------------------
detect_ffmpeg_caps

# -- Check for gifsicle if optimization requested -------------------------------
if [[ "$OPTIMIZE" == true ]] && ! command -v gifsicle &>/dev/null; then
	warn "gifsicle not found. Install for better optimization."
	OPTIMIZE=false
fi

# -- Input validation -----------------------------------------------------------
if [[ ${#INPUTS[@]} -eq 0 ]]; then
	error "No input files specified. Run with --help for usage."
fi

for input in "${INPUTS[@]}"; do
	validate_inputs "$input"
done
validate_speed

# -- Crop validation -----------------------------------------------------------
if [[ -n "$CROP" ]]; then
	[[ "$CROP" =~ ^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$ ]] || error "crop format must be WxH+X+Y. got: ${CROP}"
fi

# -- Parse max-size into bytes ---------------------------------------------------
MAX_BYTES=0
if [[ -n "$MAX_SIZE" ]]; then
	SUFFIX="${MAX_SIZE: -1}"
	NUM="${MAX_SIZE%?}"
	[[ "$NUM" =~ ^[0-9]+$ ]] || error "max-size format: number followed by K, M, or G. example: 5M"
	case "${SUFFIX^^}" in
		K) MAX_BYTES=$(( NUM * 1024 )) ;;
		M) MAX_BYTES=$(( NUM * 1024 * 1024 )) ;;
		G) MAX_BYTES=$(( NUM * 1024 * 1024 * 1024 )) ;;
		*) error "max-size suffix must be K, M, or G. got: ${SUFFIX}" ;;
	esac
fi

# -- Quality to palette settings -------------------------------------------------
get_quality_settings() {
	local q="$1"
	case "$q" in
		low) echo "64 bayer:bayer_scale=5" ;;
		medium) echo "128 bayer:bayer_scale=3" ;;
		high) echo "256 floyd_steinberg" ;;
		*) error "Invalid quality: '$q'. Use: low, medium, high" ;;
	esac
}

# -- Build video filter chain ---------------------------------------------------
build_vf() {
	local width="${1:-$WIDTH}"
	local filters=()

	# Crop
	if [[ -n "$CROP" ]]; then
		local crop_ffmpeg
		crop_ffmpeg=$(echo "$CROP" | sed 's/x/:/;s/+/:/g')
		filters+=("crop=${crop_ffmpeg}")
	fi

	# Speed
	if [[ -n "$SPEED" ]]; then
		local pts
		if command -v bc &>/dev/null; then
			pts=$(bc -l <<< "scale=6; 1/$SPEED" 2>/dev/null || echo "1.0")
		else
			pts=$(awk "BEGIN {printf \"%.6f\", 1/$SPEED}")
		fi
		filters+=("setpts=${pts}*PTS")
	fi

	# Scale
	if [[ "$FFMPEG_HAS_LANCZOS" == true ]]; then
		filters+=("scale=${width}:-2:flags=lanczos")
	else
		filters+=("scale=${width}:-2:flags=bicubic")
	fi

	# Reverse
	[[ "$REVERSE" == true ]] && filters+=("reverse")

	local IFS=','
	echo "${filters[*]}"
}

# -- Progress display handler ---------------------------------------------------
show_progress() {
	local mode="$1"
	local duration="$2"
	local output="$3"

	if [[ "$mode" == "none" ]] || [[ "$DRY_RUN" == true ]]; then
		return
	fi

	if [[ "$mode" == "full" ]] && [[ -n "$duration" ]]; then
		# Parse progress from ffmpeg stderr
		local current_ms=0 total_ms=$((duration * 1000))
		local percent=0 bar_width=30
		while IFS= read -r line; do
			if [[ "$line" =~ ^out_time_ms=([0-9]+) ]]; then
				current_ms="${BASH_REMATCH[1]}"
				percent=$((current_ms * 100 / total_ms))
				[[ $percent -gt 100 ]] && percent=100
				local filled=$((bar_width * percent / 100))
				local empty=$((bar_width - filled))
				printf "\r${CYAN}[%s%s]${NC} %3d%%" \
					"$(printf '%*s' "$filled" '' | tr ' ' '█')" \
					"$(printf '%*s' "$empty" '' | tr ' ' '░')" \
					"$percent"
			elif [[ "$line" =~ ^progress=([a-z]+) ]]; then
				if [[ "${BASH_REMATCH[1]}" == "end" ]]; then
					printf "\r${GREEN}[%s]${NC} 100%%\n" "$(printf '%*s' "$bar_width" '' | tr ' ' '█')"
				fi
			fi
		done
	else
		# Simple mode: just show frames
		local frame=0
		while IFS= read -r line; do
			if [[ "$line" =~ ^frame=([0-9]+) ]]; then
				frame="${BASH_REMATCH[1]}"
				printf "\r${CYAN}[INFO]${NC} Encoding frame %s..." "$frame"
			fi
		done
		printf "\n"
	fi
}

# -- FFmpeg runner with progress -------------------------------------------------
run_ffmpeg_with_progress() {
	local duration="${1:-}"
	shift
	local show_prog=true
	[[ "$PROGRESS_MODE" == "none" ]] && show_prog=false
	[[ "$DRY_RUN" == true ]] && show_prog=false

	if [[ "$show_prog" == true ]] && [[ "$FFMPEG_HAS_PROGRESS" == true ]]; then
		# Use progress pipe
		local progress_args=()
		for arg in "$@"; do
			if [[ "$arg" == "ffmpeg" ]]; then
				progress_args+=("$arg")
			elif [[ "$arg" == "-y" ]]; then
				progress_args+=("-nostdin" "-progress" "pipe:2" "$arg")
			else
				progress_args+=("$arg")
			fi
		done
		if [[ "$DRY_RUN" == true ]]; then
			echo -e "${YELLOW}[DRY-RUN]${NC} ${progress_args[*]}"
		else
			"${progress_args[@]}" 2>&1 | tee /dev/tty | show_progress "$PROGRESS_MODE" "$duration" "" 2>/dev/null || true
		fi
	else
		# Direct execution
		if [[ "$DRY_RUN" == true ]]; then
			echo -e "${YELLOW}[DRY-RUN]${NC} $*"
		else
			"$@"
		fi
	fi
}

# -- Core conversion function ----------------------------------------------------
do_convert() {
	local input="$1"
	local output="$2"
	local q_setting="${3:-$QUALITY}"
	local fps="${4:-$FPS}"
	local width="${5:-$WIDTH}"

	local q_data q_colors q_dither
	q_data=$(get_quality_settings "$q_setting")
	q_colors=$(echo "$q_data" | cut -d' ' -f1)
	q_dither=$(echo "$q_data" | cut -d' ' -f2)

	local time_array=()
	[[ -n "$START" ]] && time_array+=(-ss "$START")
	[[ -n "$DURATION" ]] && time_array+=(-t "$DURATION")

	# Calculate expected duration for progress
	local expected_duration="$DURATION"
	if [[ -z "$expected_duration" ]]; then
		expected_duration=$(ffprobe -v error -select_streams v:0 \
			-show_entries stream=duration -of csv=p=0 "$input" 2>/dev/null || echo "0")
		expected_duration=${expected_duration%.*}
	fi

	local pal_file
	pal_file="${TMP_DIR}/palette_$(date +%s)_${RANDOM}.png"

	info "Generating palette ($q_setting: ${q_colors} colors)..."

	# Memory limit for large videos
	local mem_flags=()
	if [[ -n "${MEMCAP:-}" ]]; then
		mem_flags+=("-max_muxing_queue_size" "9999")
	fi

	local vf
	vf=$(build_vf "$width")

	local pal_args
	pal_args=(
		ffmpeg -v warning -hide_banner
		"${time_array[@]}"
		-i "$input"
		-vf "${vf},palettegen=max_colors=${q_colors}:stats_mode=${STATS_MODE}"
		-y "$pal_file"
	)

	if [[ "$DRY_RUN" == true ]]; then
		echo -e "${YELLOW}[DRY-RUN]${NC} ${pal_args[*]}"
	else
		"${pal_args[@]}"
	fi

	[[ "$DRY_RUN" == false ]] && success "Palette created."

	info "Rendering GIF..."

	local render_args=(
		ffmpeg -v warning -hide_banner
		"${time_array[@]}"
		-i "$input"
		-i "$pal_file"
		-lavfi "${vf} [x]; [x][1:v] paletteuse=dither=${q_dither}"
		-r "$fps"
		-loop "$LOOP"
		"${mem_flags[@]}"
		-y "$output"
	)

	if [[ "$DRY_RUN" == true ]]; then
		echo -e "${YELLOW}[DRY-RUN]${NC} ${render_args[*]}"
	else
		if [[ "$PROGRESS_MODE" != "none" ]]; then
			"${render_args[@]}" 2>&1 | show_progress "$PROGRESS_MODE" "$expected_duration" "$output"
		else
			"${render_args[@]}"
		fi
	fi

	# Run gifsicle optimization if requested and available
	if [[ "$OPTIMIZE" == true ]] && [[ "$DRY_RUN" == false ]] && command -v gifsicle &>/dev/null; then
		info "Optimizing with gifsicle..."
		local tmp_gif="${TMP_DIR}/optimized.gif"
		if gifsicle -O3 --careful --optimize=3 -o "$tmp_gif" "$output" 2>/dev/null; then
			local orig_size new_size
			orig_size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo 0)
			new_size=$(stat -c%s "$tmp_gif" 2>/dev/null || stat -f%z "$tmp_gif" 2>/dev/null || echo 0)
			if [[ $new_size -lt $orig_size ]]; then
				mv "$tmp_gif" "$output"
				success "Optimized: $(numfmt --to=iec "$orig_size" 2>/dev/null || echo "${orig_size}b") → $(numfmt --to=iec "$new_size" 2>/dev/null || echo "${new_size}b")"
			else
				info "Already optimized (gifsicle couldn't improve)"
			fi
		fi
	fi
}

# -- Comparison mode -------------------------------------------------------------
do_compare() {
	local input="$1"
	local baseout dir name

	if [[ -n "$OUTPUT" ]]; then
		baseout="${OUTPUT%.gif}"
	else
		baseout="${input%.*}"
	fi

	dir=$(dirname "$baseout")
	name=$(basename "$baseout")

	info "Comparison mode - generating all quality levels..."

	for q in low medium high; do
		local out="${dir}/${name}_${q}.gif"
		info "Generating $q quality..."
		do_convert "$input" "$out" "$q" "$FPS" "$WIDTH"
	done

	success "Comparison complete:"
	for q in low medium high; do
		local f="${dir}/${name}_${q}.gif"
		[[ -f "$f" ]] && echo "  $q: $f ($(du -sh "$f" | cut -f1))"
	done
}

# -- Preview mode ----------------------------------------------------------------
do_preview() {
	local input="$1"
	local preview_file

	if [[ -n "$OUTPUT" ]]; then
		preview_file="${OUTPUT%.gif}_preview.png"
	else
		preview_file="${input%.*}_preview.png"
	fi

	[[ -f "$preview_file" ]] && [[ "$FORCE" == false ]] && [[ "$DRY_RUN" == false ]] && {
		echo -e "${YELLOW}[WARN]${NC} '$preview_file' exists. Overwrite? [y/N] "
		read -r CONFIRM
		[[ "${CONFIRM,,}" == "y" ]] || { info "Aborted."; return; }
	}

	local seek="${START:-0}"
	local vf
	vf=$(build_vf)

	rm -f "$PROGRESS_PIPE" 2>/dev/null || true

	info "Preview: frame at ${seek}s"

	local preview_args=(
		ffmpeg -v warning -hide_banner
		-ss "$seek"
		-i "$input"
		-vf "$vf"
		-vframes 1
		-y "$preview_file"
	)

	if [[ "$DRY_RUN" == true ]]; then
		echo -e "${YELLOW}[DRY-RUN]${NC} ${preview_args[*]}"
	else
		"${preview_args[@]}"
		success "Preview: $preview_file"
		local dims
		dims=$(ffprobe -v error -select_streams v:0 \
			-show_entries stream=width,height -of csv=p=0 "$preview_file" 2>/dev/null || echo "unknown")
		info "Dimensions: ${dims/,/×} px"
	fi
}

# -- Auto-resize loop for --max-size ---------------------------------------------
do_with_resize() {
	local input="$1"
	local output="$2"

	local current_fps="$FPS"
	local current_width="$WIDTH"
	local attempt=0
	local max_attempts=6

	while true; do
		attempt=$((attempt + 1))
		if [[ $attempt -gt $max_attempts ]]; then
			warn "Could not shrink below $MAX_SIZE after $max_attempts attempts."
			break
		fi

		do_convert "$input" "$output" "$QUALITY" "$current_fps" "$current_width"

		if [[ "$DRY_RUN" == true ]]; then
			info "(Dry-run: skipping size check)"
			break
		fi

		local actual_bytes actual_human
		actual_bytes=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output")
		actual_human=$(du -sh "$output" | cut -f1)

		if [[ "$actual_bytes" -le "$MAX_BYTES" ]]; then
			info "Size $actual_human within $MAX_SIZE limit"
			break
		fi

		warn "Size $actual_human > $MAX_SIZE, reducing quality..."

		if (( attempt % 2 == 1 )); then
			current_fps=$(( current_fps > 5 ? current_fps - 3 : current_fps ))
			info " → FPS: ${current_fps}"
		else
			current_width=$(( current_width > 120 ? current_width - 80 : current_width ))
			info " → Width: ${current_width}px"
		fi
	done
}

# -- Process single file ----------------------------------------------------------
process_file() {
	local input="$1"
	local output="$OUTPUT"

	# Derive output if not specified
	if [[ -z "$output" ]]; then
		output="${input%.*}.gif"
	fi

	# Overwrite check
	if [[ -f "$output" ]] && [[ "$FORCE" == false ]] && [[ "$DRY_RUN" == false ]]; then
		echo -e "${YELLOW}[WARN]${NC} '$output' exists. Overwrite? [y/N] "
		read -r CONFIRM
		[[ "${CONFIRM,,}" == "y" ]] || { info "Skipped: $input"; return; }
	fi

	# Header per file
	echo ""
	echo -e "${BOLD}--------------------------------------------------${NC}"
	echo -e "${BOLD} Video → GIF${NC}"
	echo -e "${BOLD}--------------------------------------------------${NC}"
	echo ""
	info "Input: $input"
	info "Output: $output"
	info "Settings: $QUALITY quality, ${FPS}fps, ${WIDTH}px"
	[[ -n "$CROP" ]] && info "Crop: $CROP"
	[[ -n "$SPEED" ]] && info "Speed: ${SPEED}×"
	[[ "$REVERSE" == true ]] && info "Reverse: yes"
	[[ -n "$START" ]] && info "Start: $START"
	[[ -n "$DURATION" ]] && info "Duration: ${DURATION}s"
	[[ -n "$MAX_SIZE" ]] && info "Max size: $MAX_SIZE"
	[[ "$OPTIMIZE" == true ]] && info "Optimization: gifsicle"
	[[ "$DRY_RUN" == true ]] && warn "Dry-run mode - no files written"
	echo ""

	# Route to appropriate mode
	if [[ "$PREVIEW" == true ]]; then
		do_preview "$input"
	elif [[ "$COMPARE" == true ]]; then
		do_compare "$input"
	elif [[ "$MAX_BYTES" -gt 0 ]]; then
		do_with_resize "$input" "$output"
	else
		do_convert "$input" "$output"
	fi

	# Report results (if applicable)
	if [[ "$DRY_RUN" == true ]]; then
		echo ""
		success "Dry-run complete"
	else
		if [[ "$PREVIEW" == true ]]; then
			: # Already reported in do_preview
		elif [[ "$COMPARE" == true ]]; then
			: # Already reported in do_compare
		else
			if [[ -f "$output" ]]; then
				local size dims
				size=$(du -sh "$output" | cut -f1)
				dims=$(ffprobe -v error -select_streams v:0 \
					-show_entries stream=width,height -of csv=p=0 "$output" 2>/dev/null || echo "unknown")
				echo ""
				success "GIF created: $output"
				echo -e " ${BOLD}Size:${NC} $size"
				echo -e " ${BOLD}Dimensions:${NC} ${dims/,/×} px"
				echo ""
			fi
		fi
	fi
}

# -- Main: process all inputs -----------------------------------------------------
for input in "${INPUTS[@]}"; do
	process_file "$input"
done

if [[ "$INTERRUPTED" == true ]]; then
	exit 130
fi
