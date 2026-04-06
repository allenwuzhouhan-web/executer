#!/usr/bin/env python3
"""
Executer Audio Engine
Creates audio files from TTS, music mixing, tone generation, and ducking.

Usage:
    python3 audio_engine.py --spec spec.json --output out.m4a --ffmpeg /path/to/ffmpeg

Zero pip dependencies — stdlib + FFmpeg CLI + macOS say only.
"""

import argparse, json, sys, os, subprocess, tempfile, shutil, math
from pathlib import Path


def log(msg):
    print(msg, file=sys.stderr)


# ---------------------------------------------------------------------------
# Track Renderers
# ---------------------------------------------------------------------------

def render_tts(ffmpeg, track, temp_dir, index):
    """Render a TTS track using macOS say command."""
    text = track.get("text", "")
    voice = track.get("voice", "Samantha")
    rate = track.get("rate", 170)

    if not text.strip():
        return None

    aiff_path = os.path.join(temp_dir, f"tts_{index}.aiff")
    wav_path = os.path.join(temp_dir, f"tts_{index}.wav")

    try:
        subprocess.run(
            ["say", "-v", voice, "-r", str(rate), "-o", aiff_path, text],
            check=True, capture_output=True, timeout=60
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        log(f"[audio_engine] TTS failed: {e}")
        return None

    # Convert AIFF to WAV (standard format for mixing)
    cmd = [ffmpeg, "-y", "-i", aiff_path, "-ar", "44100", "-ac", "2", wav_path]
    _run_cmd(cmd)

    return wav_path if os.path.exists(wav_path) else None


def render_file(ffmpeg, track, temp_dir, index):
    """Render a file track (load, apply volume/fade/trim/loop)."""
    path = track.get("path", "")
    expanded = str(Path(path).expanduser())
    if not os.path.exists(expanded):
        log(f"[audio_engine] File not found: {path}")
        return None

    volume = track.get("volume", 1.0)
    fade_in = track.get("fade_in", 0)
    fade_out = track.get("fade_out", 0)
    loop = track.get("loop", False)
    trim_start = track.get("trim_start")
    trim_end = track.get("trim_end")

    wav_path = os.path.join(temp_dir, f"file_{index}.wav")

    cmd = [ffmpeg, "-y"]
    if loop:
        cmd += ["-stream_loop", "-1"]
    if trim_start is not None:
        cmd += ["-ss", str(trim_start)]
    cmd += ["-i", expanded]
    if trim_end is not None:
        if trim_start is not None:
            cmd += ["-t", str(trim_end - trim_start)]
        else:
            cmd += ["-to", str(trim_end)]

    # Build audio filter chain
    filters = []
    if volume != 1.0:
        filters.append(f"volume={volume}")
    if fade_in > 0:
        filters.append(f"afade=t=in:st=0:d={fade_in}")
    if fade_out > 0:
        # Need duration to calculate fade out start
        dur = _get_audio_duration(ffmpeg, expanded)
        if dur > 0:
            fade_start = dur - fade_out
            if trim_end is not None and trim_start is not None:
                fade_start = (trim_end - trim_start) - fade_out
            elif trim_end is not None:
                fade_start = trim_end - fade_out
            filters.append(f"afade=t=out:st={max(0, fade_start)}:d={fade_out}")

    if filters:
        cmd += ["-af", ",".join(filters)]

    cmd += ["-ar", "44100", "-ac", "2", wav_path]
    _run_cmd(cmd)

    return wav_path if os.path.exists(wav_path) else None


def render_silence(ffmpeg, track, temp_dir, index):
    """Render a silence track."""
    duration = track.get("duration", 1.0)
    wav_path = os.path.join(temp_dir, f"silence_{index}.wav")

    cmd = [ffmpeg, "-y", "-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo",
           "-t", str(duration), wav_path]
    _run_cmd(cmd)

    return wav_path if os.path.exists(wav_path) else None


def render_tone(ffmpeg, track, temp_dir, index):
    """Render a tone track using FFmpeg's sine generator."""
    frequency = track.get("frequency", 440)
    duration = track.get("duration", 1.0)
    volume = track.get("volume", 0.5)
    waveform = track.get("waveform", "sine")

    wav_path = os.path.join(temp_dir, f"tone_{index}.wav")

    # FFmpeg lavfi sine source
    if waveform == "square":
        # Approximate square wave: sine with hard clipping
        cmd = [ffmpeg, "-y", "-f", "lavfi", "-i",
               f"sine=frequency={frequency}:duration={duration}:sample_rate=44100",
               "-af", f"volume={volume},asignalproc=e='if(gt(val,0),1,-1)'",
               "-ar", "44100", "-ac", "2", wav_path]
    else:
        cmd = [ffmpeg, "-y", "-f", "lavfi", "-i",
               f"sine=frequency={frequency}:duration={duration}:sample_rate=44100",
               "-af", f"volume={volume}",
               "-ar", "44100", "-ac", "2", wav_path]

    try:
        _run_cmd(cmd)
    except subprocess.CalledProcessError:
        # Fallback: simpler sine generation
        cmd = [ffmpeg, "-y", "-f", "lavfi", "-i",
               f"sine=frequency={frequency}:duration={duration}",
               "-af", f"volume={volume}",
               "-ar", "44100", "-ac", "2", wav_path]
        _run_cmd(cmd)

    return wav_path if os.path.exists(wav_path) else None


# Track renderer registry
TRACK_RENDERERS = {
    "tts": render_tts,
    "file": render_file,
    "silence": render_silence,
    "tone": render_tone,
}


# ---------------------------------------------------------------------------
# Mixing
# ---------------------------------------------------------------------------

def mix_layer(ffmpeg, rendered_tracks, ducking, output_path, temp_dir):
    """Mix tracks in parallel (layered). Optionally duck non-TTS tracks under TTS."""
    if not rendered_tracks:
        return False

    if len(rendered_tracks) == 1:
        _, path = rendered_tracks[0]
        _convert_output(ffmpeg, path, output_path)
        return True

    # Separate TTS and non-TTS tracks for ducking
    tts_tracks = [(t, p) for t, p in rendered_tracks if t == "tts"]
    other_tracks = [(t, p) for t, p in rendered_tracks if t != "tts"]

    if ducking and tts_tracks and other_tracks:
        return _mix_with_ducking(ffmpeg, tts_tracks, other_tracks, output_path, temp_dir)
    else:
        return _mix_simple_layer(ffmpeg, [p for _, p in rendered_tracks], output_path)


def _mix_simple_layer(ffmpeg, paths, output_path):
    """Simple amix of all tracks."""
    n = len(paths)
    cmd = [ffmpeg, "-y"]
    for p in paths:
        cmd += ["-i", p]

    cmd += ["-filter_complex", f"amix=inputs={n}:duration=longest:dropout_transition=2",
            "-ar", "44100", "-ac", "2"]

    _add_output_codec(cmd, output_path)
    cmd.append(output_path)
    _run_cmd(cmd)
    return os.path.exists(output_path)


def _mix_with_ducking(ffmpeg, tts_tracks, other_tracks, output_path, temp_dir):
    """Mix with sidechaincompress ducking: lower other tracks when TTS plays."""
    # First, merge all TTS into one track
    tts_merged = os.path.join(temp_dir, "tts_merged.wav")
    if len(tts_tracks) == 1:
        shutil.copy2(tts_tracks[0][1], tts_merged)
    else:
        paths = [p for _, p in tts_tracks]
        cmd = [ffmpeg, "-y"]
        for p in paths:
            cmd += ["-i", p]
        cmd += ["-filter_complex", f"amix=inputs={len(paths)}:duration=longest", "-ar", "44100", "-ac", "2", tts_merged]
        _run_cmd(cmd)

    # Merge all other tracks into one
    other_merged = os.path.join(temp_dir, "other_merged.wav")
    if len(other_tracks) == 1:
        shutil.copy2(other_tracks[0][1], other_merged)
    else:
        paths = [p for _, p in other_tracks]
        cmd = [ffmpeg, "-y"]
        for p in paths:
            cmd += ["-i", p]
        cmd += ["-filter_complex", f"amix=inputs={len(paths)}:duration=longest", "-ar", "44100", "-ac", "2", other_merged]
        _run_cmd(cmd)

    # Apply sidechain compression: duck other_merged using tts_merged as sidechain
    cmd = [ffmpeg, "-y", "-i", other_merged, "-i", tts_merged,
           "-filter_complex",
           "[0:a][1:a]sidechaincompress=threshold=0.02:ratio=6:attack=200:release=1000[ducked];"
           "[ducked][1:a]amix=inputs=2:duration=longest:dropout_transition=2[out]",
           "-map", "[out]", "-ar", "44100", "-ac", "2"]

    _add_output_codec(cmd, output_path)
    cmd.append(output_path)
    _run_cmd(cmd)
    return os.path.exists(output_path)


def mix_sequence(ffmpeg, rendered_tracks, crossfade_duration, output_path, temp_dir):
    """Mix tracks sequentially (concatenated). Optional crossfade between tracks."""
    if not rendered_tracks:
        return False

    paths = [p for _, p in rendered_tracks]

    if len(paths) == 1:
        _convert_output(ffmpeg, paths[0], output_path)
        return True

    if crossfade_duration > 0:
        return _sequence_with_crossfade(ffmpeg, paths, crossfade_duration, output_path, temp_dir)
    else:
        return _sequence_simple(ffmpeg, paths, output_path, temp_dir)


def _sequence_simple(ffmpeg, paths, output_path, temp_dir):
    """Simple sequential concatenation."""
    list_file = os.path.join(temp_dir, "seq_concat.txt")
    with open(list_file, "w") as f:
        for p in paths:
            f.write(f"file '{p}'\n")

    cmd = [ffmpeg, "-y", "-f", "concat", "-safe", "0", "-i", list_file,
           "-ar", "44100", "-ac", "2"]
    _add_output_codec(cmd, output_path)
    cmd.append(output_path)
    _run_cmd(cmd)
    return os.path.exists(output_path)


def _sequence_with_crossfade(ffmpeg, paths, crossfade_dur, output_path, temp_dir):
    """Sequential with acrossfade between consecutive tracks."""
    if len(paths) == 2:
        cmd = [ffmpeg, "-y", "-i", paths[0], "-i", paths[1],
               "-filter_complex", f"acrossfade=d={crossfade_dur}",
               "-ar", "44100", "-ac", "2"]
        _add_output_codec(cmd, output_path)
        cmd.append(output_path)
        _run_cmd(cmd)
        return os.path.exists(output_path)

    # Chain acrossfade for 3+ tracks
    n = len(paths)
    cmd = [ffmpeg, "-y"]
    for p in paths:
        cmd += ["-i", p]

    filter_parts = []
    prev = "[0:a]"
    for i in range(1, n):
        out_label = f"[a{i}]" if i < n - 1 else "[out]"
        filter_parts.append(f"{prev}[{i}:a]acrossfade=d={crossfade_dur}{out_label}")
        prev = out_label

    cmd += ["-filter_complex", ";".join(filter_parts), "-map", "[out]",
            "-ar", "44100", "-ac", "2"]
    _add_output_codec(cmd, output_path)
    cmd.append(output_path)
    _run_cmd(cmd)
    return os.path.exists(output_path)


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def _run_cmd(cmd):
    """Run a subprocess command, raising on failure."""
    log(f"[audio_engine] Running: {' '.join(cmd[:6])}...")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        log(f"[audio_engine] stderr: {result.stderr[:300]}")
        raise subprocess.CalledProcessError(result.returncode, cmd, output=result.stdout, stderr=result.stderr)
    return result


def _get_audio_duration(ffmpeg, path):
    """Get audio duration in seconds."""
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


def _convert_output(ffmpeg, input_path, output_path):
    """Convert a WAV to the desired output format."""
    cmd = [ffmpeg, "-y", "-i", input_path, "-ar", "44100", "-ac", "2"]
    _add_output_codec(cmd, output_path)
    cmd.append(output_path)
    _run_cmd(cmd)


def _add_output_codec(cmd, output_path):
    """Add appropriate codec flags based on output extension."""
    ext = Path(output_path).suffix.lower()
    if ext in (".m4a", ".aac"):
        cmd += ["-c:a", "aac", "-b:a", "192k"]
    elif ext == ".mp3":
        cmd += ["-c:a", "libmp3lame", "-b:a", "192k"]
    elif ext == ".wav":
        cmd += ["-c:a", "pcm_s16le"]
    elif ext == ".flac":
        cmd += ["-c:a", "flac"]
    else:
        cmd += ["-c:a", "aac", "-b:a", "192k"]


# ===========================================================================
# Main
# ===========================================================================

def create_audio(spec, ffmpeg, output_path):
    """Create audio from spec dict."""
    tracks_spec = spec.get("tracks", [])
    if not tracks_spec:
        return {"success": False, "error": "No tracks in spec"}

    mix_mode = spec.get("mix", "sequence")  # "layer" or "sequence"
    ducking = spec.get("ducking", False)
    crossfade_duration = spec.get("crossfade_duration", 0)
    output_format = spec.get("output_format", "m4a")

    # Ensure output has correct extension
    if not output_path.lower().endswith(f".{output_format}"):
        output_path = str(Path(output_path).with_suffix(f".{output_format}"))

    temp_dir = tempfile.mkdtemp(prefix="executer_audio_")

    try:
        # Render all tracks
        rendered_tracks = []  # List of (type, path) tuples
        for i, track in enumerate(tracks_spec):
            track_type = track.get("type", "")
            renderer = TRACK_RENDERERS.get(track_type)

            if not renderer:
                log(f"[audio_engine] Unknown track type: {track_type}, skipping")
                continue

            log(f"[audio_engine] Rendering track {i+1}/{len(tracks_spec)}: {track_type}")
            path = renderer(ffmpeg, track, temp_dir, i)

            if path and os.path.exists(path):
                rendered_tracks.append((track_type, path))
            else:
                log(f"[audio_engine] Track {i+1} produced no output")

        if not rendered_tracks:
            return {"success": False, "error": "No tracks were rendered successfully"}

        # Mix tracks
        log(f"[audio_engine] Mixing {len(rendered_tracks)} tracks ({mix_mode} mode)...")

        if mix_mode == "layer":
            success = mix_layer(ffmpeg, rendered_tracks, ducking, output_path, temp_dir)
        else:
            success = mix_sequence(ffmpeg, rendered_tracks, crossfade_duration, output_path, temp_dir)

        if not success or not os.path.exists(output_path):
            return {"success": False, "error": "Audio mixing failed"}

        duration = _get_audio_duration(ffmpeg, output_path)
        return {
            "success": True,
            "path": str(Path(output_path).resolve()),
            "duration_seconds": duration,
            "tracks": len(rendered_tracks),
            "mix_mode": mix_mode
        }

    except subprocess.CalledProcessError as e:
        stderr = e.stderr[:500] if e.stderr else str(e)
        return {"success": False, "error": f"FFmpeg failed: {stderr}"}
    except Exception as e:
        return {"success": False, "error": f"{type(e).__name__}: {str(e)}"}
    finally:
        try:
            shutil.rmtree(temp_dir)
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser(description="Executer Audio Engine")
    parser.add_argument("--spec", help="Path to spec JSON file")
    parser.add_argument("--stdin", action="store_true", help="Read spec from stdin")
    parser.add_argument("--output", required=True, help="Output audio file path")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="Path to ffmpeg binary")
    args = parser.parse_args()

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
        filename = spec.get("filename", "audio.m4a")
        output = str(Path(output) / filename)

    Path(output).parent.mkdir(parents=True, exist_ok=True)

    result = create_audio(spec, args.ffmpeg, output)
    print(json.dumps(result))
    sys.exit(0 if result.get("success") else 1)


if __name__ == "__main__":
    main()
