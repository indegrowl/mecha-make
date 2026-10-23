#!/usr/bin/env python3
# Build the DSPP colour calibration firmware for the Nothing Phone (4a)
# (qcom/milos/nothing-frogger-dspp.bin), read by the msm DPU driver.
#
# --pattern qdcm      stock QDCM tables (decoded from vendor/etc/display/
#                     qdcm_calib_data_nt37706a_..._BOE_panel_with_DSC.json):
#                     gamut_<table>.json, igc_Rec601.json, gc_Rec601noDither.json
# --pattern identity  gamma 2.2 IGC, identity gamut, 1/2.2 GC (should look unchanged)
# --pattern red-only  identity, but the gamut outputs only the red input
#
# Format v1, little-endian: "DSPC", u32 version, u32 igc_n=257, u32 gamut_dim=17,
# u32 gc_n=1024, u16 igc[3][257] (R,G,B, 12-bit), u16 gamut[4913][3] ([R,G,B]
# 12-bit, index r + 17g + 289b), u16 gc[3][1024] (R,G,B, 10-bit), u32 crc32.
import argparse
import json
import os
import struct
import sys
import zlib

IGC_N, DIM, GC_N = 257, 17, 1024
GAMUT_N = DIM ** 3


def clamp(v, bits):
    return max(0, min((1 << bits) - 1, int(round(v))))


def identity_tables(red_only):
    igc = [clamp(4095 * (i / 256) ** 2.2, 12) for i in range(IGC_N)]
    gc = [clamp(1023 * (i / 1023) ** (1 / 2.2), 10) for i in range(GC_N)]
    gamut = []
    for n in range(GAMUT_N):
        r, g, b = (clamp(4095 * x / 16, 12) for x in (n % DIM, n // DIM % DIM, n // DIM ** 2))
        gamut.append([r, 0, 0] if red_only else [r, g, b])
    return igc, gamut, gc


def qdcm_tables(qdcm_dir, table):
    def load(name):
        with open(os.path.join(qdcm_dir, name)) as f:
            return json.load(f)

    igc = [clamp(v, 12) for v in load("igc_Rec601.json")]
    gc = [clamp(v, 10) for v in load("gc_Rec601noDither.json")]
    gamut = [[clamp(c, 12) for c in e] for e in load(f"gamut_{table}.json")]
    if len(igc) != IGC_N or len(gc) != GC_N or len(gamut) != GAMUT_N:
        sys.exit(f"unexpected table sizes: igc {len(igc)}, gc {len(gc)}, gamut {len(gamut)}")
    return igc, gamut, gc


def blob(igc, gamut, gc):
    out = b"DSPC" + struct.pack("<4I", 1, IGC_N, DIM, GC_N)
    out += struct.pack(f"<{3 * IGC_N}H", *(igc * 3))
    out += struct.pack(f"<{3 * GAMUT_N}H", *(c for e in gamut for c in e))
    out += struct.pack(f"<{3 * GC_N}H", *(gc * 3))
    return out + struct.pack("<I", zlib.crc32(out))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pattern", choices=["qdcm", "identity", "red-only"], required=True)
    ap.add_argument("--qdcm-dir", default=os.path.expanduser(
        "~/projects/nothing-4a-linux/research_notes/dspp-color-2026-10-23/qdcm/qdcm_out"))
    ap.add_argument("--table", type=int, default=0, help="QDCM gamut table (0 = Alive)")
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()
    if a.pattern == "qdcm":
        tables = qdcm_tables(a.qdcm_dir, a.table)
    else:
        tables = identity_tables(a.pattern == "red-only")
    with open(a.output, "wb") as f:
        f.write(blob(*tables))


if __name__ == "__main__":
    main()
