#!/usr/bin/env python3
"""
Executer FFmpeg Engine
Video editing (operations pipeline) and video creation (scene composer).

Usage:
    python3 ffmpeg_engine.py --spec spec.json --output out.mp4 --ffmpeg /path/to/ffmpeg --mode edit
    python3 ffmpeg_engine.py --spec spec.json --output out.mp4 --ffmpeg /path/to/ffmpeg --mode create

Zero pip dependencies — stdlib + FFmpeg CLI only.
"""

import argparse, json, sys, os, subprocess, tempfile, shutil, re, math
from pathlib import Path

# ---------------------------------------------------------------------------
# Image utils import (shared with ppt_engine.py)
# ---------------------------------------------------------------------------
try:
    from image_utils import resolve_image, cleanup_temp_images
except ImportError:
    _iu_path = Path(__file__).parent / "image_utils.py"
    if _iu_path.exists():
        import importlib.util
        _spec_iu = importlib.util.spec_from_file_location("image_utils", _iu_path)
        _mod = importlib.util.module_from_spec(_spec_iu)
        _spec_iu.loader.exec_module(_mod)
        resolve_image = _mod.resolve_image
        cleanup_temp_images = _mod.cleanup_temp_images
    else:
        resolve_image = lambda source, temp_dir=None: source if source and Path(source).expanduser().exists() else None
        cleanup_temp_images = lambda d: None


def log(msg):
    print(msg, file=sys.stderr)


# ===========================================================================
# MODE: EDIT — Operations Pipeline
# ===========================================================================

def build_trim(ffmpeg, input_path, output_path, op):
    """Trim video to start-end range."""
    start = op.get("start", 0)
    end = op.get("end")
    cmd = [ffmpeg, "-y", "-i", input_path]
    cmd += ["-ss", str(start)]
    if end is not None:
        cmd += ["-to", str(end)]
    cmd += ["-c", "copy", output_path]
    return cmd


def build_merge(ffmpeg, op, output_path, temp_dir):
    """Merge multiple video files with optional crossfade transitions."""
    inputs = op.get("inputs", [])
    if len(inputs) < 2:
        return None

    transition = op.get("transition", "none")
    trans_dur = op.get("transition_duration", 0.5)

    if transition == "none" or transition == "concat":
        # Simple concat via demuxer
        list_file = os.path.join(temp_dir, "concat_list.txt")
        with open(list_file, "w") as f:
            for inp in inputs:
                f.write(f"file '{inp}'\n")
        return [ffmpeg, "-y", "-f", "concat", "-safe", "0", "-i", list_file, "-c", "copy", output_path]
    else:
        # xfade transitions — need re-encode
        if len(inputs) == 2:
            cmd = [ffmpeg, "-y", "-i", inputs[0], "-i", inputs[1]]
            # Get duration of first input for offset
            dur = _get_duration(ffmpeg, inputs[0])
            offset = max(0, dur - trans_dur)
            cmd += ["-filter_complex",
                    f"[0:v][1:v]xfade=transition=fade:duration={trans_dur}:offset={offset}[v];"
                    f"[0:a][1:a]acrossfade=d={trans_dur}[a]",
                    "-map", "[v]", "-map", "[a]", output_path]
            return cmd
        else:
            # Chain xfade for multiple inputs — build iteratively
            return _build_multi_xfade(ffmpeg, inputs, trans_dur, output_path)


def _build_multi_xfade(ffmpeg, inputs, trans_dur, output_path):
    """Build xfade filter chain for 3+ inputs."""
    n = len(inputs)
    cmd = [ffmpeg, "-y"]
    for inp in inputs:
        cmd += ["-i", inp]

    # Build filter graph
    durations = [_get_duration(ffmpeg, inp) for inp in inputs]

    filter_parts = []
    offsets = []
    cumulative = 0
    for i in range(n - 1):
        cumulative += durations[i] - trans_dur
        offsets.append(cumulative)

    # Video xfade chain
    prev = "[0:v]"
    for i in range(1, n):
        out_label = f"[v{i}]" if i < n - 1 else "[v]"
        offset = offsets[i - 1]
        filter_parts.append(f"{prev}[{i}:v]xfade=transition=fade:duration={trans_dur}:offset={offset}{out_label}")
        prev = out_label

    # Audio crossfade chain
    prev_a = "[0:a]"
    for i in range(1, n):
        out_label = f"[a{i}]" if i < n - 1 else "[a]"
        filter_parts.append(f"{prev_a}[{i}:a]acrossfade=d={trans_dur}{out_label}")
        prev_a = out_label

    cmd += ["-filter_complex", ";".join(filter_parts), "-map", "[v]", "-map", "[a]", output_path]
    return cmd


