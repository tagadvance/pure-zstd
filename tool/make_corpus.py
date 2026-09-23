#!/usr/bin/env python3
"""Builds the committed test corpus in test/fixtures/corpus/.

Every frame here is either produced by libzstd (through the `zstd` CLI or
pyzstd) or hand-built and then handed to pyzstd for a verdict, so "legal" and
"malformed" are libzstd's opinion rather than this file's. The expected plain
bytes of a legal frame are whatever pyzstd decompressed it to, gzipped so the
committed fixture stays small; nothing here writes an expectation by hand.

manifest.json records, per case, the exact command that made the frame. The
Dart tests read that manifest and never carry a literal of their own.

    ./tool/make_corpus.py          # regenerates test/fixtures/corpus

Needs pyzstd, the zstd CLI, and for the one real-tile case a .hgtz
container named in HGTZ_TILE.
"""

import gzip
import os
import json
import pathlib
import struct
import subprocess
import sys

import pyzstd

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "test" / "fixtures" / "corpus"
# One fixture is a block of real terrain lifted out of an elevation
# container. It is committed, so rebuilding it is optional: point HGTZ_TILE at
# a .hgtz file to regenerate it, and without one that case is left alone.
_TILE = os.environ.get("HGTZ_TILE")
TILE = pathlib.Path(_TILE) if _TILE else None
TILE_BLOCK = 183

MAGIC = struct.pack("<I", 0xFD2FB528)

cases = []
plains = {}


def plain(name, data):
    """Records `data` as a gzipped expectation file, returning its name."""
    if name not in plains:
        plains[name] = data
        (OUT / (name + ".raw.gz")).write_bytes(gzip.compress(data, 9, mtime=0))
    elif plains[name] != data:
        raise SystemExit(f"{name}: two different expectations")
    return name + ".raw.gz"


def legal(name, frame, parts, command, expected_size=None):
    """A frame pyzstd accepts. `parts` name the gzipped expectation files."""
    want = b"".join(plains[p[: -len(".raw.gz")]] for p in parts)
    got = pyzstd.decompress(frame)
    if got != want:
        raise SystemExit(f"{name}: pyzstd gives {len(got)} bytes, wanted {len(want)}")
    (OUT / (name + ".zst")).write_bytes(frame)
    entry = {
        "name": name,
        "frame": name + ".zst",
        "command": command,
        "verdict": "legal",
        "plain": parts,
        "size": len(want),
    }
    if expected_size is not None:
        entry["expectedSize"] = expected_size
    cases.append(entry)


def illegal(name, frame, command, note):
    """A frame pyzstd refuses, or one no decoder should accept."""
    try:
        pyzstd.decompress(frame)
    except Exception as error:
        note = f"{note}; pyzstd refuses it: {type(error).__name__}"
    else:
        note = f"{note}; NOTE pyzstd accepts this one"
    (OUT / (name + ".zst")).write_bytes(frame)
    cases.append(
        {
            "name": name,
            "frame": name + ".zst",
            "command": command,
            "verdict": "refused",
            "why": note,
        }
    )


