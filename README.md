# Video to GIF Converter

A lightweight shell-based utility designed to transform video files into high-quality, optimized animated GIFs. It acts as a wrapper around `ffmpeg`, automating complex filtering tasks like palette generation to ensure superior color output compared to standard conversions.

## Key Features

- **Automated Palette Generation**: Two-pass encoding for optimal GIF color quality.
- **Auto-Resize & FPS Scaling**: Intelligent reduction of frame rate and dimensions to meet custom file size limits.
- **Versatile Editing**: Supports cropping, playback speed adjustment, and reverse playback.
- **Preview Mode**: Extract a single frame to verify output dimensions and crop settings before encoding.
- **Robustness**: Validates video streams and handles temporary files safely.

## Tech Stack

- **Primary Language**: Rust (performance, safety, and cross-platform reliability)
- **Wrapper Script**: POSIX-compliant shell script (legacy/alternative)
- **Core Utility**: FFmpeg / ffprobe

## Prerequisites

- **FFmpeg**: Must be installed and available in the system `PATH`.
  - macOS: `brew install ffmpeg`
  - Ubuntu: `sudo apt install ffmpeg`
  - Fedora: `sudo dnf install ffmpeg`
  - Windows: [https://ffmpeg.org/download.html](https://ffmpeg.org/download.html)

## Getting Started

### 1. Clone the Repository

```bash
git clone https://github.com/your-username/video-to-gif.git
cd video-to-gif
```

### 2. Build the Project

Ensure you have Rust installed (via [rustup](https://rustup.rs/)).

```bash
# Development Build
cargo build

# Release Build (recommended for performance)
cargo build --release
```

## Usage

You can use the compiled binary directly or the provided shell script wrapper.

```bash
# Using cargo
cargo run -- [OPTIONS] <input_file>

# Using the shell wrapper
chmod +x video_to_gif.sh
./video_to_gif.sh [OPTIONS] <input_file>
```

### Options

| Option | Description | Default |
| :--- | :--- | :--- |
| `-o, --output` | Output GIF filename | `input_file.gif` |
| `-s, --start` | Start time (e.g., 5, 00:00:05) | `0` |
| `-d, --duration` | Duration in seconds | Full video |
| `-r, --fps` | Frames per second | `15` |
| `-w, --width` | Output width in pixels (-1 = auto) | `480` |
| `-l, --loop` | Loop count (0=infinite, 1=once) | `0` |
| `-q, --quality` | Quality: low, medium, high | `medium` |
| `--stats-mode` | Palette stats mode: diff, full | `diff` |
| `-c, --crop` | Crop region: WxH+X+Y | - |
| `-S, --speed` | Playback speed multiplier | - |
| `-R, --reverse` | Reverse the GIF (boomerang) | false |
| `-m, --max-size` | Target max file size (e.g., 5M) | - |
| `-p, --preview` | Extract a single preview frame | false |
| `--force` | Overwrite output without prompting | false |
| `--dry-run` | Print FFmpeg commands only | false |
| `-h, --help` | Show help message | - |

## Architecture

### Directory Structure

```
├── src/
│   └── main.rs       # Core logic, CLI parsing, and FFmpeg orchestration
├── video_to_gif.sh   # Legacy shell wrapper
├── Cargo.toml        # Dependencies and release optimizations
└── README.md         # This file
```

### Request Lifecycle

1. Argument parsing & validation (checks for video stream)
2. Quality-to-palette settings mapping
3. Optional Preview mode: extract single frame and exit
4. Core conversion logic:
   - Palette Generation (Step 1): `palettegen` filter
   - Render (Step 2): `paletteuse` filter
5. Optional Auto-resize loop (if `--max-size` is provided):
   - Iteratively degrades quality until limit is met
6. Final output reported with dimensions and file size

## Available Scripts

| Command | Description |
| :--- | :--- |
| `./video_to_gif.sh input.mp4` | Basic conversion |
| `./video_to_gif.sh -s 5 -d 3 -r 10 input.mp4` | Custom time, duration, FPS |
| `./video_to_gif.sh -m 2M input.mp4` | Limit output size to 2MB |
| `./video_to_gif.sh -p input.mp4` | Generate preview for cropping |

## Troubleshooting

### FFmpeg Errors
- **"FFmpeg is not installed"**: Ensure `ffmpeg` and `ffprobe` are in your `$PATH`.
- **"Input file does not contain a valid video stream"**: Verify your input file is a supported video format via `ffprobe`.

### Palette generation fails
- Check disk space in `/tmp` (or the default temporary directory for your user).

### Size limit not met
- If `MAX_ATTEMPTS` is reached, the script will warn you. Consider providing a larger size limit or reducing the source video length.

## License

MIT
