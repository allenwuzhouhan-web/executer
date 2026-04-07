#!/usr/bin/env python3
"""Shared image utility for Executer document engines.

Resolves image sources (local paths or URLs) to local file paths
suitable for insertion into Office documents.
"""

import hashlib
import os
import sys
import ssl
import shutil
import tempfile
import time
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import URLError

MAX_SIZE = 10 * 1024 * 1024  # 10 MB
TIMEOUT = 15  # seconds
MAX_RETRIES = 2
MAX_DIMENSION = 1920  # max width or height for presentation images
JPEG_QUALITY = 85  # quality for JPEG compression
TARGET_SIZE_KB = 500  # target max file size in KB

# Magic bytes → extension
SIGNATURES = [
    (b"\xff\xd8\xff",       "jpg"),
    (b"\x89PNG\r\n\x1a\n",  "png"),
    (b"GIF87a",              "gif"),
    (b"GIF89a",              "gif"),
    (b"BM",                  "bmp"),
    (b"II\x2a\x00",         "tiff"),
    (b"MM\x00\x2a",         "tiff"),
    (b"RIFF",               "webp"),  # RIFF....WEBP
]

# URL hash → local path cache (per-session, avoids re-downloading same image)
_download_cache = {}


def _detect_ext(data: bytes) -> str | None:
    """Detect image format from magic bytes."""
    for sig, ext in SIGNATURES:
        if data[:len(sig)] == sig:
            if ext == "webp" and data[8:12] != b"WEBP":
                continue
            return ext
    return None


def _convert_webp_to_png(webp_path: str) -> str | None:
    """Convert WebP to PNG using PIL if available. Returns PNG path or None."""
    try:
        from PIL import Image
        png_path = webp_path.rsplit(".", 1)[0] + ".png"
        with Image.open(webp_path) as im:
            im.save(png_path, "PNG")
        return png_path
    except ImportError:
        print("[image_utils] WebP conversion skipped (Pillow not installed)", file=sys.stderr)
        return None
    except Exception as e:
        print(f"[image_utils] WebP conversion failed: {e}", file=sys.stderr)
        return None


def _is_photo(im) -> bool:
    """Heuristic: photos are RGB/RGBA without transparency and have many colors.
    Graphics/diagrams tend to have fewer unique colors or use transparency."""
    if im.mode in ("RGBA", "LA", "PA"):
        # Check if alpha channel is actually used (not all opaque)
        if im.mode == "RGBA":
            extrema = im.getextrema()
            if len(extrema) >= 4:
                alpha_min = extrema[3][0]
                if alpha_min < 250:  # has meaningful transparency
                    return False
    # Sample a small region to count unique colors
    thumb = im.copy()
    thumb.thumbnail((100, 100))
    if thumb.mode not in ("RGB", "RGBA"):
        thumb = thumb.convert("RGB")
    colors = thumb.getcolors(maxcolors=1000)
    if colors is None:
        # More than 1000 colors in 100x100 → almost certainly a photo
        return True
    return len(colors) > 256


def _optimize_image(local_path: str) -> str:
    """Optimize an image for presentation use: resize, compress, strip EXIF.

    - Resizes so max dimension is MAX_DIMENSION px (maintains aspect ratio)
    - Converts photos to JPEG at quality=85; keeps PNG for transparent graphics
    - Strips EXIF metadata
    - Returns path to optimized file (may be same or new path).
    - Falls back gracefully: returns original path if Pillow unavailable or error.
    """
    try:
        from PIL import Image, ImageOps
    except ImportError:
        # Pillow not available — skip optimization silently
        return local_path

    try:
        with Image.open(local_path) as im:
            original_mode = im.mode
            w, h = im.size

            # Strip EXIF by applying orientation then discarding metadata
            try:
                im = ImageOps.exif_transpose(im)
            except Exception:
                pass  # some images have malformed EXIF

            # Resize if larger than max dimension
            if max(w, h) > MAX_DIMENSION:
                im.thumbnail((MAX_DIMENSION, MAX_DIMENSION), Image.LANCZOS)

            # Decide output format
            has_transparency = original_mode in ("RGBA", "LA", "PA")
            if has_transparency and not _is_photo(im):
                # Keep as PNG for graphics with transparency
                out_path = local_path.rsplit(".", 1)[0] + ".png"
                if im.mode != "RGBA":
                    im = im.convert("RGBA")
                im.save(out_path, "PNG", optimize=True)
            else:
                # Convert to JPEG for photos (much smaller)
                out_path = local_path.rsplit(".", 1)[0] + ".jpg"
                if im.mode in ("RGBA", "LA", "PA", "P"):
                    # Flatten transparency onto white background
                    bg = Image.new("RGB", im.size, (255, 255, 255))
                    if im.mode == "P":
                        im = im.convert("RGBA")
                    bg.paste(im, mask=im.split()[-1] if im.mode == "RGBA" else None)
                    im = bg
                elif im.mode != "RGB":
                    im = im.convert("RGB")
                im.save(out_path, "JPEG", quality=JPEG_QUALITY, optimize=True)

            # Clean up original if we wrote a different file
            if out_path != local_path and os.path.exists(out_path):
                try:
                    os.remove(local_path)
                except OSError:
                    pass
                return out_path

            return local_path

    except Exception as e:
        print(f"[image_utils] Optimization failed, using original: {e}", file=sys.stderr)
        return local_path


