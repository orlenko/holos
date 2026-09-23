#!/usr/bin/env python3
"""Safely import local Otter ZIP pairs into ignored evaluation storage.

No transcript text or private filenames are printed. Existing imports are never overwritten.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
from zipfile import ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "reference-data" / "otter"
DESTINATION = ROOT / ".local" / "evaluation" / "otter-inputs"
MAX_FILES = 100
MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024
MAX_RATIO = 200


def validated_parts(info: ZipInfo) -> tuple[str, ...]:
    name = info.filename
    if (not name or name.startswith("/") or "\\" in name or "\x00" in name
            or any(ord(char) < 32 for char in name)
            or re.match(r"^[A-Za-z]:", name)):
        raise ValueError("ZIP contains an unsafe path")
    parts = tuple(name.rstrip("/").split("/"))
    if not parts or len(parts) > 8 or any(part in ("", ".", "..") for part in parts):
        raise ValueError("ZIP contains an unsafe path")
    mode = (info.external_attr >> 16) & 0xFFFF
    kind = stat.S_IFMT(mode)
    if kind not in (0, stat.S_IFDIR if info.is_dir() else stat.S_IFREG):
        raise ValueError("ZIP contains a link or special file")
    if info.flag_bits & 1:
        raise ValueError("Encrypted ZIP entries are unsupported")
    return parts


def inventory(archive: ZipFile) -> list[tuple[ZipInfo, tuple[str, ...]]]:
    entries = archive.infolist()
    if len(entries) > MAX_FILES:
        raise ValueError("ZIP has too many entries")
    seen: set[str] = set()
    total = 0
    safe: list[tuple[ZipInfo, tuple[str, ...]]] = []
    for info in entries:
        parts = validated_parts(info)
        canonical = "/".join(parts).casefold()
        if canonical in seen:
            raise ValueError("ZIP has colliding paths")
        seen.add(canonical)
        if not info.is_dir():
            if info.file_size > MAX_FILE_BYTES:
                raise ValueError("ZIP entry exceeds the size limit")
            if info.file_size and (not info.compress_size or info.file_size / info.compress_size > MAX_RATIO):
                raise ValueError("ZIP entry exceeds the expansion limit")
            total += info.file_size
            if total > MAX_TOTAL_BYTES:
                raise ValueError("ZIP exceeds the total size limit")
        safe.append((info, parts))
    return safe


def private_destination() -> None:
    current = ROOT
    for part in (".local", "evaluation", "otter-inputs"):
        current = current / part
        if current.is_symlink():
            raise ValueError("Evaluation destination contains a symbolic link")
        existed = current.exists()
        current.mkdir(mode=0o700, exist_ok=True)
        if not current.is_dir():
            raise ValueError("Evaluation destination is not a directory")
        if not existed:
            current.chmod(0o700)


def import_archive(zip_path: Path, entries: list[tuple[ZipInfo, tuple[str, ...]]]) -> None:
    target = DESTINATION / zip_path.stem
    if target.exists() or target.is_symlink():
        print(f"{zip_path.stem}: already imported; left unchanged")
        return
    temporary = Path(tempfile.mkdtemp(prefix=f".{zip_path.stem}-", dir=DESTINATION))
    try:
        with ZipFile(zip_path) as archive:
            entries = inventory(archive)
            for info, parts in entries:
                output = temporary.joinpath(*parts)
                if info.is_dir():
                    output.mkdir(mode=0o700, parents=True, exist_ok=True)
                    output.chmod(0o700)
                    continue
                output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                copied = 0
                with archive.open(info) as source, os.fdopen(descriptor, "wb") as destination:
                    while block := source.read(1024 * 1024):
                        copied += len(block)
                        if copied > info.file_size or copied > MAX_FILE_BYTES:
                            raise ValueError("ZIP content exceeds declared size")
                        destination.write(block)
                    destination.flush()
                    os.fsync(destination.fileno())
                if copied != info.file_size:
                    raise ValueError("ZIP content size does not match metadata")
        if target.exists() or target.is_symlink():
            raise ValueError("Import destination appeared during extraction")
        os.rename(temporary, target)
        print(f"{zip_path.stem}: imported {sum(not info.is_dir() for info, _ in entries)} files")
    except Exception:
        shutil.rmtree(temporary)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extract", action="store_true", help="Extract into ignored private evaluation storage")
    args = parser.parse_args()
    archives = sorted(SOURCE.glob("[0-9][0-9][0-9].zip"))
    if not archives:
        raise SystemExit("No numbered reference ZIPs found")
    for zip_path in archives:
        with ZipFile(zip_path) as archive:
            entries = inventory(archive)
        file_count = sum(not info.is_dir() for info, _ in entries)
        total = sum(info.file_size for info, _ in entries if not info.is_dir())
        print(f"{zip_path.stem}: {file_count} safe files, {total} uncompressed bytes")
        if args.extract:
            private_destination()
            import_archive(zip_path, entries)


if __name__ == "__main__":
    main()
