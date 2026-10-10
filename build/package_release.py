#!/usr/bin/env python3
"""Package the mpv-anki-clips runtime as a GitHub-release-ready ZIP."""

import argparse
import re
import sys
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
RUNTIME_DIR = ROOT / "src" / "mpv-anki-clips"
DEFAULT_OUTPUT_DIR = ROOT / "build" / "releases"
PACKAGE_NAME = "mpv-anki-clips"


def package_runtime(version: str, output_dir: Path) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", version):
        raise ValueError("Version must contain only letters, numbers, dots, underscores, plus signs, or hyphens.")
    if not RUNTIME_DIR.is_dir():
        raise FileNotFoundError("Runtime directory was not found: {}".format(RUNTIME_DIR))

    files = sorted(
        path
        for path in RUNTIME_DIR.rglob("*")
        if path.is_file()
        and "__pycache__" not in path.parts
        and path.suffix.lower() not in {".pyc", ".luac"}
        and path.name not in {".DS_Store", "Thumbs.db", "Desktop.ini"}
    )
    if not files:
        raise FileNotFoundError("No runtime files found in {}".format(RUNTIME_DIR))

    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path = output_dir / "{}-{}.zip".format(PACKAGE_NAME, version)
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            relative_path = path.relative_to(RUNTIME_DIR)
            archive_name = (Path(PACKAGE_NAME) / relative_path).as_posix()
            archive.write(path, archive_name)

    return archive_path


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create a versioned ZIP of the mpv-anki-clips runtime for a GitHub release."
    )
    parser.add_argument(
        "--version",
        required=True,
        help="Release version or tag, for example v1.2.3",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help="Directory for the ZIP (default: build/releases)",
    )
    args = parser.parse_args()

    try:
        archive_path = package_runtime(args.version, args.output_dir)
    except (FileNotFoundError, OSError, ValueError, zipfile.BadZipFile) as error:
        print("Packaging failed: {}".format(error), file=sys.stderr)
        return 1

    print("Created release package: {}".format(archive_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
