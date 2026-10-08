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

    def test_trace_schema_and_line_safety(self):
        source = (ROOT / 'campaigns/main_attila/common/main.lua').read_text()
        instrumented = probe.instrument(source, 'b' * 40)
        self.assertIn('schema=2 source_sha=', instrumented)
        self.assertIn('gsub("%c", "?")', instrumented)
        self.assertIn('string.sub(tostring(message), 1, 512)', instrumented)
        self.assertNotIn('schema=1 source_sha=', instrumented)

    def test_lua_native_parity_is_observability_only_and_fail_closed(self):
        runtime = (ROOT / 'campaigns/main_attila/common/mkmp_runtime.lua').read_text(encoding='utf-8')
        harness = (ROOT / 'scripts/runtime/RUN-MK1212-PR45-SP-TEST.ps1').read_text(encoding='utf-8')
        self.assertIn('function MKMP_Runtime_Diagnostic_Campaign_Count()', runtime)
        self.assertIn('function MKMP_Runtime_Diagnostic_Parity()', runtime)
        self.assertIn('pcall(module.world.GetFactionCount)', runtime)
        self.assertIn('pcall(function()', runtime)
        self.assertIn('parity = "not_comparable"', runtime)
        self.assertIn('native_state = "native_unavailable"', runtime)
        self.assertIn('lua_count == native_count', runtime)
        self.assertIn('faction_parity phase=', harness)
        self.assertLess(harness.index('faction_parity phase='), harness.index('local runtime = MKMP_RUNTIME;'))
        self.assertIn('probe_world_samples >= 5', harness)
        self.assertNotIn('MKMP_Runtime_Diagnostic_Parity() ==', harness)

    def test_workshop_early_native_loader_is_bounded_and_fail_soft(self):
        harness = (ROOT / 'scripts/runtime/RUN-MK1212-PR45-SP-TEST.ps1').read_text(encoding='utf-8')
        prefix = harness.split("$Prefix = @'", 1)[1].split("'@\n$Suffix", 1)[0]
        suffix = harness.split("$Suffix = @'", 1)[1].split("'@\n$OverlayCommon", 1)[0]
        self.assertIn('Probe_Trace("bootstrap_enter")', prefix)
        self.assertIn('early_native_begin', prefix)
        self.assertIn('pcall(function()', prefix)
        self.assertIn('MKMP_Runtime_Initialize();', prefix)
        self.assertLess(prefix.index('early_native_begin'), prefix.index('MKMP_Runtime_Initialize();'))
        self.assertIn('MKMP_Debug_Initialize();', suffix)
        self.assertIn('early_bootstrap_status', suffix)
        self.assertIn('Probe_World("initializer")', suffix)
        self.assertNotIn('require("common/mkmp_debug")', prefix)
        self.assertEqual(harness.count('if (-not $Result.pass) { exit 1 }'), 1)

    def test_instrumentation_precedes_first_dependency(self):
        source = (ROOT / 'campaigns/main_attila/common/main.lua').read_text()
        result = probe.instrument(source, 'a' * 40)
        self.assertLess(result.index('Probe_Trace("bootstrap_enter")'), result.index('Probe_Require("common/mk1212_common")'))
        self.assertIn('error(result, 0)', result)
        self.assertIn('size + string.len(line) <= 65536', result)
        self.assertIn('probe_lines >= 128', result)


if __name__ == '__main__':
    unittest.main()
