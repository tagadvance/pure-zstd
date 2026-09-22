#!/usr/bin/env python3
"""Check the Dart decoder against pyzstd over real .hgtz containers.

    ./tool/oracle.py path/to/srtm1z/N39W105.hgtz
    ./tool/oracle.py --every 1500 --limit 8 path/to/srtm1z

pyzstd is the reference. Every block of every container named is extracted as
its own frame, decompressed by pyzstd, and handed to tool/verify.dart, which
decodes it again and compares byte for byte. One tile at a time, through a
temporary directory that is deleted as it goes, because a whole tile's blocks
decompress to around 29 MB.
"""

from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import pyzstd

HEADER = ">4sBbHHH"
ENTRY = ">II"


def frames(path: Path):
    """Yields (index, frame bytes, expected decompressed size) per block."""
    data = path.read_bytes()
    magic, version, _level, rows, cols, block = struct.unpack_from(HEADER, data)
    if magic != b"HGTZ" or version != 1:
        raise SystemExit(f"{path}: not a version 1 .hgtz")
    block_cols = (cols + block - 1) // block
    block_rows = (rows + block - 1) // block
    for index in range(block_rows * block_cols):
        offset, length = struct.unpack_from(ENTRY, data, 12 + 8 * index)
        top = (index // block_cols) * block
        left = (index % block_cols) * block
        height = min(block, rows - top)
        width = min(block, cols - left)
        yield index, data[offset : offset + length], height * width * 2


def check(path: Path, root: Path) -> bool:
    with tempfile.TemporaryDirectory() as name:
        directory = Path(name)
        count = 0
        for index, frame, expected in frames(path):
            plain = pyzstd.decompress(frame)
            if len(plain) != expected:
                raise SystemExit(
                    f"{path} block {index}: pyzstd gave {len(plain)},"
                    f" the index implies {expected}"
                )
            (directory / f"{index:05d}.zst").write_bytes(frame)
            (directory / f"{index:05d}.raw").write_bytes(plain)
            count += 1
        result = subprocess.run(
            ["dart", "run", "tool/verify.dart", str(directory)],
            cwd=root,
            capture_output=True,
            text=True,
        )
        line = result.stdout.strip().splitlines()[-1] if result.stdout else ""
        print(f"{path.name}: {count} blocks, {line or result.stderr.strip()}")
        return result.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument(
        "--every",
        type=int,
        default=1,
        help="when a directory is named, take every Nth container",
    )
    parser.add_argument("--limit", type=int, default=0)
    arguments = parser.parse_args()

    containers: list[Path] = []
    for path in arguments.paths:
        if path.is_dir():
            found = sorted(path.glob("*.hgtz"))
            containers += found[:: arguments.every]
        else:
            containers.append(path)
    if arguments.limit:
        containers = containers[: arguments.limit]

    root = Path(__file__).resolve().parent.parent
    failures = [c for c in containers if not check(c, root)]
    if failures:
        print(f"FAILED on {len(failures)} of {len(containers)} containers")
        return 1
    print(f"all {len(containers)} containers match pyzstd byte for byte")
    return 0


if __name__ == "__main__":
    sys.exit(main())