def cli(args, data, name="stdin"):
    """Runs the zstd CLI. A file argument and a pipe differ: from a pipe the
    size is unknown, so the frame comes out windowed with no content size."""
    if name == "stdin":
        run = subprocess.run(
            ["zstd", "-q", "-c"] + args,
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    else:
        scratch = OUT / name
        scratch.write_bytes(data)
        run = subprocess.run(
            ["zstd", "-q", "-c"] + args + [str(scratch)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        scratch.unlink()
    if run.returncode != 0:
        raise SystemExit(f"zstd {args}: {run.stderr.decode()}")
    return run.stdout


# --------------------------------------------------------------------------
# The plain inputs several cases share. A is incompressible, and pseudo-random
# rather than random so that regenerating the corpus gives the same bytes.
#
# The same xorshift64 is written out again in test/corpus.dart, because the
# three cases too large to commit build their input in the test and compress
# it with the zstd CLI there.
# --------------------------------------------------------------------------

MASK64 = (1 << 64) - 1


def xorshift(seed, count):
    state = seed
    out = bytearray(count)
    for i in range(count):
        state ^= (state << 13) & MASK64
        state ^= state >> 7
        state ^= (state << 17) & MASK64
        out[i] = (state >> 33) & 0xFF
    return bytes(out)


A = xorshift(0x9E3779B97F4A7C15, 5000)
B = b"the quick brown fox " * 500
TEXT = b"the quick brown fox jumps over the lazy dog. " * 24000


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    for stale in OUT.glob("*"):
        stale.unlink()

    a = plain("A", A)
    b = plain("B", B)

    # 1. Two frames in one buffer. pyzstd returns A+B; a decoder that reads
    #    one frame must refuse rather than return A and stop.
    legal(
        "twoframes",
        pyzstd.compress(A, 3) + pyzstd.compress(B, 3),
        [a, b],
        "python3: pyzstd.compress(A, 3) + pyzstd.compress(B, 3), "
        "A = 5000 xorshift64 bytes, B = b'the quick brown fox ' * 500",
    )
    cases[-1]["trailing"] = "a second complete frame"

    # 2. A frame with a content checksum. The three malformed variants are
    #    derived from this one in the test; pyzstd's verdict on each is
    #    recorded here so nothing is asserted on faith.
    checked = cli(["-3", "--check"], A, "A.bin")
    legal("checksum_good", checked, [a], "zstd -q -c -3 --check A.bin")
    for name, label, variant in (
        (
            "checksum_flipped",
            "the last checksum byte flipped",
            checked[:-1] + bytes([checked[-1] ^ 0x01]),
        ),
        (
            "checksum_zeroed",
            "all four checksum bytes zeroed",
            checked[:-4] + b"\0\0\0\0",
        ),
        (
            "checksum_truncated",
            "the last two bytes cut",
            checked[:-2],
        ),
    ):
        try:
            pyzstd.decompress(variant)
        except Exception as error:
            verdict = f"pyzstd refuses it: {type(error).__name__}"
        else:
            verdict = "NOTE pyzstd accepts it"
        cases.append(
            {
                "name": name,
                "frame": "checksum_good.zst",
                "command": f"zstd -q -c -3 --check A.bin, then {label}",
                "verdict": "refused",
                "why": verdict,
                "derive": label,
            }
        )

    # 3. Frame_Content_Size_flag = 3 declaring a size no machine will give.
    #    Built by rewriting a real frame's descriptor, so everything after the
    #    header is a frame libzstd wrote.
    base = pyzstd.compress(b"hello world", 3)
    assert base[4] >> 6 == 0 and (base[4] >> 5) & 1 == 1, base[4]
    for label, declared in (
        ("fcs_max_u64", (1 << 64) - 1),
        ("fcs_2p40", 1 << 40),
    ):
        frame = base[:4] + bytes([(3 << 6) | (base[4] & 0x3F)])
        frame += declared.to_bytes(8, "little") + base[6:]
        illegal(
            label,
            frame,
            f"python3: pyzstd.compress(b'hello world', 3) with the descriptor "
            f"rewritten to Frame_Content_Size_flag=3 declaring {declared}",
            "a 27-byte frame asking for a size no allocator will give",
        )

    # 3b. The same eight-byte content size on a frame that is legal, so the
    #     branch is reached by something that decodes and not only by two
    #     frames refused on the way past it.
    legal(
        "fcs8",
        rewrite_fcs8(pyzstd.compress(B, 3), len(B)),
        [b],
        "python3: pyzstd.compress(B, 3) with the descriptor rewritten to "
        "Frame_Content_Size_flag=3 and an 8-byte size",
    )

    # 4. The 53-byte frame that walked fseDecodeInterleaved past _weights[255].
    #    Hand-built: a compressed block whose literals carry an FSE-coded
    #    Huffman weight stream long enough to emit 257 weights.
    weights = bytes([0x10, 0x3F]) + bytes([0xAA] * 33) + bytes([0x02])
    body = bytes([0xA2, 0x00, 0x0A])  # compressed literals, 10 regenerated
    body += bytes([len(weights)]) + weights
    body += bytes([0x01, 0x01, 0x01, 0x00])  # sequence section, never reached
    frame = MAGIC + bytes([0x20, 0x0A]) + blockhdr(1, 2, len(body)) + body
    illegal(
        "huf_weight_overrun",
        frame,
        "hand-built: a compressed block whose Huffman weight description is "
        "[0x10, 0x3F] and whose FSE weight stream is 33 x 0xAA then 0x02",
        "the weight stream decodes past the 256th weight",
    )

    # 5. RLE literals with Number_of_Sequences = 0, at every size format.
    #    libzstd never emits these: it writes an RLE block instead.
    for fmt, count in ((0, 31), (1, 4000), (2, 70000), (2, 131072)):
        body = rle_literals(count, 0x5A, fmt)
        name = f"rlelit_fmt{fmt}_R{count}"
        expect = plain(name, bytes([0x5A]) * count)
        legal(
            name,
            single_frame([blockhdr(1, 2, len(body)) + body], count),
            [expect],
            f"hand-built: one compressed block, RLE literals Size_Format={fmt}, "
            f"Regenerated_Size={count}, byte 0x5A, Number_of_Sequences=0",
        )

    # 6. RLE and raw blocks, which the real .hgtz corpus contains none of.
    content = b"\xab" * 5000 + b"hello world hello world hello wor" + b"\x07" * 40000
    assert len(content) == 5000 + 33 + 40000
    blocks = [
        blockhdr(0, 1, 5000) + b"\xab",
        blockhdr(0, 0, 33) + content[5000:5033],
        blockhdr(1, 1, 40000) + b"\x07",
    ]
    expect = plain("mixed_rle_raw", content)
    legal(
        "mixed_rle_raw",
        single_frame(blocks, len(content)),
        [expect],
        "hand-built: [RLE 5000 x 0xAB][raw 33 bytes][RLE 40000 x 0x07] "
        "in one frame",
    )

    # 7. No Frame_Content_Size at all: the shape the CLI writes from a pipe.
    frame = cli(["-3", "--no-check"], TEXT)
    assert frame[4] >> 6 == 0 and (frame[4] >> 5) & 1 == 0, frame[4]
    expect = plain("text", TEXT)
    legal(
        "nofcs_windowed",
        frame,
        [expect],
        "zstd -3 --no-check from stdin over "
        "b'the quick brown fox jumps over the lazy dog. ' * 24000",
        expected_size=len(TEXT),
    )

    # 11. A real block that codes its Huffman weights as direct nibbles. The
    #     synthetic shapes above never produce one, and the committed
    #     container has none. Terrain is not ours to redistribute freely, so
    #     the one committed here carries its licence's attribution in the
    #     manifest; see the README's acknowledgements.
    if TILE is None:
        print("HGTZ_TILE not set: leaving direct_nibble as committed")
    else:
        tile = TILE.read_bytes()
        offset, length = struct.unpack_from(">II", tile, 12 + 8 * TILE_BLOCK)
        frame = bytes(tile[offset : offset + length])
        assert direct_nibble_weights(frame), "that block is not direct nibbles"
        expect = plain("direct_nibble", pyzstd.decompress(frame))
        legal(
            "direct_nibble",
            frame,
            [expect],
            f"block {TILE_BLOCK} of a Copernicus GLO-30 elevation tile "
            "transcoded into a .hgtz container, lifted out as its own frame; "
            "its literals carry the direct-nibble Huffman weight form",
        )

    # 13. Dictionary_ID_flag set on a frame that carries no dictionary id.
    base = pyzstd.compress(A, 3)
    illegal(
        "dictflag",
        base[:4] + bytes([base[4] | 1]) + base[5:],
        "python3: pyzstd.compress(A, 3) with Dictionary_ID_flag forced to 1 "
        "in the frame header descriptor",
        "a dictionary this decoder does not have",
    )

    (OUT / "manifest.json").write_text(json.dumps(cases, indent=2) + "\n")
    total = sum(f.stat().st_size for f in OUT.iterdir())
    print(f"{len(cases)} cases, {len(list(OUT.iterdir()))} files, {total} bytes")


def rewrite_fcs8(frame, size):
    """The same frame with an 8-byte Frame_Content_Size in place of its own."""
    descriptor = frame[4]
    single = (descriptor >> 5) & 1
    at = 5 + (0 if single else 1)
    width = {0: 1 if single else 0, 1: 2, 2: 4, 3: 8}[descriptor >> 6]
    return (
        frame[:4]
        + bytes([(3 << 6) | (descriptor & 0x3F)])
        + frame[5:at]
        + size.to_bytes(8, "little")
        + frame[at + width :]
    )


def blockhdr(last, btype, size):
    return struct.pack("<I", (size << 3) | (btype << 1) | last)[:3]


def rle_literals(count, byte, fmt):
    """A compressed block body: RLE literals, then Number_of_Sequences = 0."""
    if fmt == 0:
        assert count < 32
        body = bytes([(count << 3) | (0 << 2) | 1, byte])
    elif fmt == 1:
        assert count < 4096
        body = bytes([((count & 0xF) << 4) | (1 << 2) | 1, count >> 4, byte])
    else:
        assert count < (1 << 20)
        body = bytes(
            [
                ((count & 0xF) << 4) | (3 << 2) | 1,
                (count >> 4) & 0xFF,
                count >> 12,
                byte,
            ]
        )
    return body + b"\x00"


def single_frame(blocks, size):
    """A single-segment frame declaring `size` and carrying `blocks`."""
    if size < 256:
        descriptor, field = (0 << 6) | (1 << 5), bytes([size])
    elif size < 65536 + 256:
        descriptor, field = (1 << 6) | (1 << 5), struct.pack("<H", size - 256)
    else:
        descriptor, field = (2 << 6) | (1 << 5), struct.pack("<I", size)
    return MAGIC + bytes([descriptor]) + field + b"".join(blocks)


def direct_nibble_weights(frame):
    """True when the frame's first block codes Huffman weights as nibbles."""
    descriptor = frame[4]
    at = 5 + (0 if (descriptor >> 5) & 1 else 1)
    at += {0: 1 if (descriptor >> 5) & 1 else 0, 1: 2, 2: 4, 3: 8}[descriptor >> 6]
    header = frame[at] | (frame[at + 1] << 8) | (frame[at + 2] << 16)
    at += 3
    if (header >> 1) & 3 != 2:
        return False
    literals = frame[at]
    if literals & 3 != 2:
        return False
    at += {0: 3, 1: 3, 2: 4, 3: 5}[(literals >> 2) & 3]
    return frame[at] >= 128


if __name__ == "__main__":
    sys.exit(build())
