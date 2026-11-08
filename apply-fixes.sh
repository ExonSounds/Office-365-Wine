#!/bin/bash
# Apply the Wine workarounds for Microsoft 365 to this prefix (PREFIX/wine-office-fixes/..).
# install.sh runs it before and after Office's installer; run it again after an Office update or
# whenever something stops working. Safe to run repeatedly; steps that need the installed Office
# files are skipped until they exist. The shims come from github.com/Tombert/office365_flake
# (LGPL-2.1); sources and the built DLLs are in shim/. README.md explains each fix.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/env.sh"
WINELIB="$GE_PROTON/lib/wine"
DRIVE_C="$WINEPREFIX/drive_c"
SYS32="$DRIVE_C/windows/system32"
SYSWOW64="$DRIVE_C/windows/syswow64"
OFFICE16="$DRIVE_C/Program Files/Microsoft Office/root/Office16"
[ -x "$GE_PROTON/bin/wine" ] || { echo "apply-fixes.sh: $GE_VERSION is missing in $WINEPREFIX/runner (run install.sh)" >&2; exit 1; }
[ -f "$WINEPREFIX/system.reg" ] || { echo "apply-fixes.sh: $WINEPREFIX is not a Wine prefix yet (run install.sh)" >&2; exit 1; }

winpath() { local p; p="$(readlink -f "$1")"; printf 'Z:%s' "${p//\//\\}"; }  # GE-Proton has no winepath

# Never let this run's Wine sessions write Linux menu entries for Windows programs.
export WINEDLLOVERRIDES="winemenubuilder.exe=d"
# Update the prefix to GE-Proton's Wine first: an update puts Wine's own DLLs back over the shims
# below. GE-Proton has no wineboot command (a bare "wineboot" would be the system Wine's, which
# marks the prefix as out of date for GE-Proton), so run its wineboot.exe through wine.
wineserver -k 2>/dev/null || true
wine wineboot -u >/dev/null 2>&1 || true
wineserver -w

# Copy a Wine builtin under another name with its "Wine builtin DLL" marker blanked, so Wine
# loads the file itself as a native DLL.
as_native() {
    python3 -I -c '
import sys
d = bytearray(open(sys.argv[1], "rb").read())
i = d.find(b"Wine builtin DLL")
assert 0 < i < 0x100, "no builtin marker"
d[i:i + 16] = b"\0" * 16
open(sys.argv[2], "wb").write(d)' "$1" "$2"
}

# ole32 forwarder shim (+ the same DLL as ms365shim.dll for AppInit_DLLs); the real ole32 becomes
# ole32_wine.dll. shim/ole32.def matches GE-Proton11-7's ole32 exports (see shim/BUILD.txt).
as_native "$WINELIB/x86_64-windows/ole32.dll" "$SYS32/ole32_wine.dll"
cp "$OFFICE_FIXES/shim/ole32.dll" "$SYS32/ole32.dll"
cp "$OFFICE_FIXES/shim/ole32.dll" "$SYS32/ms365shim.dll"
cp "$OFFICE_FIXES/shim/ms365uia.dll" "$SYS32/ms365uia.dll"
cp "$OFFICE_FIXES/shim/sppc.dll" "$SYS32/sppc.dll"

# Direct2D from Wine 11.16: GE-Proton 11's d2d1 ignores geometry-group fill modes (ribbon controls
# become solid blocks).
cp "$OFFICE_FIXES/d2d1-wine11.16.dll" "$SYS32/d2d1.dll"

# GE-Proton's own DXVK (matches its Wine's shared-resource / keyed-mutex support)
for d in d3d8 d3d9 d3d10core d3d11 dxgi; do
    cp "$WINELIB/dxvk/x86_64-windows/$d.dll" "$SYS32/$d.dll"
    cp "$WINELIB/dxvk/i386-windows/$d.dll" "$SYSWOW64/$d.dll"
done

# vkd3d runtime DLLs GE's wined3d imports (Proton's launcher normally copies these into the prefix)
cp "$GE_PROTON"/lib/vkd3d/x86_64-windows/*.dll "$SYS32/"
cp "$GE_PROTON"/lib/vkd3d/i386-windows/*.dll "$SYSWOW64/"

# Office keeps most DLLs under root/vfs/<KnownFolder> and relies on App-V to redirect the real
# paths there, which is unreliable under Wine; mirror the tree into place (only where nothing exists).
link_tree() { # link_tree <src dir> <dst dir>
    local src="$1" dst="$2" e name
    [ -d "$src" ] || return 0
    mkdir -p "$dst"
    for e in "$src"/*; do
        [ -e "$e" ] || continue
        name="${e##*/}"
        if [ ! -e "$dst/$name" ]; then
            ln -s "$e" "$dst/$name"
        elif [ -d "$e" ] && [ -d "$dst/$name" ] && [ ! -L "$dst/$name" ]; then
            link_tree "$e" "$dst/$name"
        fi
    done
}
VFS="$DRIVE_C/Program Files/Microsoft Office/root/vfs"
link_tree "$VFS/ProgramFilesCommonX64" "$DRIVE_C/Program Files/Common Files"
link_tree "$VFS/ProgramFilesCommonX86" "$DRIVE_C/Program Files (x86)/Common Files"
link_tree "$VFS/ProgramFilesX64" "$DRIVE_C/Program Files"
link_tree "$VFS/ProgramFilesX86" "$DRIVE_C/Program Files (x86)"
link_tree "$VFS/Fonts" "$DRIVE_C/windows/Fonts"

