# Video to GIF Converter

A shell script to convert video files to optimized, high-quality animated GIFs using `ffmpeg`.

## Key Features

- **Customizable**: Control FPS, duration, speed, and output size.
- **Optimized**: Uses `palettegen` and `paletteuse` filters for high-quality color output.
- **Auto-Resize**: `--max-size` option automatically reduces quality/dimensions to meet file size limits.
- **Editing**: Built-in support for cropping and playback speed adjustment.
- **Convenience**: Includes preview mode and dry-run execution.

## Prerequisites

- **FFmpeg**: Must be installed and available in your `PATH`.
  - macOS: `brew install ffmpeg`
  - Ubuntu: `sudo apt install ffmpeg`
  - Fedora: `sudo dnf install ffmpeg`

## Getting Started

### 1. Clone the Repository

```bash
git clone https://github.com/Lunatic16/video-to-gif.git
cd video-to-gif
```

### 2. Make Executable

```bash
chmod +x video_to_gif.sh
```

### 3. Usage

```bash
./video_to_gif.sh [OPTIONS] input.mp4
```

## Options

| Option | Description | Default |
| :--- | :--- | :--- |
| `-o`, `--output` | Output GIF filename | `input.gif` |
| `-s`, `--start` | Start time (e.g., `00:00:05` or `5`) | `0` |
| `-d`, `--duration` | Duration in seconds | Full video |
| `-r`, `--fps` | Frames per second | `15` |
| `-w`, `--width` | Output width in pixels (`-1` = auto) | `480` |
| `-l`, `--loop` | Loop count (`0` = infinite) | `0` |
| `-q`, `--quality` | Quality: `low`, `medium`, `high` | `medium` |
| `-c`, `--crop` | Crop region (`WxH+X+Y`) | None |
| `-S`, `--speed` | Playback speed (e.g., `2.0`) | Normal |
| `-R`, `--reverse` | Reverse the GIF (boomerang effect) | False |
| `-m`, `--max-size` | Target max file size (e.g., `5M`) | Auto-adjust |
| `-p`, `--preview` | Extract single preview frame | False |
| `--force` | Overwrite output without prompting | False |
| `--dry-run` | Print FFmpeg commands only | False |

## Examples

**Basic conversion:**
```bash
./video_to_gif.sh input.mp4
```

**Custom settings (start at 5s, 3s long, 10 fps):**
```bash
./video_to_gif.sh -s 5 -d 3 -r 10 input.mp4
```

**Crop and double speed:**
```bash
./video_to_gif.sh -c 320x320+0+0 -S 2.0 input.mp4
```

**Limit file size to 2MB:**
```bash
./video_to_gif.sh -m 2M input.mp4
```

## Architecture

### Request Lifecycle

1. User invokes `video_to_gif.sh` with arguments.
2. Script validates input and dependencies (`ffmpeg`, `ffprobe`).
3. If `--max-size` is provided, script enters an auto-resize loop.
4. `do_convert` function:
   - Generates an optimized color palette using `palettegen`.
   - Renders the GIF using `paletteuse` with the chosen quality/dithering.
5. If `--preview` is provided, a single PNG frame is extracted.
6. Temporary files (palette) are cleaned up via `trap`.

## Troubleshooting

- **FFmpeg Not Found**: Ensure FFmpeg is installed and in your system PATH.
- **Conversion Failed**: Check if the input file path is correct and accessible.
- **File Size Too Large**: Use the `-m` (max-size) option to automatically scale down the video until it fits the limit.
- **Quality Poor**: Try setting `--quality high` for better color dithering.
