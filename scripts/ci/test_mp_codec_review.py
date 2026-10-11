from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from lua_test_runtime import lua_executable, run_lua_fixture  # noqa: E402


class MPCodecCompatibilityReviewTests(unittest.TestCase):
    def test_legacy_save_capacity_and_diagnostics_cannot_regress(self) -> None:
        result = run_lua_fixture("scripts/ci/fixtures/codec_review.lua")
        self.assertIn("PASS: codec legacy capacity", result.stdout)

    def test_real_comma_numeric_locale_round_trip(self) -> None:
        # Generate a private locale when its source is available. LOCPATH is
        # scoped to this child only; system locale configuration is untouched.
        with tempfile.TemporaryDirectory(prefix="mk1212-numeric-locale-") as directory:
            env = os.environ.copy()
            localedef = shutil.which("localedef")
            if localedef and Path("/usr/share/i18n/locales/pl_PL").is_file():
                generated = subprocess.run(
                    [localedef, "--no-archive", "-i", "pl_PL", "-f", "UTF-8",
                     str(Path(directory) / "pl_PL.UTF-8")],
                    capture_output=True, text=True, timeout=60,
                )
                if generated.returncode == 0:
                    env["LOCPATH"] = directory
                    env["MK1212_TEST_NUMERIC_LOCALE"] = "pl_PL.UTF-8"
            result = subprocess.run(
                [str(lua_executable()), "scripts/ci/fixtures/codec_numeric_locale.lua"],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=30,
            )
            if result.returncode == 77:
                if env.get("MK1212_REQUIRE_NUMERIC_LOCALE") == "1":
                    self.fail(
                        "MK1212_REQUIRE_NUMERIC_LOCALE=1 requires the real comma-locale "
                        "regression to execute. Install a pl_PL/de_DE/fr_FR UTF-8 locale "
                        "or provide localedef with the pl_PL and UTF-8 locale sources. "
                        + result.stdout.strip()
                    )
                self.skipTest(result.stdout.strip())
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: real comma numeric locale", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