# Selawik as the Segoe UI stand-in, and Wine's Tahoma (the system message font) where DirectWrite
# finds it; both are registered in office-wine.reg
cp "$OFFICE_FIXES"/fonts/selawk*.ttf "$DRIVE_C/windows/Fonts/"
cp "$GE_PROTON"/share/wine/fonts/tahoma.ttf "$GE_PROTON"/share/wine/fonts/tahomabd.ttf "$DRIVE_C/windows/Fonts/"

# Microsoft's VC++ runtime (winetricks vcrun2022) must be the one in use: with Wine's builtin
# vcruntime140/msvcp140 Office aborts (__C_specific_handler_noexcept). Office's own redist installer
# leaves Wine's copies in place, as they report a newer version; then extract Microsoft's DLLs from
# the redist packages winetricks downloaded.
vcrt_builtin() {
    local f
    for f in "$SYS32"/{vcruntime140,vcruntime140_1,msvcp140,msvcp140_1,msvcp140_2,concrt140}.dll \
             "$SYSWOW64"/{vcruntime140,msvcp140,msvcp140_1,concrt140}.dll; do
        if [ ! -f "$f" ] || grep -qa 'Wine builtin DLL' "$f"; then return 0; fi
    done
    return 1
}
extract_vcrt() { # extract_vcrt <x64|x86> <file suffix in the cabinets> <dest dir>
    local exe="$VCRT_CACHE/vc_redist.$1.exe" t f b
    [ -f "$exe" ] || { echo "warning: $exe missing; Wine's builtin VC++ runtime stays active (fix: winetricks -q -f vcrun2022, then run this again)" >&2; return 0; }
    t="$(mktemp -d)"
    mkdir -p "$t/outer" "$t/dll"
    cabextract -q -d "$t/outer" "$exe" 2>/dev/null || true
    for f in "$t/outer"/*; do cabextract -q -d "$t/dll" "$f" 2>/dev/null || true; done
    for f in "$t/dll"/*_"$2"; do
        [ -e "$f" ] || continue
        b="$(basename "$f" "_$2")"
        case "$b" in vc*.dll|msvcp*.dll|concrt*.dll) cp -f "$f" "$3/$b" ;; esac
    done
    rm -rf "$t"
}
VCRT_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/winetricks/vcrun2022"
if vcrt_builtin; then
    extract_vcrt x64 amd64 "$SYS32"
    extract_vcrt x86 x86 "$SYSWOW64"
fi

wine regedit /S "$(winpath "$OFFICE_FIXES/office-wine.reg")"

# Token ("vNext") licensing for each installed product (ProductReleaseIds, e.g. O365ProPlusRetail,
# O365HomePremRetail, O365EduCloudRetail), read from the registry file wineserver has just written.
products="$(awk '/^\[Software\\\\Microsoft\\\\Office\\\\ClickToRun\\\\Configuration\]/ { f = 1; next }
                 /^\[/ { f = 0 }
                 f && /^"ProductReleaseIds"="/ { sub(/^"ProductReleaseIds"="/, ""); sub(/".*$/, ""); print }' \
            "$WINEPREFIX/system.reg")"
if [ -n "$products" ]; then
    lic="$DRIVE_C/windows/temp/office-licensing.reg"
    {
        printf 'Windows Registry Editor Version 5.00\n\n'
        printf '[HKEY_CURRENT_USER\\Software\\Microsoft\\Office\\16.0\\Common\\Licensing\\LicensingNext]\n'
        for p in ${products//,/ }; do
            case "$p" in *[!A-Za-z0-9_.]*) continue ;; esac
            printf '"%s"=dword:00000002\n' "$p"
        done
    } >"$lic"
    wine regedit /S 'C:\windows\temp\office-licensing.reg'
    rm -f "$lic"
fi

if [ -d "$OFFICE16" ]; then
    # MSI component registrations the integrator never writes under Wine (proofing tools, VBA, add-ins)
    python3 -I "$OFFICE_FIXES/msi-components.py" "$DRIVE_C" "$OFFICE_FIXES/msi-components.reg" &&
        wine regedit /S "$(winpath "$OFFICE_FIXES/msi-components.reg")"
    # VBA UserForms: FM20's designer class is otherwise only in the App-V virtual registry
    wine regsvr32 /s 'C:\Program Files\Microsoft Office\root\vfs\System\FM20.DLL' >/dev/null 2>&1 || true
fi

# Office resets this lock file's ACL; Wine maps that to Unix mode 000 and the next start fails
# ("access denied", Click-to-Run error 5). The office launcher does the same before every start.
locker="$DRIVE_C/ProgramData/Microsoft/Office/ClickToRunPackageLocker"
[ -e "$locker" ] && chmod 644 "$locker"

# WebView2's updater service, if the Evergreen runtime was installed: manual start, as winetricks
# does (Wine bug 53925)
if wine reg query 'HKLM\System\CurrentControlSet\Services\edgeupdate' >/dev/null 2>&1; then
    wine reg add 'HKLM\System\CurrentControlSet\Services\edgeupdate' /v Start /t REG_DWORD /d 3 /f >/dev/null
fi
wine reg delete 'HKCU\Software\Microsoft\Office\16.0\Word\Resiliency' /f >/dev/null 2>&1 || true
wineserver -w
echo "fixes applied to $WINEPREFIX"
