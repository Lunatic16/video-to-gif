use clap::Parser;
use colored::*;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

// ── CLI definition ─────────────────────────────────────────────────────────
#[derive(Parser, Debug)]
#[command(
    name = "video_to_gif",
    about = "Convert a video file into an animated GIF using FFmpeg",
    long_about = "Convert a video file into an animated GIF using FFmpeg.\n\
    \n\
    Requirements:\n  \
      FFmpeg must be installed.\n  \
      macOS:   brew install ffmpeg\n  \
      Ubuntu:  sudo apt install ffmpeg\n  \
      Fedora:  sudo dnf install ffmpeg\n  \
      Windows: https://ffmpeg.org/download.html"
)]
struct Args {
    /// Input video file
    input: PathBuf,

    /// Output GIF filename (default: input filename + .gif)
    #[arg(short, long, value_name = "FILE")]
    output: Option<PathBuf>,

    /// Start time (e.g. 00:00:05 or 5)
    #[arg(short, long, value_name = "TIME")]
    start: Option<String>,

    /// Duration in seconds
    #[arg(short, long, value_name = "TIME")]
    duration: Option<String>,

    /// Frames per second
    #[arg(short = 'r', long, value_name = "FPS", default_value_t = 15)]
    fps: u32,

    /// Output width in pixels (-1 = auto)
    #[arg(short, long, value_name = "PX", default_value_t = 480)]
    width: i32,

    /// Loop count: 0=infinite, 1=play once, etc.
    #[arg(short, long, value_name = "N", default_value_t = 0)]
    loop_count: u32,

    /// Quality level: low | medium | high
    #[arg(short, long, value_name = "LEVEL", default_value = "medium")]
    quality: String,

    /// Palette stats mode: diff | full
    #[arg(long, value_name = "MODE", default_value = "diff")]
    stats_mode: String,

    /// Crop region before scaling, e.g. 640x360+0+60
    #[arg(short, long, value_name = "WxH+X+Y")]
    crop: Option<String>,

    /// Playback speed multiplier (e.g. 2.0 = 2x faster)
    #[arg(short = 'S', long, value_name = "FACTOR")]
    speed: Option<f64>,

    /// Reverse the GIF (boomerang effect)
    #[arg(short = 'R', long)]
    reverse: bool,

    /// Target max file size (e.g. 5M, 500K); auto-reduces FPS/width until output fits
    #[arg(short = 'm', long, value_name = "SIZE")]
    max_size: Option<String>,

    /// Extract a single preview frame (PNG) and exit
    #[arg(short, long)]
    preview: bool,

    /// Overwrite output without prompting
    #[arg(long)]
    force: bool,

    /// Print FFmpeg commands without executing them
    #[arg(long)]
    dry_run: bool,
}

// ── Quality settings ───────────────────────────────────────────────────────
struct QualitySettings {
    max_colors: u32,
    dither: String,
}

fn quality_settings(quality: &str) -> Result<QualitySettings, String> {
    match quality {
        "low"    => Ok(QualitySettings { max_colors: 64,  dither: "bayer:bayer_scale=5".into() }),
        "medium" => Ok(QualitySettings { max_colors: 128, dither: "bayer:bayer_scale=3".into() }),
        "high"   => Ok(QualitySettings { max_colors: 256, dither: "floyd_steinberg".into()      }),
        other    => Err(format!("Invalid quality level '{}'. Use: low, medium, high", other)),
    }
}

// ── Parse max-size string -> bytes ──────────────────────────────────────────
fn parse_max_size(s: &str) -> Result<u64, String> {
    if s.is_empty() {
        return Ok(0);
    }
    let (num_str, suffix) = s.split_at(s.len() - 1);
    let num: u64 = num_str.parse()
        .map_err(|_| "--max-size format must be a number followed by K, M, or G (e.g. 5M)".to_string())?;
    match suffix.to_uppercase().as_str() {
        "K" => Ok(num * 1024),
        "M" => Ok(num * 1024 * 1024),
        "G" => Ok(num * 1024 * 1024 * 1024),
        _   => Err(format!("--max-size suffix must be K, M, or G (got: {})", suffix)),
    }
}

// ── Validate crop format ───────────────────────────────────────────────────
fn validate_crop(crop: &str) -> Result<(), String> {
    let valid = crop.chars().all(|c| c.is_ascii_digit() || c == 'x' || c == '+')
        && crop.contains('x')
        && crop.matches('+').count() == 2;
    if !valid {
        return Err(format!("--crop format must be WxH+X+Y (got: {})", crop));
    }
    Ok(())
}

