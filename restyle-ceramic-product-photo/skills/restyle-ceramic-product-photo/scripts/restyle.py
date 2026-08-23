#!/usr/bin/env python3
"""Bootstrap and run the reproducible ceramic-photo restyle pipeline."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL_ROOT / "scripts"
LOCK_FILE = SCRIPTS / "requirements.lock"
RENDERER = SCRIPTS / "render.py"
MODEL_NAME = "isnet-general-use.onnx"
MODEL_URL = (
    "https://github.com/danielgatis/rembg/releases/download/v0.0.0/"
    "isnet-general-use.onnx"
)
MODEL_SHA256 = "60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a"
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff"}
RUNTIME_FLAG = "CERAMIC_RESTYLE_RUNTIME"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_model(path: Path) -> None:
    actual = sha256_file(path)
    if actual != MODEL_SHA256:
        raise RuntimeError(
            f"model checksum mismatch: expected {MODEL_SHA256}, got {actual}"
        )


def cache_root() -> Path:
    base = os.environ.get("XDG_CACHE_HOME")
    if base:
        return Path(base) / "restyle-ceramic-product-photo"
    return Path.home() / ".cache" / "restyle-ceramic-product-photo"


def find_compatible_python() -> str:
    candidates = [sys.executable, "python3.12", "python3.11", "python3.10", "python3.9"]
    checked = set()
    for candidate in candidates:
        resolved = shutil.which(candidate) if not Path(candidate).is_file() else candidate
        if not resolved or str(resolved) in checked:
            continue
        checked.add(str(resolved))
        probe = subprocess.run(
            [
                str(resolved),
                "-c",
                "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')",
            ],
            text=True,
            capture_output=True,
        )
        if probe.returncode == 0:
            major, minor = map(int, probe.stdout.strip().split("."))
            if major == 3 and 9 <= minor <= 12:
                return str(resolved)
    raise RuntimeError("Python 3.9–3.12 is required; no compatible interpreter found")


def runtime_python(venv: Path) -> Path:
    if os.name == "nt":
        return venv / "Scripts" / "python.exe"
    return venv / "bin" / "python"


def ensure_runtime() -> Path:
    lock_hash = sha256_file(LOCK_FILE)[:12]
    root = cache_root() / f"runtime-{lock_hash}"
    python = runtime_python(root)
    marker = root / ".ready"
    if marker.is_file() and python.is_file():
        return python

    root.parent.mkdir(parents=True, exist_ok=True)
    if not python.is_file():
        subprocess.run([find_compatible_python(), "-m", "venv", str(root)], check=True)
    subprocess.run(
        [
            str(python),
            "-m",
            "pip",
            "install",
            "--disable-pip-version-check",
            "-r",
            str(LOCK_FILE),
        ],
        check=True,
    )
    marker.write_text(lock_hash + "\n", encoding="utf-8")
    return python


def ensure_model() -> Path:
    model_dir = cache_root() / "models" / MODEL_SHA256
    model = model_dir / MODEL_NAME
    if model.is_file():
        verify_model(model)
        return model

    model_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=model_dir, suffix=".download", delete=False) as temp:
        temp_path = Path(temp.name)
    try:
        print(f"Downloading pinned segmentation model ({MODEL_NAME})…", flush=True)
        urllib.request.urlretrieve(MODEL_URL, temp_path)
        verify_model(temp_path)
        os.replace(temp_path, model)
    finally:
        if temp_path.exists():
            temp_path.unlink()
    return model


def plan_batch(source: Path, output_dir: Path):
    images = sorted(
        (
            path
            for path in source.iterdir()
            if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
        ),
        key=lambda path: path.name.casefold(),
    )
    planned = []
    used = set()
    for image in images:
        stem = image.stem
        candidate = f"{stem}-styled.jpg"
        index = 2
        while candidate.casefold() in used:
            candidate = f"{stem}-styled-{index}.jpg"
            index += 1
        used.add(candidate.casefold())
        planned.append((image, output_dir / candidate))
    return planned


def render_one(source: Path, output: Path, force: bool) -> None:
    if output.exists() and not force:
        raise FileExistsError(f"output exists (use --force to replace): {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    model = ensure_model()
    env["U2NET_HOME"] = str(model.parent)
    temp_root = cache_root() / "tmp"
    temp_root.mkdir(parents=True, exist_ok=True)
    env["TMPDIR"] = str(temp_root)
    subprocess.run(
        [sys.executable, str(RENDERER), str(source), str(output)],
        check=True,
        env=env,
    )


def parse_args():
    parser = argparse.ArgumentParser(
        description="Apply the pinned soft upper-left studio preset to ceramic photos."
    )
    parser.add_argument("input", type=Path, help="Input image or folder")
    parser.add_argument("output", type=Path, nargs="?", help="Output image or folder")
    parser.add_argument("--force", action="store_true", help="Replace existing outputs")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source = args.input.expanduser().resolve()
    if not source.exists():
        raise FileNotFoundError(f"input does not exist: {source}")

    if os.environ.get(RUNTIME_FLAG) != "1":
        python = ensure_runtime()
        env = os.environ.copy()
        env[RUNTIME_FLAG] = "1"
        command = [str(python), str(Path(__file__).resolve()), *sys.argv[1:]]
        return subprocess.run(command, env=env).returncode

    if source.is_dir():
        output = (
            args.output.expanduser().resolve()
            if args.output
            else source.with_name(source.name + "-styled")
        )
        jobs = plan_batch(source, output)
        if not jobs:
            raise RuntimeError(f"no supported images found in {source}")
        for image, destination in jobs:
            print(f"{image.name} -> {destination.name}", flush=True)
            render_one(image, destination, args.force)
    else:
        output = (
            args.output.expanduser().resolve()
            if args.output
            else source.with_name(source.stem + "-styled.jpg")
        )
        render_one(source, output, args.force)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, FileExistsError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