def _download_with_retry(url: str, max_retries: int = MAX_RETRIES) -> bytes | None:
    """Download URL content with retry logic."""
    req = Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                      "AppleWebKit/537.36 (KHTML, like Gecko) "
                      "Chrome/120.0.0.0 Safari/537.36",
    })

    last_error = None
    for attempt in range(max_retries):
        try:
            ctx = ssl.create_default_context()
            try:
                resp = urlopen(req, timeout=TIMEOUT, context=ctx)
            except ssl.SSLCertVerificationError:
                # Only bypass cert verification, not other SSL errors
                ctx = ssl._create_unverified_context()
                resp = urlopen(req, timeout=TIMEOUT, context=ctx)

            data = resp.read(MAX_SIZE + 1)
            if len(data) > MAX_SIZE:
                print(f"[image_utils] Skipped (>{MAX_SIZE // 1024 // 1024}MB): {url}", file=sys.stderr)
                return None
            return data

        except (URLError, OSError, Exception) as e:
            last_error = e
            if attempt < max_retries - 1:
                time.sleep(1 * (attempt + 1))  # 1s, 2s backoff

    print(f"[image_utils] Download failed after {max_retries} attempts for {url}: {last_error}", file=sys.stderr)
    return None


def resolve_image(source: str, temp_dir: str = None) -> str | None:
    """Resolve an image source to a local file path.

    Args:
        source: Local file path or HTTP(S) URL.
        temp_dir: Directory for downloaded files. Created if None.

    Returns:
        Local file path to the image, or None on failure.
    """
    if not source:
        return None

    source = source.strip()

    # Local file
    if not source.startswith(("http://", "https://")):
        p = Path(source).expanduser()
        return str(p) if p.exists() else None

    # Check cache
    cache_key = hashlib.md5(source.encode()).hexdigest()
    if cache_key in _download_cache:
        cached = _download_cache[cache_key]
        if os.path.exists(cached):
            return cached

    # URL — download with retry
    data = _download_with_retry(source)
    if data is None:
        return None

    ext = _detect_ext(data)
    if not ext:
        print(f"[image_utils] Not a recognized image format: {source}", file=sys.stderr)
        return None

    if temp_dir is None:
        temp_dir = tempfile.mkdtemp(prefix="executer_imgs_")

    os.makedirs(temp_dir, exist_ok=True)
    fname = f"img_{cache_key[:12]}.{ext}"
    local_path = os.path.join(temp_dir, fname)
    with open(local_path, "wb") as f:
        f.write(data)

    # WebP → PNG conversion (python-pptx doesn't support WebP)
    if ext == "webp":
        png_path = _convert_webp_to_png(local_path)
        if png_path:
            local_path = png_path

    # Optimize image (resize, compress, strip EXIF) before caching
    local_path = _optimize_image(local_path)

    _download_cache[cache_key] = local_path
    return local_path


def cleanup_temp_images(temp_dir: str):
    """Remove temporary image directory."""
    if temp_dir and os.path.isdir(temp_dir):
        try:
            shutil.rmtree(temp_dir)
        except OSError:
            pass
