# video_to_gif.sh

A production-quality Bash script to convert video files into optimized animated GIFs using FFmpeg. Features intelligent palette generation, size optimization, batch processing, and gifsicle post-processing.

## Features

- **High-Quality Output**: Lanczos scaling, optimized color palette generation, Floyd-Steinberg or Bayer dithering
- **Smart Optimization**: Automatic quality reduction to meet file size targets
- **Batch Processing**: Convert multiple videos in one command
- **gifsicle Integration**: Optional post-processing for 20-40% smaller files
- **Comparison Mode**: Generate low/medium/high quality versions side-by-side
- **Config File Support**: Persistent default settings
- **Progress Indicators**: Real-time conversion progress (simple or full bar)
- **Memory Safety**: Warnings for large files, auto-limits for memory-intensive operations
- **Crop & Transform**: Crop regions, speed adjustment, reverse playback

## Requirements

- **FFmpeg 2.8+** (3.0+ recommended) with `palettegen` and `paletteuse` filters
- **ffprobe** (ships with FFmpeg)
- **bash** 4.0+ with `shopt` support for batch globbing
- **Optional:** `gifsicle` for additional optimization
- **Optional:** `bc` for improved floating-point math

### Installing Dependencies

**macOS:**
```bash
brew install ffmpeg gifsicle
```

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install ffmpeg gifsicle bc
```

**Fedora:**
```bash
sudo dnf install ffmpeg gifsicle bc
```

**Windows:**
- FFmpeg: https://ffmpeg.org/download.html
- gifsicle: https://www.lcdf.org/gifsicle/

## Installation

```bash
# Clone or download the script
git clone <repo-url>
cd video-to-gif

# Make executable
chmod +x video_to_gif.sh

# Optional: Add to PATH
sudo ln -s "$(pwd)/video_to_gif.sh" /usr/local/bin/video-to-gif
```

## Quick Start

```bash
# Convert video to GIF with defaults (480px, 15fps, medium quality)
./video_to_gif.sh video.mp4

# High quality, specific width
./video_to_gif.sh -q high -w 320 video.mp4

# Crop region, 2x speed
./video_to_gif.sh -c 640x360+0+60 -S 2.0 video.mp4

# Enable gifsicle optimization
./video_to_gif.sh -O video.mp4

# Preview frame before converting
./video_to_gif.sh -p video.mp4

# Generate comparison GIFs (low/medium/high)
./video_to_gif.sh --compare video.mp4
```

## Usage

```
./video_to_gif.sh [OPTIONS] input.mp4 [input2.mp4 ...]
```

### Options

| Option | Long | Description | Default |
|--------|------|-------------|---------|
| `-o` | `--output FILE` | Output GIF filename | input + .gif |
| `-s` | `--start TIME` | Start time (00:00:05 or 5) | 0 |
| `-d` | `--duration TIME` | Duration in seconds | Full video |
| `-r` | `--fps FPS` | Frames per second | 15 |
| `-w` | `--width PX` | Output width in pixels | 480 (-1 = auto) |
| `-l` | `--loop N` | Loop count (0=infinite, 1=once) | 0 |
| `-q` | `--quality LEVEL` | low, medium, or high | medium |
| | `--stats-mode MODE` | Palette stats: diff or full | diff |
| `-c` | `--crop WxH+X+Y` | Crop before scaling (e.g., 640x360+0+60) | — |
| `-S` | `--speed FACTOR` | Playback speed multiplier | — |
| `-R` | `--reverse` | Reverse playback (boomerang) | false |
| `-m` | `--max-size SIZE` | Target max size (e.g., 5M, 500K) | — |
| `-p` | `--preview` | Extract one preview frame | — |
| `-C` | `--compare` | Generate quality comparison | — |
| `-O` | `--optimize` | Post-process with gifsicle | false |
| | `--no-progress` | Disable progress indicator | — |
| | `--progress-full` | Full progress bar | simple |
| | `--force` | Overwrite without prompting | — |
| | `--dry-run` | Print commands, don't execute | — |
| `-h` | `--help` | Show help message | — |

### Quality Levels

| Level | Colors | Dithering | Best For |
|-------|--------|-----------|----------|
| low | 64 | Bayer (scale 5) | Small files, previews |
| medium | 128 | Bayer (scale 3) | Balance (default) |
| high | 256 | Floyd-Steinberg | Maximum quality |

## Configuration File

Create `~/.config/video_to_gif/config` for persistent defaults:

```bash
mkdir -p ~/.config/video_to_gif
cat > ~/.config/video_to_gif/config << 'EOF'
# Default settings for video_to_gif.sh
fps=20
width=320
quality=high
loop=0
stats_mode=diff
optimize=true
progress=simple
EOF
```

**Config options:**
- `fps` — Default frame rate
- `width` — Default output width
- `quality` — Default quality level
- `loop` — Default loop count
- `stats_mode` — `diff` or `full` palette generation
- `optimize` — `true`/`false` or `1`/`0` for gifsicle
- `progress` — `simple`, `full`, or `none`

Command-line options override config file values.

## Examples

### Basic Conversion
```bash
# Default settings
./video_to_gif.sh video.mp4
# Output: video.gif (480px, 15fps, medium quality, ~200-500KB)
```

### High-Quality GIF
```bash
./video_to_gif.sh -q high -w 640 -r 30 video.mp4
# 640px width, 30fps, 256 colors, Floyd-Steinberg dithering
```

### Extract Segment
```bash
# Start at 5 seconds, 3 seconds duration
./video_to_gif.sh -s 5 -d 3 video.mp4