def build_overlay_text(ffmpeg, input_path, output_path, op):
    """Overlay text on video."""
    text = op.get("text", "").replace("'", "\\'").replace(":", "\\:")
    position = op.get("position", "center")
    font_size = op.get("font_size", 48)
    color = op.get("color", "white")
    bg_color = op.get("bg_color", "")
    start = op.get("start", 0)
    duration = op.get("duration")

    # Position mapping
    pos_map = {
        "center": "x=(w-text_w)/2:y=(h-text_h)/2",
        "top": "x=(w-text_w)/2:y=50",
        "bottom": "x=(w-text_w)/2:y=h-text_h-50",
        "top_left": "x=50:y=50",
        "top_right": "x=w-text_w-50:y=50",
        "bottom_left": "x=50:y=h-text_h-50",
        "bottom_right": "x=w-text_w-50:y=h-text_h-50",
    }
    pos = pos_map.get(position, pos_map["center"])

    drawtext = f"drawtext=text='{text}':fontsize={font_size}:fontcolor={color}:{pos}"
    if bg_color:
        drawtext += f":box=1:boxcolor={bg_color}@0.7:boxborderw=10"

    # Time range
    if duration is not None:
        drawtext += f":enable='between(t,{start},{start + duration})'"
    elif start > 0:
        drawtext += f":enable='gte(t,{start})'"

    return [ffmpeg, "-y", "-i", input_path, "-vf", drawtext, "-codec:a", "copy", output_path]


def build_overlay_image(ffmpeg, input_path, output_path, op, temp_dir):
    """Overlay an image on video."""
    image_path = op.get("image_path", "")
    resolved = resolve_image(image_path, temp_dir)
    if not resolved:
        return None

    x = op.get("x", 0)
    y = op.get("y", 0)
    width = op.get("width")
    height = op.get("height")
    start = op.get("start", 0)
    duration = op.get("duration")
    opacity = op.get("opacity", 1.0)

    overlay_filter = f"overlay={x}:{y}"
    if duration is not None:
        overlay_filter += f":enable='between(t,{start},{start + duration})'"

    cmd = [ffmpeg, "-y", "-i", input_path, "-i", resolved]

    scale_filter = ""
    if width and height:
        scale_filter = f"[1:v]scale={width}:{height}[img];"
        overlay_filter = f"[0:v][img]" + overlay_filter
    else:
        overlay_filter = f"[0:v][1:v]" + overlay_filter

    filter_str = scale_filter + overlay_filter + "[out]"
    cmd += ["-filter_complex", filter_str, "-map", "[out]", "-map", "0:a?", "-codec:a", "copy", output_path]
    return cmd


def build_add_audio(ffmpeg, input_path, output_path, op):
    """Add audio track to video."""
    audio_path = op.get("audio_path", "")
    volume = op.get("volume", 1.0)
    loop = op.get("loop", False)
    mix_mode = op.get("mix_mode", "mix")  # "replace" or "mix"

    cmd = [ffmpeg, "-y", "-i", input_path]

    if loop:
        cmd += ["-stream_loop", "-1"]
    cmd += ["-i", audio_path]

    if mix_mode == "replace":
        cmd += ["-map", "0:v", "-map", "1:a", "-shortest", "-c:v", "copy", output_path]
    else:
        # Mix: combine original audio with new audio
        filter_str = f"[1:a]volume={volume}[music];[0:a][music]amix=inputs=2:duration=first:dropout_transition=2"
        cmd += ["-filter_complex", filter_str, "-map", "0:v", "-shortest", "-c:v", "copy", output_path]
    return cmd


def build_speed(ffmpeg, input_path, output_path, op):
    """Change video speed."""
    factor = op.get("factor", 1.0)
    factor = max(0.25, min(4.0, factor))

    video_filter = f"setpts={1.0/factor}*PTS"

    # Audio tempo adjustment (atempo only supports 0.5-2.0, chain for extremes)
    atempo_filters = []
    remaining = factor
    while remaining > 2.0:
        atempo_filters.append("atempo=2.0")
        remaining /= 2.0
    while remaining < 0.5:
        atempo_filters.append("atempo=0.5")
        remaining /= 0.5
    atempo_filters.append(f"atempo={remaining}")
    audio_filter = ",".join(atempo_filters)

    return [ffmpeg, "-y", "-i", input_path, "-vf", video_filter, "-af", audio_filter, output_path]


def build_resize(ffmpeg, input_path, output_path, op):
    """Resize video."""
    width = op.get("width", -2)
    height = op.get("height", -2)
    return [ffmpeg, "-y", "-i", input_path, "-vf", f"scale={width}:{height}", "-codec:a", "copy", output_path]


def build_crop(ffmpeg, input_path, output_path, op):
    """Crop video."""
    x = op.get("x", 0)
    y = op.get("y", 0)
    w = op.get("width", 1920)
    h = op.get("height", 1080)
    return [ffmpeg, "-y", "-i", input_path, "-vf", f"crop={w}:{h}:{x}:{y}", "-codec:a", "copy", output_path]


def build_rotate(ffmpeg, input_path, output_path, op):
    """Rotate video by 90, 180, or 270 degrees."""
    angle = op.get("angle", 90)
    transpose_map = {90: "transpose=1", 180: "transpose=1,transpose=1", 270: "transpose=2"}
    vf = transpose_map.get(angle, "transpose=1")
    return [ffmpeg, "-y", "-i", input_path, "-vf", vf, "-codec:a", "copy", output_path]


def build_extract_audio(ffmpeg, input_path, output_path, op):
    """Extract audio from video."""
    fmt = op.get("format", "mp3")
    ext_map = {"mp3": ".mp3", "wav": ".wav", "aac": ".m4a", "m4a": ".m4a"}
    ext = ext_map.get(fmt, ".mp3")
    # Override output extension
    out = Path(output_path).with_suffix(ext)
    return [ffmpeg, "-y", "-i", input_path, "-vn", str(out)]