// ── Convert crop WxH+X+Y -> FFmpeg crop=W:H:X:Y ────────────────────────────
fn crop_to_ffmpeg(crop: &str) -> String {
    crop.replacen('x', ":", 1).replace('+', ":")
}

// ── Build the video filter chain ───────────────────────────────────────────
fn build_vf(width: i32, crop: Option<&str>, speed: Option<f64>, reverse: bool) -> String {
    let mut filters: Vec<String> = Vec::new();

    if let Some(c) = crop {
        filters.push(format!("crop={}", crop_to_ffmpeg(c)));
    }

    if let Some(s) = speed {
        let pts = 1.0 / s;
        filters.push(format!("setpts={:.6}*PTS", pts));
    }

    filters.push(format!("scale={}:-2:flags=lanczos", width));

    if reverse {
        filters.push("reverse".to_string());
    }

    filters.join(",")
}

// ── Logging helpers ────────────────────────────────────────────────────────
fn info(msg: &str)    { println!("{} {}", "[INFO]".cyan(), msg); }
fn success(msg: &str) { println!("{} {}", "[OK]".green(), msg); }
fn warn(msg: &str)    { println!("{} {}", "[WARN]".yellow(), msg); }
fn error_exit(msg: &str) -> ! {
    eprintln!("{} {}", "[ERROR]".red(), msg);
    std::process::exit(1);
}

// ── Run (or dry-run) an FFmpeg command ────────────────────────────────────
fn run_ffmpeg(args: &[&str], dry_run: bool) -> Result<(), String> {
    if dry_run {
        println!("{} ffmpeg {}", "[DRY-RUN]".yellow(), args.join(" "));
        return Ok(());
    }
    let status = Command::new("ffmpeg")
        .args(args)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|e| format!("Failed to run ffmpeg: {}", e))?;
    if !status.success() {
        return Err(format!("FFmpeg exited with status {}", status));
    }
    Ok(())
}

// ── Check whether input has a valid video stream ──────────────────────────
fn has_video_stream(input: &Path) -> bool {
    Command::new("ffprobe")
        .args([
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_type",
            "-of", "csv=p=0",
            input.to_str().unwrap_or(""),
        ])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("video"))
        .unwrap_or(false)
}

// ── Get dimensions of a media file via ffprobe ────────────────────────────
fn get_dims(path: &Path) -> String {
    Command::new("ffprobe")
        .args([
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height",
            "-of", "csv=p=0",
            path.to_str().unwrap_or(""),
        ])
        .output()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .trim()
                .replace(',', "x")
        })
        .unwrap_or_else(|_| "unknown".to_string())
}

