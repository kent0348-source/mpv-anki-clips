#!/usr/bin/env python3
"""Build and zip the self-contained Rust/Slint configuration GUI for this OS."""

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "config_gui" / "rust" / "Cargo.toml"
BUILD_ROOT = ROOT / "build" / "config-gui"
APP_NAME = "mpv-anki-clips-config"
MAX_PACKAGE_BYTES = 20 * 1024 * 1024


def build_package(version: str, output_dir: Path) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", version):
        raise ValueError(
            "Version must contain only letters, numbers, dots, underscores, plus signs, or hyphens."
        )
    if not MANIFEST.is_file():
        raise FileNotFoundError(f"Rust GUI manifest is missing: {MANIFEST}")

    build_environment = os.environ.copy()
    if platform.system() == "Windows":
        build_environment["RUSTFLAGS"] = (
            f"{build_environment.get('RUSTFLAGS', '')} -C target-feature=+crt-static"
        ).strip()
    subprocess.run(
        [
            "cargo",
            "build",
            "--locked",
            "--release",
            "--manifest-path",
            str(MANIFEST),
            "--target-dir",
            str(BUILD_ROOT / "target"),
        ],
        cwd=ROOT,
        env=build_environment,
        check=True,
    )

    executable_name = APP_NAME + (".exe" if platform.system() == "Windows" else "")
    executable = BUILD_ROOT / "target" / "release" / executable_name
    if not executable.is_file():
        raise FileNotFoundError(f"Cargo did not produce the GUI executable: {executable}")

    output_dir.mkdir(parents=True, exist_ok=True)
    system = platform.system().lower()
    machine = platform.machine().lower().replace(" ", "_")
    archive_path = output_dir / f"{APP_NAME}-{version}-{system}-{machine}.zip"
    with tempfile.TemporaryDirectory(prefix=f"{APP_NAME}-") as temporary:
        app_folder = Path(temporary) / APP_NAME
        app_folder.mkdir()
        shutil.copy2(executable, app_folder / executable_name)
        (app_folder / "README.txt").write_text(
            "MPV Anki Clips Config (portable)\n\n"
            "Keep this executable and README.txt together. No installer, Rust\n"
            "toolchain, or administrator permission is required. The app edits mpv's\n"
            "script-opts files under the config folder shown in the app; use Browse\n"
            "to select another. The add-on Lua runtime is installed separately in\n"
            "mpv's scripts folder. Changes take effect after restarting mpv. Existing\n"
            "configs are backed up as .bak files in this folder's config-backups folder.\n",
            encoding="utf-8",
        )
        packaged_size = sum(path.stat().st_size for path in app_folder.rglob("*") if path.is_file())
        if packaged_size >= MAX_PACKAGE_BYTES:
            raise ValueError(
                f"Portable GUI folder is {packaged_size / (1024 * 1024):.2f} MiB; "
                "the release limit is less than 20 MiB."
            )
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(app_folder.iterdir()):
                if path.is_file():
                    archive.write(path, (Path(APP_NAME) / path.name).as_posix())
        archive_size = archive_path.stat().st_size
        if archive_size >= MAX_PACKAGE_BYTES:
            archive_path.unlink()
            raise ValueError(
                f"Portable GUI ZIP is {archive_size / (1024 * 1024):.2f} MiB; "
                "the release limit is less than 20 MiB."
            )
    return archive_path


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build a portable folder-based GUI ZIP for the current OS."
    )
    parser.add_argument("--version", required=True, help="Release version, for example v1.0.0")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=ROOT / "build" / "releases",
        help="Where to write the portable ZIP (default: build/releases)",
    )
    args = parser.parse_args()
    try:
        archive = build_package(args.version, args.output_dir)
    except (FileNotFoundError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"GUI packaging failed: {error}", file=sys.stderr)
        return 1
    print(f"Created portable GUI package: {archive}")
    print(f"Portable folder and ZIP are each limited to less than 20 MiB.")
    print("Build separately on Windows and Ubuntu; each archive is for the OS where it was built.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
