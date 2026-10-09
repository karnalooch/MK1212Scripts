# NSIS installer runtime

The Windows installer uses the unmodified Unicode installer runtime and bundled
nsDialogs/nsExec plug-ins from **NSIS 3.13**, released 27 September 2026.

- Project and release: https://nsis.sourceforge.io/Download
- Source mirror maintained by the project: https://github.com/NSIS-Dev/nsis
- License: the complete original `COPYING` notice is retained as `LICENSE.txt`.
- The compiler is a build dependency; it is not installed on the user's machine.
- `third_party/nsis/lock.json` in the source repository pins the complete
  original ZIP and matching source archive by byte count and SHA-256.
- `scripts/installer/goldberg_lab.nsi` is the repository-owned wizard source.

Windows CI compiles with `makensis.exe` from the verified original ZIP. A Linux
build may compile the same native compiler from the pinned source archive and
use the original ZIP's unchanged Windows runtime and plug-ins. The upstream
`INSTALL` file documents this cross-platform compiler-only configuration:

```sh
python -m SCons -j2 SKIPSTUBS=all SKIPPLUGINS=all SKIPUTILS=all SKIPMISC=all \
  NSIS_CONFIG_CONST_DATA_PATH=no VERSION=3.13 VER_PACKED=0x03013000 \
  SOURCE_DATE_EPOCH=1790467200 PREFIX=/path/to/nsis-3.13 install-compiler
```

The generated installer records the exact MK1212Scripts source SHA. Successful
compilation or an installer fixture test is not proof of an ATTILA lobby or
campaign. Game assets and Workshop content are copied only from paths selected
on the user's computer; they are not bundled in this installer.
