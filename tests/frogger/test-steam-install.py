#!/usr/bin/env python3
# Checks the first-open Steam client installer (frogger-steam-install).
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
here = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader(
    "fsi", str(repo / "mkosi.extra.frogger/usr/libexec/frogger-steam-install"))
spec = importlib.util.spec_from_loader("fsi", loader)
fsi = importlib.util.module_from_spec(spec)
loader.exec_module(fsi)


def vz_entry(name, data):
    return {"zipvz": f"{name}.zip.vz.abc_{len(data)}",
            "sha2vz": hashlib.sha256(data).hexdigest()}


class Installer(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_parse_manifest(self):
        m = fsi.parse_manifest((here / "steam-fixtures/manifest.vdf").read_text())
        e = m["bins_linuxarm64_linuxarm64"]
        self.assertEqual(e["file"], "bins_linuxarm64_linuxarm64.zip.426e3ea97690dd3ddacbfb4b509a4ca9e916b62d")
        self.assertEqual(e["sha2"], "a77faaf185f7b0681886d1c30e989d2cd1821cea421d41556e733b9d065b85a1")
        self.assertEqual(e["zipvz"], "bins_linuxarm64_linuxarm64.zip.vz.58c5cb12cb236d192c285c8935557fa1bdea1c02_61432555")
        self.assertEqual(e["sha2vz"], "dcedf6272899aa60c694d2a28394850b2ae6860ba88b5460708b684b6057b29e")
        self.assertEqual(m["tenfoot_images_all"]["size"], "6582204")
        self.assertEqual(m["version"], "1792099137")

    def test_extract_converts_backslashes(self):
        z = self.dir / "b.zip"
        with zipfile.ZipFile(z, "w") as f:
            f.writestr("steamrtarm64\\steam", b"\x7fELF fake")
            f.writestr("steamrtarm64\\builddate.txt", b"today")
            f.writestr("..\\evil", b"x")
        dest = self.dir / "Steam"
        fsi.extract_bootstrap(z, dest)
        steam = dest / "steamrtarm64/steam"
        self.assertEqual(steam.read_bytes(), b"\x7fELF fake")
        self.assertEqual(stat.S_IMODE(steam.stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE((dest / "steamrtarm64/builddate.txt").stat().st_mode), 0o644)
        self.assertFalse((self.dir / "evil").exists())
        self.assertFalse((dest.parent / "evil").exists())

    def test_links(self):
        home = self.dir / "home"
        s = home / ".local/share/Steam"
        s.mkdir(parents=True)
        fsi.make_links(home, s)
        want = {"steam": s, "root": s, "sdk32": s / "linux32", "sdk64": s / "linux64",
                "sdkarm64": s / "linuxarm64", "bin32": s / "ubuntu12_32", "bin64": s / "ubuntu12_64"}
        for name, target in want.items():
            self.assertEqual(os.readlink(home / ".steam" / name), str(target), name)
        vr = json.loads((home / ".config/openvr/openvrpaths.vrpath").read_text())
        self.assertEqual(vr, {"config": [], "external_drivers": None, "jsonid": "vrpathreg",
                              "log": [], "runtime": [], "version": 1})
        fsi.make_links(home, s)  # idempotent

    def test_prefetch_fetches_only_missing_vz(self):
        a, b = b"aaaa", b"bbbbbb"
        m = {"version": "1", "a": vz_entry("a", a), "b": vz_entry("b", b)}
        pkg = self.dir / "package"
        pkg.mkdir()
        (pkg / m["a"]["zipvz"]).write_bytes(a)
        calls = []

        def fetch(name, out):
            calls.append(name)
            out.write_bytes(b)
        fsi.prefetch(m, pkg, fetch)
        self.assertEqual(calls, [m["b"]["zipvz"]])
        self.assertEqual((pkg / m["b"]["zipvz"]).read_bytes(), b)

    def test_truncated_package_is_refetched(self):
        a = b"aaaa"
        m = {"a": vz_entry("a", a)}
        pkg = self.dir / "package"
        pkg.mkdir()
        (pkg / m["a"]["zipvz"]).write_bytes(b"aa")
        calls = []

        def fetch(name, out):
            calls.append(name)
            out.write_bytes(a)
        fsi.prefetch(m, pkg, fetch)
        self.assertEqual(calls, [m["a"]["zipvz"]])
        self.assertEqual((pkg / m["a"]["zipvz"]).read_bytes(), a)

    def test_corrupt_download_raises(self):
        m = {"a": vz_entry("a", b"good")}
        pkg = self.dir / "package"
        pkg.mkdir()
        with self.assertRaises(fsi.InstallError):
            fsi.prefetch(m, pkg, lambda name, out: out.write_bytes(b"bad!"))
        self.assertFalse((pkg / m["a"]["zipvz"]).exists())

    def test_unreachable_cdn_raises(self):
        m = {"a": vz_entry("a", b"data")}
        pkg = self.dir / "package"
        pkg.mkdir()

        def fetch(name, out):
            raise OSError("network is unreachable")
        with self.assertRaises(fsi.InstallError):
            fsi.prefetch(m, pkg, fetch)

    def test_no_marker_means_not_installed(self):
        s = self.dir / "Steam"
        (s / "steamrtarm64").mkdir(parents=True)
        (s / "steamrtarm64/steam").write_bytes(b"x")
        self.assertFalse(fsi.is_installed(s))
        (s / ".frogger-installed").touch()
        self.assertTrue(fsi.is_installed(s))

    def test_default_beta(self):
        self.assertEqual(fsi.DEFAULT_BETA, "linux_arm64_beta_861407927dc8efb407da7cf")
        self.assertEqual(fsi.CDN, "https://client-update.steamstatic.com/")


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
