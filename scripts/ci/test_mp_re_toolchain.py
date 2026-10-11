"""Small, offline contracts for the optional static RE tools. No Ghidra download."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "re"))
import validate_leads  # noqa: E402

class ResearchToolchainContract(unittest.TestCase):
    def test_official_archives_are_pinned_and_never_runtime_dependencies(self):
        manifest = json.loads((ROOT / "scripts/re/toolchain.lock.json").read_text())
        self.assertEqual(1, manifest["schema_version"])
        self.assertEqual("local-static-analysis-only", manifest["purpose"])
        self.assertTrue(manifest["ghidra"]["url"].startswith(
            "https://github.com/NationalSecurityAgency/ghidra/releases/download/"))
        self.assertTrue(manifest["jdk"]["url"].startswith(
            "https://github.com/adoptium/temurin25-binaries/releases/download/"))
        for package in (manifest["ghidra"], manifest["jdk"]):
            self.assertEqual(64, len(package["sha256"]))
            int(package["sha256"], 16)
            self.assertTrue(package["archive"].endswith(".zip"))
            self.assertTrue(package["license"])

    def make_evidence(self, root: Path):
        binary = root / "original.dll"
        content = bytearray(256)
        content[:2] = b"MZ"
        content[0x3C:0x40] = (128).to_bytes(4, "little")
        content[128:132] = b"PE\x00\x00"
        content[132:134] = (0x14C).to_bytes(2, "little")
        binary.write_bytes(content)
        evidence = {
            "schema_version": 1, "tool": "ghidra",
            "binary_sha256": hashlib.sha256(content).hexdigest(),
            "status": "STATIC_CANDIDATE_ONLY",
            "truncated": False, "findings": [
                {"kind": "string_xref", "address": "0012ab34",
                 "reference": "0012ab56", "function": "FUN_0012ab00",
                 "excerpt": "diplomacy_smallest_payment"}
            ],
        }
        path = root / "evidence.json"
        path.write_text(json.dumps(evidence), encoding="utf-8")
        return binary, evidence, path

    def test_valid_evidence_creates_explicitly_unproven_report(self):
        with tempfile.TemporaryDirectory() as folder:
            binary, _, path = self.make_evidence(Path(folder))
            payload = validate_leads.validate(path, binary)
            report = validate_leads.markdown_report(payload, binary.name, "a" * 40)
            self.assertIn("STATIC_CANDIDATE_ONLY", report)
            self.assertIn("not", report.lower())
            self.assertIn("diplomacy_smallest_payment", report)

    def test_wrong_binary_sha_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            binary, _, path = self.make_evidence(Path(folder))
            with binary.open("ab") as handle:
                handle.write(b"changed")
            with self.assertRaisesRegex(validate_leads.InvalidResearchEvidence, "does not match"):
                validate_leads.validate(path, binary)

    def test_claims_of_runtime_proof_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            binary, evidence, path = self.make_evidence(Path(folder))
            evidence["status"] = "RUNTIME_PROVEN"
            path.write_text(json.dumps(evidence), encoding="utf-8")
            with self.assertRaisesRegex(validate_leads.InvalidResearchEvidence, "claim runtime proof"):
                validate_leads.validate(path, binary)

    def test_overflow_and_invalid_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            binary, evidence, path = self.make_evidence(Path(folder))
            evidence["findings"] *= 301
            path.write_text(json.dumps(evidence), encoding="utf-8")
            with self.assertRaisesRegex(validate_leads.InvalidResearchEvidence, "bounded"):
                validate_leads.validate(path, binary)
            evidence["findings"] = []
            evidence["truncated"] = None
            path.write_text(json.dumps(evidence), encoding="utf-8")
            with self.assertRaisesRegex(validate_leads.InvalidResearchEvidence, "truncation"):
                validate_leads.validate(path, binary)

if __name__ == "__main__":
    unittest.main()