// ── Get file size in bytes ─────────────────────────────────────────────────
fn file_size(path: &Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

// ── Human-readable file size ───────────────────────────────────────────────
fn human_size(bytes: u64) -> String {
    if bytes >= 1024 * 1024 * 1024 {
        format!("{:.1}G", bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    } else if bytes >= 1024 * 1024 {
        format!("{:.1}M", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.1}K", bytes as f64 / 1024.0)
    } else {
        format!("{}B", bytes)
    }
}

// ── Tiny pseudo-random suffix for temp palette filenames ──────────────────
fn rand_hex() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    format!("{:08x}", t)
}

// ── Core conversion ────────────────────────────────────────────────────────
#[allow(clippy::too_many_arguments)]
fn do_convert(
    fps: u32,
    width: i32,
    input: &Path,
    output: &Path,
    time_flags: &[String],
    crop: Option<&str>,
    speed: Option<f64>,
    reverse: bool,
    max_colors: u32,
    stats_mode: &str,
    dither: &str,
    loop_count: u32,
    tmp_dir: &Path,
    dry_run: bool,
) -> Result<(), String> {
    let vf = build_vf(width, crop, speed, reverse);
    let palette = tmp_dir.join(format!("palette_{}.png", rand_hex()));
    let palette_str = palette.to_string_lossy().to_string();

    info(&format!(
        "Step 1/2 — Generating optimized color palette  (fps={}, width={}px, mode={})...",
        fps, width, stats_mode
    ));

    let pal_vf = format!("{},palettegen=max_colors={}:stats_mode={}", vf, max_colors, stats_mode);
    let mut pal_args: Vec<String> = vec!["-v".into(), "warning".into()];
    pal_args.extend_from_slice(time_flags);
    pal_args.extend([
        "-i".into(), input.to_string_lossy().to_string(),
        "-vf".into(), pal_vf,
        "-y".into(), palette_str.clone(),
    ]);
    run_ffmpeg(
        &pal_args.iter().map(String::as_str).collect::<Vec<_>>(),
        dry_run,
    )?;
    if !dry_run { success("Palette created."); }

    info("Step 2/2 — Rendering GIF...");

    let gif_lavfi = format!("{} [x]; [x][1:v] paletteuse=dither={}", vf, dither);
    let mut gif_args: Vec<String> = vec!["-v".into(), "warning".into()];
    gif_args.extend_from_slice(time_flags);
    gif_args.extend([
        "-i".into(), input.to_string_lossy().to_string(),
        "-i".into(), palette_str,
        "-lavfi".into(), gif_lavfi,
        "-r".into(), fps.to_string(),
        "-loop".into(), loop_count.to_string(),
        "-y".into(), output.to_string_lossy().to_string(),
    ]);
    run_ffmpeg(
        &gif_args.iter().map(String::as_str).collect::<Vec<_>>(),
        dry_run,
    )
}

// ── Entry point ────────────────────────────────────────────────────────────
fn main() {
    let args = Args::parse();

    // Validate input
    if !args.input.exists() {
        error_exit(&format!("Input file not found: {}", args.input.display()));
    }
    if !has_video_stream(&args.input) {
        error_exit(&format!(
            "Input file does not contain a valid video stream: {}",
            args.input.display()
        ));
    }

    // Check ffmpeg / ffprobe
    for tool in &["ffmpeg", "ffprobe"] {
        if Command::new(tool).arg("-version").output().is_err() {
            error_exit(&format!(
                "{} is not installed or not in PATH.\n  macOS: brew install ffmpeg\n  Ubuntu: sudo apt install ffmpeg",
                tool
            ));
        }
    }

    // FFmpeg version check (best-effort)
    if let Ok(out) = Command::new("ffmpeg").arg("-version").output() {
        let ver_text = String::from_utf8_lossy(&out.stdout);
        if let Some(ver) = ver_text.split_whitespace().nth(2) {
            let parts: Vec<&str> = ver.splitn(3, '.').collect();
            if parts.len() >= 2 {
                let major: u32 = parts[0].parse().unwrap_or(99);
                let minor: u32 = parts[1].parse().unwrap_or(99);
                if major < 2 || (major == 2 && minor < 8) {
                    warn(&format!(
                        "FFmpeg {}.{} detected. Version 2.8+ is recommended for best quality filters.",
                        major, minor
                    ));
                }
            }
        }
    }

    // Validate crop format
    if let Some(ref c) = args.crop {
        if let Err(e) = validate_crop(c) {
            error_exit(&e);
        }
    }

    // Parse max-size
    let max_bytes = if let Some(ref s) = args.max_size {
        match parse_max_size(s) {
            Ok(b) => b,
            Err(e) => error_exit(&e),
        }
    } else {
        0
    };

    // Derive quality settings
    let qs = match quality_settings(&args.quality) {
        Ok(q) => q,
        Err(e) => error_exit(&e),
    };

    // Derive output path
    let output: PathBuf = match &args.output {
        Some(o) => o.clone(),
        None => {
            let stem = args.input.file_stem().unwrap_or_default();
            let parent = args.input.parent().unwrap_or(Path::new("."));
            parent.join(format!("{}.gif", stem.to_string_lossy()))
        }
    };

    // Overwrite protection
    if output.exists() && !args.force && !args.dry_run {
        print!(
            "{} '{}' already exists. Overwrite? [y/N] ",
            "[WARN]".yellow(),
            output.display()
        );
        io::stdout().flush().unwrap();
        let mut confirm = String::new();
        io::stdin().read_line(&mut confirm).unwrap();
        if confirm.trim().to_lowercase() != "y" {
            info("Aborted.");
            return;
        }
    }

    // Build time flags
    let mut time_flags: Vec<String> = Vec::new();
    if let Some(ref s) = args.start    { time_flags.extend(["-ss".into(), s.clone()]); }
    if let Some(ref d) = args.duration { time_flags.extend(["-t".into(), d.clone()]); }

    // Temp dir (auto-cleaned on drop)
    let tmp_dir = tempfile::tempdir().unwrap_or_else(|e| {
        error_exit(&format!("Could not create temp directory: {}", e));
    });

    // Print header
    println!();
    println!("{}", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━".bold());
    println!("{}", "  Video -> GIF Converter".bold());
    println!("{}", "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━".bold());
    println!();
    info(&format!("Input:    {}", args.input.display()));
    info(&format!("Output:   {}", output.display()));
    info(&format!("FPS:      {}", args.fps));
    info(&format!("Width:    {}px", args.width));
    info(&format!("Quality:  {} ({} colors)", args.quality, qs.max_colors));
    if let Some(ref c) = args.crop     { info(&format!("Crop:     {}", c)); }
    if let Some(ref s) = args.speed    { info(&format!("Speed:    {}x", s)); }
    if args.reverse                    { info("Reverse:  yes (boomerang)"); }
    if let Some(ref s) = args.start    { info(&format!("Start:    {}", s)); }
    if let Some(ref d) = args.duration { info(&format!("Duration: {}s", d)); }
    if let Some(ref m) = args.max_size { info(&format!("Max size: {}", m)); }
    if args.dry_run                    { warn("Dry-run mode — no files will be written."); }
    println!();

    // Preview mode
    if args.preview {
        let preview_stem = output.file_stem().unwrap_or_default();
        let preview_parent = output.parent().unwrap_or(Path::new("."));
        let preview_path = preview_parent.join(format!("{}_preview.png", preview_stem.to_string_lossy()));

        let seek = args.start.as_deref().unwrap_or("0");
        info(&format!("Preview mode — extracting one frame at {}s...", seek));

        let vf = build_vf(args.width, args.crop.as_deref(), args.speed, args.reverse);
        let input_str = args.input.to_string_lossy().to_string();
        let preview_str = preview_path.to_string_lossy().to_string();
        let preview_args = [
            "-v", "warning",
            "-ss", seek,
            "-i", &input_str,
            "-vf", &vf,
            "-vframes", "1",
            "-y", &preview_str,
        ];
        if let Err(e) = run_ffmpeg(&preview_args, args.dry_run) {
            error_exit(&e);
        }
        if !args.dry_run {
            success(&format!("Preview saved: {}", preview_path.display()));
            info(&format!("Dimensions: {} px", get_dims(&preview_path)));
        }
        return;
    }

    // Conversion (with optional auto-resize loop)
    if max_bytes > 0 {
        let mut current_fps = args.fps;
        let mut current_width = args.width;
        let max_attempts = 6usize;

        for attempt in 1..=max_attempts {
            if let Err(e) = do_convert(
                current_fps, current_width,
                &args.input, &output,
                &time_flags,
                args.crop.as_deref(), args.speed, args.reverse,
                qs.max_colors, &args.stats_mode, &qs.dither,
                args.loop_count, tmp_dir.path(), args.dry_run,
            ) { error_exit(&e); }

            if args.dry_run {
                info("(Dry-run: skipping size check loop)");
                break;
            }

            let actual_bytes = file_size(&output);
            let actual_human = human_size(actual_bytes);

            if actual_bytes <= max_bytes {
                info(&format!("Size {} is within limit {} \u{2713}", actual_human, args.max_size.as_deref().unwrap_or("")));
                break;
            }
            if attempt == max_attempts {
                warn(&format!("Could not shrink below {} after {} attempts.", args.max_size.as_deref().unwrap_or(""), max_attempts));
                warn("Keeping last output as-is.");
                break;
            }
            warn(&format!("Size {} exceeds {} — reducing quality...", actual_human, args.max_size.as_deref().unwrap_or("")));
            if attempt % 2 == 1 {
                current_fps = if current_fps > 5 { current_fps - 3 } else { current_fps };
                info(&format!("  -> Reduced FPS to {}", current_fps));
            } else {
                current_width = if current_width > 120 { current_width - 80 } else { current_width };
                info(&format!("  -> Reduced width to {}px", current_width));
            }
        }
    } else {
        if let Err(e) = do_convert(
            args.fps, args.width,
            &args.input, &output,
            &time_flags,
            args.crop.as_deref(), args.speed, args.reverse,
            qs.max_colors, &args.stats_mode, &qs.dither,
            args.loop_count, tmp_dir.path(), args.dry_run,
        ) { error_exit(&e); }
    }

    // Report results
    if args.dry_run {
        println!();
        success("Dry-run complete — no files written.");
        println!();
        return;
    }

    if output.exists() {
        println!();
        success("GIF created successfully!");
        println!("  {}       {}", "File:".bold(),       output.display());
        println!("  {}       {}", "Size:".bold(),       human_size(file_size(&output)));
        println!("  {} {} px", "Dimensions:".bold(), get_dims(&output));
        println!();
    } else {
        error_exit("Conversion failed — output file was not created.");
    }
}
