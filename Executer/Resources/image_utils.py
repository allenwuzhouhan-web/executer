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

    _download_cache[cache_key] = local_path
    return local_path


def cleanup_temp_images(temp_dir: str):
    """Remove temporary image directory."""
    if temp_dir and os.path.isdir(temp_dir):
        try:
            shutil.rmtree(temp_dir)
        except OSError:
            pass
