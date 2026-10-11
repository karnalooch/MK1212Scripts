#!/usr/bin/env python3
"""Offline, fail-closed validator for Ghidra/IDA candidate findings.

Reads only the named local binary to calculate SHA256; no game binaries or
decompilation output are uploaded or modified by this module.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path

HEX64 = re.compile(r"^[0-9a-f]{64}$")
KINDS = {"named_function", "matched_string", "string_xref"}
TOOLS = {"ghidra", "ida"}

class InvalidResearchEvidence(ValueError):
    pass

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def check_pe(path: Path) -> None:
    if not path.is_file() or path.suffix.lower() not in (".exe", ".dll"):
        raise InvalidResearchEvidence("An original .exe/.dll must be supplied.")
    with path.open("rb") as stream:
        head = stream.read(64)
        if len(head) < 64 or head[:2] != b"MZ":
            raise InvalidResearchEvidence("Original input is not an MZ/PE binary.")
        pe_offset = int.from_bytes(head[0x3C:0x40], "little")
        if pe_offset < 64 or pe_offset > path.stat().st_size - 6:
            raise InvalidResearchEvidence("Invalid PE header offset.")
        stream.seek(pe_offset)
        if stream.read(4) != b"PE\x00\x00":
            raise InvalidResearchEvidence("Missing PE signature.")
        if int.from_bytes(stream.read(2), "little") not in (0x14C, 0x8664):
            raise InvalidResearchEvidence("PE architecture is not x86/x64.")

def validate(source: Path, binary: Path) -> dict:
    if not source.is_file() or source.stat().st_size > 1048576:
        raise InvalidResearchEvidence("Missing or oversized JSON evidence.")
    check_pe(binary)
    try:
        payload = json.loads(source.read_text(encoding="utf-8-sig"))
    except (json.JSONDecodeError, UnicodeError) as exc:
        raise InvalidResearchEvidence("Invalid UTF-8 JSON.") from exc
    if not isinstance(payload, dict):
        raise InvalidResearchEvidence("Evidence must be a JSON object.")
    digest = payload.get("binary_sha256")
    if not isinstance(digest, str) or not HEX64.fullmatch(digest):
        raise InvalidResearchEvidence("Missing exact binary SHA256.")
    if digest != sha256_file(binary):
        raise InvalidResearchEvidence("Wrong binary: SHA256 does not match evidence.")
    if payload.get("schema_version") != 1 or payload.get("tool") not in TOOLS:
        raise InvalidResearchEvidence("Unknown RE evidence schema or tool.")
    if payload.get("status") != "STATIC_CANDIDATE_ONLY":
        raise InvalidResearchEvidence("Static leads must not claim runtime proof.")
    if type(payload.get("truncated")) is not bool:
        raise InvalidResearchEvidence("A true/false truncation flag is required.")
    findings = payload.get("findings")
    if not isinstance(findings, list) or len(findings) > 300:
        raise InvalidResearchEvidence("Findings must be a bounded list.")
    for index, finding in enumerate(findings):
        if not isinstance(finding, dict) or finding.get("kind") not in KINDS:
            raise InvalidResearchEvidence(f"Invalid finding at index {index}.")
        for field in ("address", "reference", "function", "excerpt"):
            value = finding.get(field)
            if not isinstance(value, str) or len(value) > 160:
                raise InvalidResearchEvidence(f"Invalid {field} field at index {index}.")
    return payload

def markdown_report(payload: dict, name: str, repo_sha: str) -> str:
    if not re.fullmatch(r"[a-f0-9]{40}", repo_sha):
        raise InvalidResearchEvidence("Expected exact 40-character MK1212 source commit.")
    rows = [
        "# MK1212 native static leads",
        "",
        "**Evidence status: STATIC_CANDIDATE_ONLY — NOT multiplayer/runtime proof.**",
        "",
        f"- MK1212 source SHA: {repo_sha}",
        f"- Binary filename: {name}",
        f"- Binary SHA256: {payload['binary_sha256']}",
        f"- Tool: {payload['tool']}",
        f"- Findings: {len(payload['findings'])}",
        f"- Truncated/incomplete: {payload['truncated']}",
        "",
        "| Kind | Address (binary-local) | Referrer | Function | String fragment |",
        "|---|---|---|---|---|",
    ]
    def cell(text: str) -> str:
        return text.replace("|", "\\|").replace("\r", " ").replace("\n", " ")[:160]
    for entry in payload["findings"]:
        rows.append("| " + " | ".join(cell(entry[key]) for key in (
            "kind", "address", "reference", "function", "excerpt")) + " |")
    rows += [
        "",
        "Addresses belong ONLY to the hashed original binary; never transplant them across builds.",
        "No identified function or packet ID is confirmed until an exact-build, both-peer runtime experiment.",
        "Review game-owned strings and provenance before sharing any report.",
        "",
    ]
    return "\n".join(rows)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--repo-sha", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    evidence = validate(args.input, args.binary)
    report = markdown_report(evidence, args.binary.name, args.repo_sha)
    if args.output.exists():
        parser.error("Output exists; choose a new file instead of overwriting prior evidence.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8", newline="\n") as handle:
        handle.write(report)
    print(f"STATIC_CANDIDATE_ONLY: {args.output}")

if __name__ == "__main__":
    main()
