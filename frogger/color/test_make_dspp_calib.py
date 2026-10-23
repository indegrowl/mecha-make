#!/usr/bin/env python3
# Tests for make-dspp-calib.py: python3 -m unittest -v frogger/color/test_make_dspp_calib.py
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "make-dspp-calib.py")
QDCM = os.path.expanduser(
    "~/projects/nothing-4a-linux/research_notes/dspp-color-2026-10-23/qdcm/qdcm_out")

IGC_OFF, GAMUT_OFF, GC_OFF, CRC_OFF, SIZE = 20, 1562, 31040, 37184, 37188


def build(*args):
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "calib.bin")
        subprocess.run([sys.executable, TOOL, *args, "-o", out], check=True)
        with open(out, "rb") as f:
            return f.read()


def gamut(blob, n):
    return list(struct.unpack_from("<3H", blob, GAMUT_OFF + 6 * n))


def igc(blob, ch, i):
    return struct.unpack_from("<H", blob, IGC_OFF + 2 * (257 * ch + i))[0]


def gc(blob, ch, i):
    return struct.unpack_from("<H", blob, GC_OFF + 2 * (1024 * ch + i))[0]


class MakeDsppCalib(unittest.TestCase):
    def test_size_and_header(self):
        b = build("--pattern", "identity")
        self.assertEqual(len(b), SIZE)
        self.assertEqual(b[:4], b"DSPC")
        self.assertEqual(struct.unpack_from("<4I", b, 4), (1, 257, 17, 1024))

    def test_crc(self):
        b = build("--pattern", "identity")
        self.assertEqual(struct.unpack_from("<I", b, CRC_OFF)[0], zlib.crc32(b[:CRC_OFF]))

    def test_qdcm_table0_corners(self):
        b = build("--pattern", "qdcm", "--qdcm-dir", QDCM, "--table", "0")
        self.assertEqual(gamut(b, 0), [0, 0, 0])
        self.assertEqual(gamut(b, 16), [3307, 82, 0])
        self.assertEqual(gamut(b, 4912), [4022, 4054, 3806])
        for ch in range(3):
            self.assertAlmostEqual(igc(b, ch, 128), round(0.217 * 4095), delta=2)

    def test_identity(self):
        b = build("--pattern", "identity")
        self.assertEqual(gamut(b, 16), [4095, 0, 0])
        self.assertEqual(gamut(b, 289 * 8), [0, 0, 2048])
        for ch in range(3):
            self.assertEqual(igc(b, ch, 256), 4095)
            self.assertEqual(gc(b, ch, 1023), 1023)

    def test_red_only(self):
        b = build("--pattern", "red-only")
        self.assertEqual(gamut(b, 4912), [4095, 0, 0])


if __name__ == "__main__":
    unittest.main()