def build_subtitles(ffmpeg, input_path, output_path, op):
    """Burn subtitles into video."""
    srt_path = op.get("srt_path", "")
    if srt_path and os.path.exists(srt_path):
        escaped = srt_path.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")
        return [ffmpeg, "-y", "-i", input_path, "-vf", f"subtitles='{escaped}'", "-codec:a", "copy", output_path]
    return None


def build_fade(ffmpeg, input_path, output_path, op):
    """Add fade in/out to video."""
    fade_in = op.get("fade_in", 0)
    fade_out = op.get("fade_out", 0)
    duration = _get_duration(ffmpeg, input_path)

    filters = []
    if fade_in > 0:
        filters.append(f"fade=t=in:st=0:d={fade_in}")
    if fade_out > 0 and duration > 0:
        filters.append(f"fade=t=out:st={duration - fade_out}:d={fade_out}")

    if not filters:
        return None

    vf = ",".join(filters)

    # Audio fades
    afilters = []
    if fade_in > 0:
        afilters.append(f"afade=t=in:st=0:d={fade_in}")
    if fade_out > 0 and duration > 0:
        afilters.append(f"afade=t=out:st={duration - fade_out}:d={fade_out}")
    af = ",".join(afilters) if afilters else None

    cmd = [ffmpeg, "-y", "-i", input_path, "-vf", vf]
    if af:
        cmd += ["-af", af]
    cmd += [output_path]
    return cmd


def build_color_adjust(ffmpeg, input_path, output_path, op):
    """Adjust brightness, contrast, saturation."""
    brightness = op.get("brightness", 0)
    contrast = op.get("contrast", 1.0)
    saturation = op.get("saturation", 1.0)
    return [ffmpeg, "-y", "-i", input_path,
            "-vf", f"eq=brightness={brightness}:contrast={contrast}:saturation={saturation}",
            "-codec:a", "copy", output_path]


def build_stabilize(ffmpeg, input_path, output_path, op, temp_dir):
    """Stabilize video using vidstab (2-pass)."""
    strength_map = {"low": 4, "medium": 10, "high": 20}
    strength = strength_map.get(op.get("strength", "medium"), 10)

    transforms_file = os.path.join(temp_dir, "transforms.trf")

    # Pass 1: analyze
    cmd1 = [ffmpeg, "-y", "-i", input_path,
            "-vf", f"vidstabdetect=shakiness={strength}:result={transforms_file}",
            "-f", "null", "-"]

    # Pass 2: apply
    cmd2 = [ffmpeg, "-y", "-i", input_path,
            "-vf", f"vidstabtransform=input={transforms_file}:smoothing={strength}",
            "-codec:a", "copy", output_path]

    return (cmd1, cmd2)  # Tuple = two-pass


# Builder registry
EDIT_BUILDERS = {
    "trim": "build_trim",
    "overlay_text": "build_overlay_text",
    "add_audio": "build_add_audio",
    "speed": "build_speed",
    "resize": "build_resize",
    "crop": "build_crop",
    "rotate": "build_rotate",
    "extract_audio": "build_extract_audio",
    "add_subtitles": "build_subtitles",
    "fade": "build_fade",
    "color_adjust": "build_color_adjust",
}


def run_edit(spec, ffmpeg, ffprobe, output_path, temp_dir):
    """Execute edit mode — operations pipeline."""
    input_path = spec.get("input", "")
    if not input_path or not os.path.exists(input_path):
        return {"success": False, "error": f"Input file not found: {input_path}"}

    operations = spec.get("operations", [])
    if not operations:
        return {"success": False, "error": "No operations specified"}

    pipeline = spec.get("pipeline", True)
    current_input = input_path
    step = 0

    try:
        for op in operations:
            op_type = op.get("type", "")
            step += 1

            if pipeline and step < len(operations):
                step_output = os.path.join(temp_dir, f"step_{step}.mp4")
            else:
                step_output = output_path

            log(f"[ffmpeg_engine] Step {step}/{len(operations)}: {op_type}")

            cmd = None

            if op_type == "merge":
                cmd = build_merge(ffmpeg, op, step_output, temp_dir)
                current_input = step_output
                if cmd:
                    _run_cmd(cmd)
                continue
            elif op_type == "overlay_image":
                cmd = build_overlay_image(ffmpeg, current_input, step_output, op, temp_dir)
            elif op_type == "stabilize":
                result = build_stabilize(ffmpeg, current_input, step_output, op, temp_dir)
                if result:
                    _run_cmd(result[0])  # Pass 1
                    cmd = result[1]  # Pass 2
            elif op_type in EDIT_BUILDERS:
                builder_name = EDIT_BUILDERS[op_type]
                builder_fn = globals()[builder_name]
                # Determine parameter count by inspection
                import inspect
                sig = inspect.signature(builder_fn)
                params = list(sig.parameters.keys())
                if len(params) == 4:
                    cmd = builder_fn(ffmpeg, current_input, step_output, op)
                else:
                    cmd = builder_fn(ffmpeg, current_input, step_output, op, temp_dir)
            else:
                log(f"[ffmpeg_engine] Unknown operation: {op_type}, skipping")
                continue

            if cmd:
                _run_cmd(cmd)
                current_input = step_output

        if not os.path.exists(output_path):
            return {"success": False, "error": "No output file produced"}

        duration = _get_duration(ffmpeg, output_path)
        return {
            "success": True,
            "path": str(Path(output_path).resolve()),
            "duration_seconds": duration,
            "operations": len(operations)
        }

    except subprocess.CalledProcessError as e:
        return {"success": False, "error": f"FFmpeg failed: {e.stderr[:500] if e.stderr else str(e)}"}
    except Exception as e:
        return {"success": False, "error": f"{type(e).__name__}: {str(e)}"}


