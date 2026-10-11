from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from lua_test_runtime import run_lua_fixture  # noqa: E402


class MPUIRandomnessTests(unittest.TestCase):
    def test_host_only_pope_ui_preserves_next_shared_random_draw(self) -> None:
        result = run_lua_fixture("scripts/ci/fixtures/mp_ui_rng.lua")
        self.assertIn("shared RNG untouched", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
