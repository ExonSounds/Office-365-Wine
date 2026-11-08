#!/bin/bash
# Rebuild the shim DLLs in this folder from source with a Windows cross-compiler, e.g. llvm-mingw
# (github.com/mstorsjo/llvm-mingw; the prebuilt DLLs were built with its 20261020 release).
#
#   build.sh                 build ole32.dll, ms365uia.dll and sppc.dll
#   build.sh --def RUNNER    first regenerate ole32.def from the ole32.dll of a GE-Proton folder
#                            (e.g. PREFIX/runner/GE-Proton11-7-x86_64); needed for another Wine
#                            version. Uses winedump (part of Wine).
#
# CC selects the compiler (default x86_64-w64-mingw32-clang).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
CC="${CC:-x86_64-w64-mingw32-clang}"

if [ "${1:-}" = --def ]; then
    [ $# -ge 2 ] || { echo "usage: build.sh --def GE-PROTON-DIR" >&2; exit 2; }
    ole32="$2/files/lib/wine/x86_64-windows/ole32.dll"
    [ -f "$ole32" ] || { echo "build.sh: $ole32 not found" >&2; exit 1; }
    # Every export of Wine's ole32 is forwarded: to the DLL Wine itself forwards it to, else to the
    # real ole32 (installed as ole32_wine.dll). CoRegisterActivationFilter is implemented in shim.c.
    winedump -j export "$ole32" | awk '
        BEGIN { print "LIBRARY ole32.dll"; print "EXPORTS" }
        /^  [0-9A-F]+ +[0-9]+ / {
            name = $3
            if (name == "CoRegisterActivationFilter") next
            if ($4 == "(->") { fw = $5; sub(/\)$/, "", fw); print "  " name " = " fw }
            else print "  " name " = ole32_wine." name
        }
        END { print "  CoRegisterActivationFilter" }' >ole32.def.new
    mv ole32.def.new ole32.def
    echo "ole32.def regenerated from $ole32"
fi

command -v "$CC" >/dev/null || { echo "build.sh: $CC not found (put llvm-mingw's bin/ on PATH, or set CC)" >&2; exit 1; }
"$CC" -shared -O2 -Wall -o ole32.dll shim.c ole32.def
"$CC" -shared -O2 -Wall -o ms365uia.dll uia.c -lole32 -luuid
"$CC" -shared -O2 -Wall -o sppc.dll sppc.c
echo "built ole32.dll ms365uia.dll sppc.dll"
