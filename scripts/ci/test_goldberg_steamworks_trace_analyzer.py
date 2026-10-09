#!/usr/bin/env python3
import importlib.util
import tempfile
from pathlib import Path
import unittest

SOURCE=Path(__file__).resolve().parents[1]/"diagnostics/analyze_goldberg_steamworks_trace.py"
spec=importlib.util.spec_from_file_location("trace_analyzer",SOURCE)
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class GoldbergTraceAnalyzerTest(unittest.TestCase):
    def test_unavailable_is_not_turned_into_no_calls(self):
        a=mod.read_trace(Path("/missing/mk1212-goldberg-host.log"))
        self.assertEqual(a["status"],"NOT_PROVIDED")
        self.assertIn("INCOMPLETE",mod.diagnose(a,a))
    def test_callbacks_and_absence(self):
        with tempfile.TemporaryDirectory() as d:
            host=Path(d)/"host.log";client=Path(d)/"client.log"
            host.write_text("1790000000|124|CreateLobby.call|type=2 members=2\n"
                            "1790000001|124|CreateLobby.return|call=1\n"
                            "1790000002|124|LobbyCreated.callback|result=ok call=1 lobby=5\n",encoding="utf8")
            client.write_text("1790000000|125|RequestLobbyList.call|begin=1\n"
                              "1790000001|125|LobbyMatchList.callback|call=3 matches=0\n",encoding="utf8")
            h=mod.read_trace(host);c=mod.read_trace(client)
            self.assertEqual(h["counts"]["CreateLobby.call"],1)
            self.assertIn("0 matches",mod.diagnose(h,c))
    def test_refuse_oversize(self):
        with tempfile.TemporaryDirectory() as d:
            f=Path(d)/"log"
            f.write_bytes(b"x"*(mod.MAX_BYTES+1))
            self.assertEqual(mod.read_trace(f)["status"],"OVERSIZE_REFUSED")
            self.assertIn("INCOMPLETE",mod.diagnose(mod.read_trace(f),mod.read_trace(f)))

if __name__=="__main__":
    unittest.main()