# Or with HH:MM:SS format
./video_to_gif.sh -s 00:01:30 -d 10 video.mp4
```

### Crop Region
```bash
# Crop 640x360 starting at x=0, y=60
./video_to_gif.sh -c 640x360+0+60 video.mp4
```

### Speed Adjustment
```bash
# 2x faster playback
./video_to_gif.sh -S 2.0 video.mp4

# Half speed (0.5x)
./video_to_gif.sh -S 0.5 video.mp4
```

### Boomerang Effect
```bash
# Reverse the playback
./video_to_gif.sh -R video.mp4

# Combine with speed
./video_to_gif.sh -R -S 1.5 video.mp4
```

### File Size Limit
```bash
# Auto-reduce quality until under 2MB
./video_to_gif.sh -m 2M video.mp4

# Target 500KB
./video_to_gif.sh -m 500K -q medium video.mp4
```

### Preview Frame
```bash
# Extract one frame at start time
./video_to_gif.sh -p video.mp4

# Preview at specific time
./video_to_gif.sh -p -s 30 video.mp4
# Output: video_preview.png
```

### Comparison Mode
```bash
./video_to_gif.sh --compare video.mp4
# Generates: video_low.gif, video_medium.gif, video_high.gif
```

### Batch Processing
```bash
# Convert all MP4s in directory
./video_to_gif.sh *.mp4

# With same settings
./video_to_gif.sh -q low -w 240 *.mp4
```

### With Optimization
```bash
./video_to_gif.sh -O video.mp4
# Creates GIF, then optimizes with gifsicle -O3
# Shows size reduction: 500KB → 350KB
```

### Dry Run
```bash
# Print FFmpeg commands without executing
./video_to_gif.sh --dry-run -q high video.mp4
```

## Architecture

### Conversion Pipeline

```
Input Video
    ↓
    [Time Flags] --start, --duration
    ↓
    [Video Filters]
      ├── Crop (--crop)
      ├── Speed (--speed → setpts)
      ├── Scale (width × proportional height)
      └── Reverse (--reverse → reverse filter)
    ↓
    [Palette Generation]
      ├── palettegen (max_colors based on quality)
      └── stats_mode (diff or full)
    ↓
    [GIF Encoding]
      ├── paletteuse (dithering)
      └── Loop/Frame rate
    ↓
    [Optional: gifsicle -O3]
    ↓
    Output GIF
```

### Filter Chain

FFmpeg filters applied in order:
1. `crop` — Region extraction
2. `setpts` — Speed adjustment (PTS manipulation)
3. `scale` — Width/height with lanczos/bicubic
4. `reverse` — Backward playback

### Palette Generation

- `diff` mode: analyzes only changed pixels between frames (smaller palette, faster)
- `full` mode: analyzes entire frame (larger palette, more accurate)

## Troubleshooting

### "Input file has no video stream"
Video is corrupted or has no video track. Verify with:
```bash
ffprobe -v error -select_streams v:0 -show_entries stream=codec_type input.mp4
```

### "FFmpeg missing palettegen/paletteuse filters"
FFmpeg too old or custom build without filters. Reinstall:
```bash
# Ubuntu
sudo apt install ffmpeg --reinstall

# macOS
brew reinstall ffmpeg
```

### Large file warning (>500MB)
Script warns about memory usage. Solutions:
- Use `-d` to limit duration
- Use `-w` to reduce width
- Run with `MEMCAP=1` to enable queue limits

### gifsicle not found but expected
Install gifsicle or use `--dry-run` to preview:
```bash
# Ubuntu/Debian
sudo apt install gifsicle

# macOS
brew install gifsicle
```

### GIF too large
```bash
# Try file size targeting
./video_to_gif.sh -m 1M video.mp4

# Or manually reduce quality
./video_to_gif.sh -q low -w 320 -r 10 video.mp4
```

### Interrupted conversion preserves partial file
SIGINT (Ctrl+C) handler prevents cleanup of partial output, letting you resume or inspect. Remove partial file manually if needed.

## File Size Optimization Tips

| Factor | Impact | Recommend |
|--------|--------|-----------|
| Width | Quadratic | 320px for web, 480px for sharing |
| FPS | Linear | 10-15fps for most content |
| Duration | Linear | Trim to essential frames |
| Palette | Logarithmic | 128 colors often sufficient |
| gifsicle | 20-40% smaller | Always use -O flag |

### Example Optimizations

```bash
# Web-optimized: 100-300KB typical
./video_to_gif.sh -q low -w 320 -r 10 -m 500K video.mp4

# Social-optimized: 300KB-1MB
./video_to_gif.sh -w 480 -r 15 -O video.mp4

# Preview: tiny file
./video_to_gif.sh -q low -w 240 -r 8 video.mp4
```

## Script Structure

```
video_to_gif.sh
├── Config Loading (~/.config/video_to_gif/config)
├── Capability Detection (FFmpeg, gifsicle)
├── Input Validation (exists, readable, video stream)
├── Argument Parsing
├── Video Filter Chain Build
├── Core Conversion (do_convert)
│   ├── Palette Generation (palettegen)
│   └── GIF Rendering (paletteuse)
├── Optional: gifsicle Optimization
└── Output Reporting
```

## Contributing

Bug reports and pull requests welcome. Development notes:

- Test with `bash -n video_to_gif.sh` for syntax
- Test with `shellcheck video_to_gif.sh` for best practices
- Verify FFmpeg compatibility across versions 2.8–7.x

## License

MIT License — see script header for details.
