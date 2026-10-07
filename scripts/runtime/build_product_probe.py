"""Build a source-pinned SP probe; never include Workshop/game assets."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
REQUIRE = re.compile(r'\brequire\s*\(\s*["\']([^"\']+)["\']\s*\)')


def dependencies(root: Path, entry: str = 'common/main') -> list[Path]:
    """Include the complete static require closure, including SP-only branches."""
    seen: set[str] = set()
    def visit(module: str) -> None:
        if module in seen:
            return
        if not re.fullmatch(r'[A-Za-z0-9_/-]+', module) or '..' in module:
            raise ValueError(f'Invalid module path: {module}')
        seen.add(module)
        path = root / (module + '.lua')
        if not path.is_file():
            raise ValueError(f'Missing bootstrap dependency: {module}')
        source = path.read_text(encoding='utf-8-sig')
        for child in REQUIRE.findall(source):
            visit(child)
    visit(entry)
    return [Path(name + '.lua') for name in sorted(seen)]


def instrument(source: str, sha: str) -> str:
    # Diagnostic-only file access; no gameplay state or RNG changes.
    prefix = '''local probe_lines = 0;
local function Probe_Trace(message)
    if probe_lines >= 128 then return; end
    probe_lines = probe_lines + 1;
    pcall(function()
        if not io or not io.open then return; end
        local file = io.open("PR45_RUNTIME_TRACE.txt", "ab");
        if not file then return; end
        local size = file:seek("end");
        local line = "schema=1 source_sha=SHA "..string.sub(tostring(message), 1, 512).."\\n";
        if size and size + string.len(line) <= 65536 then
            file:write(line);
        end
        file:close();
    end);
end
Probe_Trace("bootstrap_enter");
local function Probe_Require(module)
    Probe_Trace("require_begin module="..module);
    local ok, result = pcall(require, module);
    if not ok then
        Probe_Trace("require_failed module="..module.." error="..tostring(result));
        error(result, 0);
    end
    Probe_Trace("require_ok module="..module);
    return result;
end
'''.replace('source_sha=SHA ', 'source_sha=' + sha + ' ')
    source = REQUIRE.sub(lambda m: 'Probe_Require("' + m.group(1) + '")', source)
    source = source.replace('function Common_Initializer()', 'function Common_Initializer()\n\tProbe_Trace("initializer_enter");', 1)
    source = source.replace('MKMP_Runtime_Initialize();', '''MKMP_Runtime_Initialize();
    local status = MKMP_Runtime_Status();
    Probe_Trace("runtime_status available="..tostring(status.available).." reason="..tostring(status.reason).." native_sha="..tostring(status.twdll_sha).." luaopen_calls="..tostring(status.luaopen_calls));''', 1)
    return prefix + source


def build(output: Path, dll: Path, rpfm: Path, root: Path = ROOT) -> Path:
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    # Never label an uncommitted payload as exact-head proof.
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=root, text=True).strip():
        raise ValueError('Commit source changes before creating an exact-head probe')
    campaign = root / 'campaigns/main_attila'
    files = dependencies(campaign)
    subprocess.check_call(['git', 'ls-files', '--error-unmatch', *['campaigns/main_attila/' + p.as_posix() for p in files], 'scripts/runtime/build_product_probe.py', 'scripts/runtime/RUN-MK1212-PR45-SP-TEST.ps1', 'scripts/runtime/RUN-MK1212-PR45-SP-TEST.cmd'], cwd=root, stdout=subprocess.DEVNULL)
    for binary in (dll, rpfm):
        if not binary.is_file():
            raise ValueError(f'Missing binary: {binary}')
    # Builder consumes a native artifact from the same exact source commit.
    if sha.encode('ascii') not in dll.read_bytes():
        raise ValueError('DLL does not embed the exact source SHA')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp)
        payload = stage / 'payload/patch-src/campaigns/main_attila'
        records = []
        for relative in files:
            dest = payload / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            source = (campaign / relative).read_bytes()
            if relative.as_posix() == 'common/main.lua':
                source = instrument(source.decode('utf-8-sig'), sha).encode('utf-8')
            dest.write_bytes(source)
            records.append({'path': 'campaigns/main_attila/' + relative.as_posix(), 'sha256': hashlib.sha256(source).hexdigest()})
        (stage / 'tools').mkdir()
        shutil.copy2(dll, stage / 'payload/twdll.dll')
        shutil.copy2(rpfm, stage / 'tools/rpfm_cli.exe')
        for name in ('RUN-MK1212-PR45-SP-TEST.ps1', 'RUN-MK1212-PR45-SP-TEST.cmd'):
            shutil.copy2(root / 'scripts/runtime' / name, stage / name)
        manifest = {'schema': 1, 'source_sha': sha, 'files': records,
                    'dll_sha256': hashlib.sha256(dll.read_bytes()).hexdigest(),
                    'rpfm_sha256': hashlib.sha256(rpfm.read_bytes()).hexdigest()}
        (stage / 'payload-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        result = output / f'MK1212-PR45-SP-PROBE-{sha}.zip'
        with zipfile.ZipFile(result, 'w', zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(stage.rglob('*')):
                if path.is_file():
                    archive.write(path, path.relative_to(stage))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--rpfm', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(build(args.output.resolve(), args.dll.resolve(), args.rpfm.resolve()))