# ===========================================================================
# MODE: CREATE — Scene Composer
# ===========================================================================

def run_create(spec, ffmpeg, ffprobe, output_path, temp_dir, style_path=None):
    """Execute create mode — scene-based video composer."""
    scenes = spec.get("scenes", [])
    if not scenes:
        return {"success": False, "error": "No scenes in spec"}

    resolution = spec.get("resolution", [1920, 1080])
    fps = spec.get("fps", 30)
    width, height = resolution[0], resolution[1]
    transitions_cfg = spec.get("transitions", {})
    trans_type = transitions_cfg.get("type", "crossfade")
    trans_dur = transitions_cfg.get("duration", 0.8)
    audio_cfg = spec.get("audio", {})
    subtitles_enabled = spec.get("subtitles", False)

    # Load style if provided
    style = None
    if style_path and os.path.exists(style_path):
        try:
            style = json.loads(Path(style_path).read_text())
            log(f"[ffmpeg_engine] Loaded video style: {style_path}")
        except Exception:
            pass

    try:
        # Step 1: Generate per-scene clips
        scene_clips = []
        narration_texts = []
        scene_durations = []
        failed_images = 0
        warnings = []

        for i, scene in enumerate(scenes):
            log(f"[ffmpeg_engine] Generating scene {i+1}/{len(scenes)}: {scene.get('type', 'unknown')}")
            clip_path = os.path.join(temp_dir, f"scene_{i:03d}.mp4")
            duration = scene.get("duration", 5)

            scene_type = scene.get("type", "image")

            if scene_type == "title_card":
                _create_title_card(ffmpeg, clip_path, scene, width, height, fps, duration)
            elif scene_type == "image":
                _create_image_scene(ffmpeg, clip_path, scene, width, height, fps, duration, temp_dir)
                if scene.get("_image_failed"):
                    failed_images += 1
                    warnings.append(f"Scene {i+1}: image not found, used black frame")
            elif scene_type == "video":
                _create_video_scene(ffmpeg, clip_path, scene, width, height, fps, duration)
            elif scene_type == "color_card":
                color = scene.get("bg_color", "#000000")
                _create_color_card(ffmpeg, clip_path, color, width, height, fps, duration)
            else:
                log(f"[ffmpeg_engine] Unknown scene type: {scene_type}, using color card")
                _create_color_card(ffmpeg, clip_path, "#000000", width, height, fps, duration)

            if os.path.exists(clip_path):
                scene_clips.append(clip_path)
                scene_durations.append(duration)
                # Collect narration text
                narration = scene.get("narration", "")
                narration_texts.append(narration)
            else:
                log(f"[ffmpeg_engine] Warning: Scene {i+1} produced no output")

        if not scene_clips:
            return {"success": False, "error": "No scene clips were generated"}

        # Step 2: Concatenate scenes with transitions
        log("[ffmpeg_engine] Concatenating scenes...")
        concat_path = os.path.join(temp_dir, "concat.mp4")

        if len(scene_clips) == 1:
            shutil.copy2(scene_clips[0], concat_path)
        elif trans_type == "none":
            _concat_simple(ffmpeg, scene_clips, concat_path)
        else:
            _concat_with_transitions(ffmpeg, scene_clips, scene_durations, concat_path, trans_type, trans_dur)

        if not os.path.exists(concat_path):
            return {"success": False, "error": "Scene concatenation failed"}

        # Step 3: Generate TTS narration if any
        narration_path = None
        narration_cfg = audio_cfg.get("narration", {})
        has_narration = any(t.strip() for t in narration_texts)

        if has_narration:
            log("[ffmpeg_engine] Generating TTS narration...")
            voice = narration_cfg.get("voice", "Samantha") if isinstance(narration_cfg, dict) else "Samantha"
            rate = narration_cfg.get("rate", 170) if isinstance(narration_cfg, dict) else 170
            narration_path = _generate_narration(ffmpeg, narration_texts, scene_durations, voice, rate, temp_dir)

        # Step 4: Generate subtitles if enabled
        srt_path = None
        if subtitles_enabled and has_narration:
            log("[ffmpeg_engine] Generating subtitles...")
            srt_path = _generate_srt(narration_texts, scene_durations, trans_dur, temp_dir)

        # Step 5: Mix audio (narration + background music + ducking)
        log("[ffmpeg_engine] Mixing audio...")
        final_path = output_path
        bg_music = audio_cfg.get("background_music", "")
        music_volume = audio_cfg.get("music_volume", 0.15)
        ducking = audio_cfg.get("ducking", True)

        _mix_final_audio(ffmpeg, concat_path, narration_path, bg_music, music_volume,
                         ducking, srt_path, final_path, temp_dir)

        # Step 6: Apply style color grading if present
        if style and os.path.exists(final_path):
            _apply_style_grading(ffmpeg, final_path, style, temp_dir)

        if not os.path.exists(final_path):
            return {"success": False, "error": "Final video assembly failed"}

        duration = _get_duration(ffmpeg, final_path)
        result = {
            "success": True,
            "path": str(Path(final_path).resolve()),
            "duration_seconds": duration,
            "scenes": len(scene_clips),
            "failed_images": failed_images,
        }
        if warnings:
            result["warnings"] = warnings
        return result

    except subprocess.CalledProcessError as e:
        stderr = e.stderr[:500] if e.stderr else str(e)
        return {"success": False, "error": f"FFmpeg failed: {stderr}"}
    except Exception as e:
        return {"success": False, "error": f"{type(e).__name__}: {str(e)}"}


