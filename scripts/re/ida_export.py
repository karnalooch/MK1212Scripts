"""Optional IDAPython exporter for a licensed, user-installed IDA instance.

Execute from IDA's File > Script file; the output path is requested interactively.
Or supply the output as first script argument in a supported IDA batch invocation.
"""
import hashlib
import json
import os
import re

import ida_funcs
import ida_kernwin
import ida_nalt
import idautils
import idc

TERMS = re.compile(
    r"diplom|treaty|pay(?:ment)?|treasur|negotiat|proposal|offer|multiplayer|"
    r"net.?work|net.?packet|command.?queue|dispatch|serializ|dilemma|incident|turn.?start",
    re.IGNORECASE,
)
MAX_RESULTS = 300
MAX_NAMES = 250000
MAX_STRINGS = 250000
MAX_REFS = 5

def main():
    source = ida_nalt.get_input_file_path()
    if not source or not os.path.isfile(source):
        raise RuntimeError("IDA's original input binary is unavailable; cannot establish identity.")
    with open(source, "rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1048576), b""):
            digest.update(chunk)
        digest = digest.hexdigest()

    args = list(getattr(idc, "ARGV", []))
    target = args[1] if len(args) > 1 else ida_kernwin.ask_file(True, "*.json", "Export MK1212 static leads")
    if not target:
        raise RuntimeError("No output path selected.")
    if os.path.exists(target):
        raise RuntimeError("Output already exists; preserving previous evidence.")
    if not os.path.isdir(os.path.dirname(os.path.abspath(target))):
        raise RuntimeError("Output directory does not exist.")

    findings = {}
    truncated = False
    def add(kind, address, reference="", function="", excerpt=""):
        nonlocal truncated
        if len(findings) >= MAX_RESULTS:
            truncated = True
            return
        row = {
            "kind": kind,
            "address": "0x%x" % int(address),
            "reference": ("0x%x" % int(reference)) if reference != "" else "",
            "function": str(function)[:160],
            "excerpt": str(excerpt).replace("\n", " ").replace("\r", " ")[:160],
        }
        key = (row["kind"], row["address"], row["reference"], row["function"])
        findings[key] = row

    names_scanned = 0
    for ea, name in idautils.Names():
        names_scanned += 1
        if names_scanned > MAX_NAMES:
            truncated = True
            break
        if TERMS.search(name):
            add("named_function", ea, function=name)

    strings_scanned = 0
    for item in idautils.Strings():
        strings_scanned += 1
        if strings_scanned > MAX_STRINGS:
            truncated = True
            break
        value = str(item)
        if not TERMS.search(value):
            continue
        add("matched_string", item.ea, excerpt=value)
        references = []
        for ref in idautils.DataRefsTo(item.ea):
            if len(references) > MAX_REFS:
                truncated = True
                break
            references.append(ref)
        for ref in references[:MAX_REFS]:
            owner = ida_funcs.get_func(ref)
            owner_name = idc.get_func_name(owner.start_ea) if owner else ""
            add("string_xref", item.ea, reference=ref, function=owner_name, excerpt=value)

    output = {
        "schema_version": 1,
        "tool": "ida",
        "binary_sha256": digest,
        "program": os.path.basename(source),
        "status": "STATIC_CANDIDATE_ONLY",
        "truncated": truncated,
        "scanned_functions": names_scanned,
        "scanned_strings": strings_scanned,
        "findings": [findings[key] for key in sorted(findings)],
    }
    encoded = (json.dumps(output, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    if len(encoded) > 1048576:
        raise RuntimeError("Report unexpectedly exceeds 1 MiB.")
    with open(target, "xb") as stream:
        stream.write(encoded)
    print("MK1212 IDA static leads: %d; file: %s" % (len(findings), target))

if __name__ == "__main__":
    main()
