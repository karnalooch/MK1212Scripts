from __future__ import annotations
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('probe_builder', ROOT / 'scripts/runtime/build_product_probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProductProbeTests(unittest.TestCase):
    def test_real_bootstrap_closure_contains_debug_and_nested_ui(self):
        files = {p.as_posix() for p in probe.dependencies(ROOT / 'campaigns/main_attila')}
        self.assertIn('common/mkmp_debug.lua', files)
        self.assertIn('common/mkmp_runtime.lua', files)
        self.assertIn('common/ui/mk1212_unit_information_lists.lua', files)
        self.assertIn('common/ui/mk1212_global_ui_lists.lua', files)
        self.assertIn('common/ui/mk1212_occupation_decisions.lua', files)
        self.assertEqual(len(files), 14)

    def test_missing_transitive_dependency_fails_before_packaging(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'common').mkdir()
            (root / 'common/main.lua').write_text('require("common/child");')
            (root / 'common/child.lua').write_text('require("common/missing");')
            with self.assertRaisesRegex(ValueError, 'common/missing'):
                probe.dependencies(root)

    def test_require_cycles_are_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'common').mkdir()
            (root / 'common/main.lua').write_text('require("common/child");')
            (root / 'common/child.lua').write_text('require("common/main");')
            self.assertEqual(len(probe.dependencies(root)), 2)

    def test_instrumentation_precedes_first_dependency(self):
        source = (ROOT / 'campaigns/main_attila/common/main.lua').read_text()
        result = probe.instrument(source, 'a' * 40)
        self.assertLess(result.index('Probe_Trace("bootstrap_enter")'), result.index('Probe_Require("common/mk1212_common")'))
        self.assertIn('error(result, 0)', result)
        self.assertIn('size < 65536', result)
        self.assertIn('probe_lines >= 128', result)


if __name__ == '__main__':
    unittest.main()
