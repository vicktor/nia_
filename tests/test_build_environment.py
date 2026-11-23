#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Exercise the real macOS build preflight in an isolated, tool-stubbed tree.

The CMake stub stops before compilation; this does not claim to build macOS.
Run with: python3 -m unittest discover -s tests -p 'test_build_environment.py'
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "scripts/build-native-macos.sh"


class BuildEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nia-build-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home with spaces"
        self.tools = self.root / "tools"
        self.home.mkdir()
        self.tools.mkdir()
        (self.root / "scripts").mkdir()
        (self.root / ".build/llama.cpp/.git").mkdir(parents=True)
        self.script = self.root / "scripts/build-native-macos.sh"
        shutil.copyfile(SOURCE, self.script)
        for name in ("dirname", "rm"):
            (self.tools / name).symlink_to(shutil.which(name))
        self.stub("uname", "printf 'Darwin\\n'")
        self.stub("swiftc", "exit 0")
        self.stub("git", "exit 90")
        self.stub("cmake", "command -v cargo\nexit 73")
        self.env = {"HOME": str(self.home), "PATH": str(self.tools)}

    def stub(self, name, body, directory=None):
        path = (directory or self.tools) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o700)
        return path

    def run_preflight(self):
        return subprocess.run(
            [shutil.which("bash"), str(self.script)],
            env=self.env, capture_output=True, text=True, timeout=10,
        )

    def assert_resolved_cargo(self, result, expected):
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(result.stdout.strip(), str(expected))

    def test_uses_existing_rustup_when_not_on_gui_path(self):
        cargo = self.stub("cargo", "exit 0", self.home / ".cargo/bin")
        self.assert_resolved_cargo(self.run_preflight(), cargo)

    def test_honors_custom_cargo_home(self):
        cargo_home = self.home / "Rust tools"
        self.env["CARGO_HOME"] = str(cargo_home)
        cargo = self.stub("cargo", "exit 0", cargo_home / "bin")
        self.assert_resolved_cargo(self.run_preflight(), cargo)

    def test_preserves_cargo_already_selected_in_path(self):
        selected = self.stub("cargo", "exit 0")
        self.stub("cargo", "exit 0", self.home / ".cargo/bin")
        self.assert_resolved_cargo(self.run_preflight(), selected)

    def test_missing_cargo_reports_lookup_failure(self):
        result = self.run_preflight()
        self.assertEqual(result.returncode, 1)
        self.assertIn("No se encuentra cargo en PATH", result.stderr)
        self.assertIn("Si Rust ya está instalado", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_custom_cargo_home_does_not_silently_use_default_install(self):
        self.stub("cargo", "exit 0", self.home / ".cargo/bin")
        self.env["CARGO_HOME"] = str(self.home / "chosen-but-missing")
        result = self.run_preflight()
        self.assertEqual(result.returncode, 1)
        self.assertIn(self.env["CARGO_HOME"] + "/bin", result.stderr)


if __name__ == "__main__":
    unittest.main()