# ---------------------------------------------------------------------------
# Scene generators
# ---------------------------------------------------------------------------

def _create_title_card(ffmpeg, output, scene, w, h, fps, duration):
    """Generate a title card clip with text on a color background."""
    bg_color = scene.get("bg_color", "#1a1a2e")
    text_color = scene.get("text_color", "#ffffff")
    title = scene.get("text", "").replace("'", "\\'").replace(":", "\\:")
    subtitle = scene.get("subtitle", "").replace("'", "\\'").replace(":", "\\:")
    font_size = scene.get("font_size", 72)

    filters = [f"color=c={bg_color}:size={w}x{h}:duration={duration}:r={fps}"]

    # Title text
    if title:
        y_pos = f"(h-text_h)/2-40" if subtitle else "(h-text_h)/2"
        filters.append(f"drawtext=text='{title}':fontsize={font_size}:fontcolor={text_color}:x=(w-text_w)/2:y={y_pos}")

    # Subtitle
    if subtitle:
        sub_size = max(24, font_size // 2)
        filters.append(f"drawtext=text='{subtitle}':fontsize={sub_size}:fontcolor={text_color}@0.8:x=(w-text_w)/2:y=(h-text_h)/2+50")

    # Add silent audio track
    vf = ",".join(filters)
    cmd = [ffmpeg, "-y", "-f", "lavfi", "-i", f"color=c={bg_color}:size={w}x{h}:duration={duration}:r={fps}",
           "-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo",
           "-vf", ",".join(filters[1:]) if len(filters) > 1 else "null",
           "-t", str(duration), "-shortest",
           "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-b:a", "128k",
           output]

    # Simpler approach: generate color + drawtext in one pass
    cmd = [ffmpeg, "-y",
           "-f", "lavfi", "-i", f"color=c={bg_color}:size={w}x{h}:duration={duration}:r={fps}",
           "-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo",
           "-t", str(duration), "-shortest"]

    draw_filters = []
    if title:
        y_pos = "(h-text_h)/2-40" if subtitle else "(h-text_h)/2"
        draw_filters.append(f"drawtext=text='{title}':fontsize={font_size}:fontcolor={text_color}:x=(w-text_w)/2:y={y_pos}")
    if subtitle:
        sub_size = max(24, font_size // 2)
        draw_filters.append(f"drawtext=text='{subtitle}':fontsize={sub_size}:fontcolor={text_color}@0.8:x=(w-text_w)/2:y=(h-text_h)/2+50")

    if draw_filters:
        cmd += ["-vf", ",".join(draw_filters)]

    cmd += ["-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k", output]

    _run_cmd(cmd)


def _create_image_scene(ffmpeg, output, scene, w, h, fps, duration, temp_dir):
    """Generate a scene from an image with Ken Burns animation."""
    source = scene.get("source", "")
    resolved = resolve_image(source, temp_dir)
    # Fallback: try search_query as a URL/path if source failed
    if not resolved:
        fallback = scene.get("search_query", "")
        if fallback:
            resolved = resolve_image(fallback, temp_dir)
    if not resolved:
        log(f"[ffmpeg_engine] ERROR: Image not found for scene — source={source!r}, search_query={scene.get('search_query', '')!r}. Using black frame.")
        scene["_image_failed"] = True
        _create_color_card(ffmpeg, output, "#000000", w, h, fps, duration)
        return

    animation = scene.get("animation", "zoom_in")
    total_frames = int(duration * fps)

    # Ken Burns via zoompan filter
    zoom_map = {
        "zoom_in": f"zoompan=z='min(zoom+0.0015,1.5)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d={total_frames}:s={w}x{h}:fps={fps}",
        "zoom_out": f"zoompan=z='if(eq(on,1),1.5,max(zoom-0.0015,1.0))':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d={total_frames}:s={w}x{h}:fps={fps}",
        "pan_left": f"zoompan=z='1.2':x='if(eq(on,1),iw*0.2,x-0.5)':y='ih/2-(ih/zoom/2)':d={total_frames}:s={w}x{h}:fps={fps}",
        "pan_right": f"zoompan=z='1.2':x='if(eq(on,1),0,x+0.5)':y='ih/2-(ih/zoom/2)':d={total_frames}:s={w}x{h}:fps={fps}",
        "pan_up": f"zoompan=z='1.2':x='iw/2-(iw/zoom/2)':y='if(eq(on,1),ih*0.2,y-0.5)':d={total_frames}:s={w}x{h}:fps={fps}",
        "none": f"zoompan=z='1':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d={total_frames}:s={w}x{h}:fps={fps}",
    }
    zoom_filter = zoom_map.get(animation, zoom_map["zoom_in"])

    cmd = [ffmpeg, "-y",
           "-loop", "1", "-i", resolved,
           "-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo",
           "-vf", f"scale={w*2}:{h*2}:force_original_aspect_ratio=increase,crop={w*2}:{h*2},{zoom_filter},format=yuv420p",
           "-t", str(duration), "-shortest",
           "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-b:a", "128k",
           output]
    _run_cmd(cmd)


def _create_video_scene(ffmpeg, output, scene, w, h, fps, duration):
    """Generate a scene from a video clip (with optional trim)."""
    source = scene.get("source", "")
    if not os.path.exists(source):
        _create_color_card(ffmpeg, output, "#000000", w, h, fps, duration)
        return

    cmd = [ffmpeg, "-y"]
    trim_start = scene.get("trim_start")
    trim_end = scene.get("trim_end")

    if trim_start is not None:
        cmd += ["-ss", str(trim_start)]
    cmd += ["-i", source]
    if trim_end is not None:
        if trim_start is not None:
            cmd += ["-t", str(trim_end - trim_start)]
        else:
            cmd += ["-to", str(trim_end)]

    cmd += ["-vf", f"scale={w}:{h}:force_original_aspect_ratio=decrease,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2",
            "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k",
            "-r", str(fps), output]
    _run_cmd(cmd)


def _create_color_card(ffmpeg, output, color, w, h, fps, duration):
    """Generate a solid color clip."""
    cmd = [ffmpeg, "-y",
           "-f", "lavfi", "-i", f"color=c={color}:size={w}x{h}:duration={duration}:r={fps}",
           "-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo",
           "-t", str(duration), "-shortest",
           "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-b:a", "128k",
           output]
    _run_cmd(cmd)


# ---------------------------------------------------------------------------
# Concatenation
# ---------------------------------------------------------------------------

def _concat_simple(ffmpeg, clips, output):
    """Simple concatenation without transitions using concat filter."""
    n = len(clips)
    cmd = [ffmpeg, "-y"]
    for clip in clips:
        cmd += ["-i", clip]

    filter_str = ""
    for i in range(n):
        filter_str += f"[{i}:v]scale=iw:ih,setsar=1[v{i}];"
        filter_str += f"[{i}:a]aformat=sample_rates=44100:channel_layouts=stereo[a{i}];"

    v_inputs = "".join(f"[v{i}]" for i in range(n))
    a_inputs = "".join(f"[a{i}]" for i in range(n))
    filter_str += f"{v_inputs}concat=n={n}:v=1:a=0[v];{a_inputs}concat=n={n}:v=0:a=1[a]"

    cmd += ["-filter_complex", filter_str, "-map", "[v]", "-map", "[a]",
            "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k", output]
    _run_cmd(cmd)


def _concat_with_transitions(ffmpeg, clips, durations, output, trans_type, trans_dur):
    """Concatenate clips with xfade transitions."""
    n = len(clips)
    if n == 1:
        shutil.copy2(clips[0], output)
        return

    xfade_map = {
        "crossfade": "fade",
        "wipe_left": "wipeleft",
        "wipe_right": "wiperight",
        "fade_black": "fadeblack",
    }
    xfade_name = xfade_map.get(trans_type, "fade")

    cmd = [ffmpeg, "-y"]
    for clip in clips:
        cmd += ["-i", clip]

    # Build xfade filter chain
    v_filters = []
    a_filters = []
    cumulative_offset = 0

    prev_v = "[0:v]"
    prev_a = "[0:a]"

    for i in range(1, n):
        cumulative_offset += durations[i - 1] - trans_dur
        offset = max(0, cumulative_offset)

        v_out = f"[v{i}]" if i < n - 1 else "[vout]"
        a_out = f"[a{i}]" if i < n - 1 else "[aout]"

        v_filters.append(f"{prev_v}[{i}:v]xfade=transition={xfade_name}:duration={trans_dur}:offset={offset}{v_out}")
        a_filters.append(f"{prev_a}[{i}:a]acrossfade=d={trans_dur}{a_out}")

        prev_v = v_out
        prev_a = a_out

    filter_str = ";".join(v_filters + a_filters)
    cmd += ["-filter_complex", filter_str, "-map", "[vout]", "-map", "[aout]",
            "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k", output]
    _run_cmd(cmd)


# ---------------------------------------------------------------------------
# TTS & Audio
# ---------------------------------------------------------------------------

def _generate_narration(ffmpeg, texts, durations, voice, rate, temp_dir):
    """Generate TTS narration aligned to scene durations using macOS say."""
    segments = []

    for i, (text, dur) in enumerate(zip(texts, durations)):
        if not text.strip():
            # Silence for this scene
            seg_path = os.path.join(temp_dir, f"narr_silence_{i:03d}.m4a")
            cmd = [ffmpeg, "-y", "-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo",
                   "-t", str(dur), "-c:a", "aac", "-b:a", "128k", seg_path]
            _run_cmd(cmd)
            segments.append(seg_path)
            continue

        # Generate TTS via macOS say
        aiff_path = os.path.join(temp_dir, f"narr_tts_{i:03d}.aiff")
        m4a_path = os.path.join(temp_dir, f"narr_tts_{i:03d}.m4a")

        try:
            subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", aiff_path, text],
                           check=True, capture_output=True, timeout=30)
        except (subprocess.CalledProcessError, FileNotFoundError):
            log(f"[ffmpeg_engine] TTS failed for scene {i+1}, using silence")
            seg_path = os.path.join(temp_dir, f"narr_silence_{i:03d}.m4a")
            cmd = [ffmpeg, "-y", "-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo",
                   "-t", str(dur), "-c:a", "aac", "-b:a", "128k", seg_path]
            _run_cmd(cmd)
            segments.append(seg_path)
            continue

        # Convert AIFF to M4A and pad/trim to scene duration
        cmd = [ffmpeg, "-y", "-i", aiff_path,
               "-af", f"apad=whole_dur={dur}",
               "-t", str(dur),
               "-c:a", "aac", "-b:a", "128k", "-ar", "44100", "-ac", "2",
               m4a_path]
        _run_cmd(cmd)
        segments.append(m4a_path)

    if not segments:
        return None

    # Concatenate all narration segments
    narration_path = os.path.join(temp_dir, "narration_full.m4a")
    if len(segments) == 1:
        shutil.copy2(segments[0], narration_path)
    else:
        list_file = os.path.join(temp_dir, "narr_concat.txt")
        with open(list_file, "w") as f:
            for seg in segments:
                f.write(f"file '{seg}'\n")
        cmd = [ffmpeg, "-y", "-f", "concat", "-safe", "0", "-i", list_file,
               "-c:a", "aac", "-b:a", "128k", narration_path]
        _run_cmd(cmd)

    return narration_path


def _generate_srt(texts, durations, trans_dur, temp_dir):
    """Generate SRT subtitle file from narration texts and scene durations."""
    srt_path = os.path.join(temp_dir, "subtitles.srt")
    lines = []
    current_time = 0
    idx = 1

    for text, dur in zip(texts, durations):
        if not text.strip():
            current_time += dur
            continue

        start = _format_srt_time(current_time)
        end = _format_srt_time(current_time + dur - trans_dur * 0.5)

        # Split long text into chunks of ~60 chars
        words = text.split()
        chunks = []
        current_chunk = []
        current_len = 0
        for word in words:
            if current_len + len(word) + 1 > 60 and current_chunk:
                chunks.append(" ".join(current_chunk))
                current_chunk = [word]
                current_len = len(word)
            else:
                current_chunk.append(word)
                current_len += len(word) + 1
        if current_chunk:
            chunks.append(" ".join(current_chunk))

        # Distribute chunks across the scene duration
        chunk_dur = dur / max(1, len(chunks))
        for j, chunk in enumerate(chunks):
            c_start = _format_srt_time(current_time + j * chunk_dur)
            c_end = _format_srt_time(current_time + (j + 1) * chunk_dur - 0.1)
            lines.append(f"{idx}\n{c_start} --> {c_end}\n{chunk}\n")
            idx += 1

        current_time += dur

    with open(srt_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    return srt_path


def _format_srt_time(seconds):
    """Format seconds to SRT time format HH:MM:SS,mmm."""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def _mix_final_audio(ffmpeg, video_path, narration_path, bg_music, music_volume,
                     ducking, srt_path, output_path, temp_dir):
    """Mix narration, background music, and video audio. Burn subtitles."""
    has_narration = narration_path and os.path.exists(narration_path)
    has_music = bg_music and os.path.exists(bg_music)
    has_srt = srt_path and os.path.exists(srt_path)

    # No extra audio — just handle subtitles
    if not has_narration and not has_music:
        if has_srt:
            escaped = srt_path.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")
            cmd = [ffmpeg, "-y", "-i", video_path,
                   "-vf", f"subtitles='{escaped}'",
                   "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
                   "-c:a", "copy", output_path]
            _run_cmd(cmd)
        else:
            shutil.copy2(video_path, output_path)
        return

    video_duration = _get_duration(ffmpeg, video_path)

    cmd = [ffmpeg, "-y", "-i", video_path]
    input_idx = 1
    narr_idx = None
    music_idx = None

    if has_narration:
        cmd += ["-i", narration_path]
        narr_idx = input_idx
        input_idx += 1

    if has_music:
        cmd += ["-stream_loop", "-1", "-i", bg_music]
        music_idx = input_idx
        input_idx += 1

    # Build audio filter
    filter_parts = []

    if has_music:
        filter_parts.append(f"[{music_idx}:a]volume={music_volume}[music]")

    if has_narration and has_music and ducking:
        # Sidechain compress: duck music when narration plays
        filter_parts.append(f"[music][{narr_idx}:a]sidechaincompress=threshold=0.02:ratio=6:attack=200:release=1000[ducked_music]")
        filter_parts.append(f"[{narr_idx}:a][ducked_music]amix=inputs=2:duration=first:dropout_transition=2[mixed]")
        audio_out = "[mixed]"
    elif has_narration and has_music:
        filter_parts.append(f"[{narr_idx}:a][music]amix=inputs=2:duration=first:dropout_transition=2[mixed]")
        audio_out = "[mixed]"
    elif has_narration:
        audio_out = f"[{narr_idx}:a]"
    elif has_music:
        audio_out = "[music]"
    else:
        audio_out = "[0:a]"

    # Video filter (subtitles)
    vf = None
    if has_srt:
        escaped = srt_path.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")
        vf = f"subtitles='{escaped}'"

    if filter_parts:
        cmd += ["-filter_complex", ";".join(filter_parts)]

    if vf:
        cmd += ["-vf", vf]

    cmd += ["-map", "0:v"]
    if filter_parts:
        cmd += ["-map", audio_out]
    elif has_narration:
        cmd += ["-map", f"{narr_idx}:a"]

    cmd += ["-t", str(video_duration), "-shortest",
            "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k",
            output_path]
    _run_cmd(cmd)


def _apply_style_grading(ffmpeg, video_path, style, temp_dir):
    """Apply color grading from a video style profile."""
    visual = style.get("visual", {})
    color_temp = visual.get("color_temperature", "neutral")

    # Map color temperature to eq adjustments
    grading_map = {
        "warm": "eq=saturation=1.1:contrast=1.05,colorbalance=rs=0.05:gs=-0.02:bs=-0.05",
        "cool": "eq=saturation=1.0:contrast=1.05,colorbalance=rs=-0.05:gs=0.02:bs=0.05",
        "neutral": None,
        "vibrant": "eq=saturation=1.3:contrast=1.1",
        "muted": "eq=saturation=0.8:contrast=0.95",
    }

    vf = grading_map.get(color_temp)
    if not vf:
        return

    graded_path = os.path.join(temp_dir, "graded.mp4")
    cmd = [ffmpeg, "-y", "-i", video_path, "-vf", vf, "-c:a", "copy", graded_path]
    _run_cmd(cmd)

    if os.path.exists(graded_path):
        shutil.move(graded_path, video_path)


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def _run_cmd(cmd):
    """Run a subprocess command, raising on failure."""
    log(f"[ffmpeg_engine] Running: {' '.join(cmd[:6])}...")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        log(f"[ffmpeg_engine] stderr: {result.stderr[:300]}")
        raise subprocess.CalledProcessError(result.returncode, cmd, output=result.stdout, stderr=result.stderr)
    return result


def _get_duration(ffmpeg, path):
    """Get media file duration in seconds via ffprobe."""
    ffprobe = ffmpeg.replace("ffmpeg", "ffprobe")
    try:
        result = subprocess.run(
            [ffprobe, "-v", "quiet", "-print_format", "json", "-show_format", path],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            return float(data.get("format", {}).get("duration", 0))
    except Exception:
        pass
    return 0


# ===========================================================================
# Main
# ===========================================================================

def main():
    parser = argparse.ArgumentParser(description="Executer FFmpeg Engine")
    parser.add_argument("--spec", help="Path to spec JSON file")
    parser.add_argument("--stdin", action="store_true", help="Read spec from stdin")
    parser.add_argument("--output", required=True, help="Output file path")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="Path to ffmpeg binary")
    parser.add_argument("--ffprobe", default=None, help="Path to ffprobe binary")
    parser.add_argument("--mode", required=True, choices=["edit", "create"], help="Engine mode")
    parser.add_argument("--style", default=None, help="Path to video style JSON (create mode)")
    args = parser.parse_args()

    # Resolve ffprobe from ffmpeg path if not provided
    if not args.ffprobe:
        args.ffprobe = args.ffmpeg.replace("ffmpeg", "ffprobe")

    # Load spec
    if args.stdin:
        try:
            spec = json.load(sys.stdin)
        except json.JSONDecodeError as e:
            print(json.dumps({"success": False, "error": f"Invalid JSON: {e}"}))
            sys.exit(1)
    elif args.spec:
        try:
            spec = json.loads(Path(args.spec).read_text(encoding="utf-8"))
        except Exception as e:
            print(json.dumps({"success": False, "error": str(e)}))
            sys.exit(1)
    else:
        print(json.dumps({"success": False, "error": "Provide --spec or --stdin"}))
        sys.exit(1)

    # Handle directory output
    output = args.output
    if output.endswith("/") or Path(output).is_dir():
        filename = spec.get("filename", "video.mp4")
        if not filename.endswith(".mp4"):
            filename += ".mp4"
        output = str(Path(output) / filename)

    Path(output).parent.mkdir(parents=True, exist_ok=True)

    # Create temp directory for intermediates
    temp_dir = tempfile.mkdtemp(prefix="executer_ffmpeg_")

    try:
        if args.mode == "edit":
            result = run_edit(spec, args.ffmpeg, args.ffprobe, output, temp_dir)
        else:
            result = run_create(spec, args.ffmpeg, args.ffprobe, output, temp_dir, args.style)

        print(json.dumps(result))
        sys.exit(0 if result.get("success") else 1)
    finally:
        try:
            shutil.rmtree(temp_dir)
        except OSError:
            pass


if __name__ == "__main__":
    main()
