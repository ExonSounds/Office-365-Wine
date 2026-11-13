#!/usr/bin/env bash
# install.sh: installs Microsoft 365 (Click-to-Run Office: Word, Excel,
# PowerPoint, ...) into a Wine prefix that runs on GE-Proton, starting from
# nothing.
#
#   ./install.sh [options] [OfficeSetup.exe]
#
#   OfficeSetup.exe  Office's installer as downloaded from your Microsoft account
#                    (office.com -> Install apps). May be left out to repair an
#                    existing install.
#   --prefix DIR     Wine prefix to create or use (default: ~/.office_365). The
#                    path must not contain spaces or quotes.
#   --no-desktop     don't add the Word, Excel and PowerPoint menu entries
#                    (also their "Open with" entries for Office documents)
#   --powershell     also install PowerShell 7 into the prefix (winetricks
#                    powershell); start it with PREFIX/wine-office-fixes/powershell
#   --reinstall      run Office's installer even if Office is already installed
#   --clean-cache    afterwards delete the downloaded GE-Proton and WebView2
#                    archives (~950 MB) from ~/.cache/office-365-wine
#
# Needs: curl, tar, sha256sum, sha512sum, cabextract, python3, winetricks, a
# 32-bit FreeType library (Arch: lib32-freetype2), a Vulkan driver (Office
# draws through DXVK), a graphical session, internet access, ~15 GB free disk. Takes 25-90 minutes, mostly Office's own download.
# Safe to re-run: finished steps are skipped, so it also repairs an install.
# Everything is logged to PREFIX/install-logs/.
#
# Steps:
#   1. GE-Proton11-7 (checksum-verified) into PREFIX/runner
#   2. this folder copied to PREFIX/wine-office-fixes; 64-bit prefix;
#      winetricks win10 corefonts msxml6 msxml3 vcrun2022
#   3. the Wine workarounds (apply-fixes.sh: office365_flake shims, DXVK,
#      Direct2D, fonts, registry settings)
#   4. the Microsoft Edge WebView2 runtime (Fixed Version 152, checksum-
#      verified) for Office's sign-in page
#   5. Office's installer, followed until Click-to-Run has finished
#   6. the workarounds that need Office's files (apply-fixes.sh again), menu
#      entries
#
# Licensing is left to Microsoft: on first start Office asks you to sign in
# with the account that has the Microsoft 365 subscription.

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd -P)"

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit "${1:-0}"; }

GE_VERSION="$(sed -n 's/^GE_VERSION=//p' "$HERE/env.sh")"
GE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$GE_VERSION/$GE_VERSION-x86_64.tar.gz"
GE_SHA512=7db87e9787e20c35cbdac26018431d5794626b626e4067b050684e45a88cc2ca229d7d263519eafb2e168cde5bef57611065d159d3685aaec152ccb9abe3073f
WV2_VERSION=152.0.4191.62
WV2_URL="https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/0a4a34d9-ccaa-4cef-98b4-58cb313fbfeb/Microsoft.WebView2.FixedVersionRuntime.$WV2_VERSION.x64.cab"
WV2_SHA256=2dc7d817ddce4d036f33684425c218f1ca2d073911136e5d3f8ce9b2340569b5
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/office-365-wine"
VCRT_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/winetricks/vcrun2022"

PREFIX="$HOME/.office_365"
DESKTOP=1 PWSH=0 REINSTALL=0 CLEAN=0 SRC=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) [ $# -ge 2 ] || usage 2; PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --no-desktop) DESKTOP=0; shift ;;
        --powershell) PWSH=1; shift ;;
        --reinstall) REINSTALL=1; shift ;;
        --clean-cache) CLEAN=1; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "install.sh: unknown option $1" >&2; usage 2 ;;
        *) [ -z "$SRC" ] || usage 2; SRC="$1"; shift ;;
    esac
done
[ "$GE_VERSION" = GE-Proton11-7 ] || { echo "install.sh: env.sh names $GE_VERSION, but this script has the checksum of GE-Proton11-7" >&2; exit 2; }
if [ -n "$SRC" ]; then
    [ -f "$SRC" ] || { echo "install.sh: $SRC not found" >&2; exit 2; }
    [ "$(head -c2 "$SRC")" = MZ ] || { echo "install.sh: $SRC is not a Windows program (expected OfficeSetup.exe)" >&2; exit 2; }
    SRC="$(readlink -f "$SRC")"
fi

mkdir -p "$PREFIX" && PREFIX="$(cd "$PREFIX" && pwd -P)" || exit 1
case "$PREFIX" in
    *[[:space:]\"\'\$\`\\]*) echo "install.sh: the prefix path must not contain spaces, quotes, \$, \` or \\: $PREFIX" >&2; exit 2 ;;
esac
export WINEPREFIX="$PREFIX"
unset WINEARCH WINEDLLOVERRIDES WINEPATH WINELOADER WINESERVER WINEDLLPATH

LOGDIR="$WINEPREFIX/install-logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/install-$(date +%Y%m%d-%H%M%S).log"
say()  { printf '%s\n' "$*" | tee -a "$LOG"; }
step() { say ""; say "==> $*"; }
warn() { say "WARNING: $*"; }
die()  { say "ERROR: $*"; say "Full log: $LOG"; exit 1; }
run()  { printf '+ %s\n' "$*" >>"$LOG"; "$@" </dev/null >>"$LOG" 2>&1; }

# Runs a Wine program and prints its output. Wine's output goes to a file, not
# a pipe: a Wine session started by the command would keep a pipe open forever.
wine_output() {
    local t rc; t="$(mktemp)"
    "$@" </dev/null >"$t" 2>>"$LOG"; rc=$?
    tr -d '\r' <"$t"; rm -f "$t"
    return $rc
}
# PIDs of this prefix's processes whose command line matches the regex $1
# (case-insensitive).
prefix_pids() {
    local p
    for p in $(pgrep -i -u "$(id -u)" -f "$1"); do
        tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -qxF "WINEPREFIX=$WINEPREFIX" && echo "$p"
    done
}
human() { awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf "%.1f %s", b, u[i] }'; }
# fetch URL FILE sha256|sha512 SUM DESCRIPTION: download FILE unless a copy
# with the right checksum is there already.
fetch() {
    local url="$1" f="$2" algo="$3" sum="$4"
    [ -f "$f" ] && printf '%s  %s\n' "$sum" "$f" | "${algo}sum" -c --status && return 0
    mkdir -p "$(dirname "$f")"
    say "Downloading $5"
    run curl -fsSL --retry 3 --retry-delay 5 -o "$f.part" "$url" || { rm -f "$f.part"; return 1; }
    if ! printf '%s  %s\n' "$sum" "$f.part" | "${algo}sum" -c --status; then
        rm -f "$f.part"; say "$(basename "$f"): checksum mismatch"; return 1
    fi
    mv -f "$f.part" "$f"
}
# Values of HKLM\Software\Microsoft\Office\ClickToRun\Configuration, from the
# registry file wineserver writes when it exits.
c2r_config() {
    awk -v name="\"$1\"=\"" '/^\[Software\\\\Microsoft\\\\Office\\\\ClickToRun\\\\Configuration\]/ { f = 1; next }
         /^\[/ { f = 0 }
         f && index($0, name) == 1 { v = substr($0, length(name) + 1); sub(/".*$/, "", v); print v }' \
        "$WINEPREFIX/system.reg" 2>/dev/null
}
OFFICE16="$WINEPREFIX/drive_c/Program Files/Microsoft Office/root/Office16"
office_installed() {
    [ -n "$(c2r_config ProductReleaseIds)" ] &&
        { [ -f "$OFFICE16/WINWORD.EXE" ] || [ -f "$OFFICE16/EXCEL.EXE" ] || [ -f "$OFFICE16/POWERPNT.EXE" ]; }
}

say "Microsoft 365 for Wine installer, $(date)"
say "Prefix: $WINEPREFIX"
say "Log:    $LOG"
[ -n "$SRC" ] && say "Installer: $SRC"

# ---------------------------------------------------------------- checks ----
missing=()
for t in curl tar sha256sum sha512sum cabextract python3 winetricks pgrep du df awk; do
    command -v "$t" >/dev/null || missing+=("$t")
done
[ ${#missing[@]} -eq 0 ] ||
    die "missing programs: ${missing[*]} (e.g. Arch: pacman -S curl cabextract python winetricks; Debian/Ubuntu: apt install curl cabextract python3 winetricks)"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 6))' || die "python3 >= 3.6 needed"
# GE-Proton's Wine still runs some programs as 32-bit processes. Without a 32-bit FreeType they
# compute the prefix's window metrics from no font at all (title bars millions of pixels tall),
# and every Office window stays invisible. Distribution Wine packages built as pure WoW64 (Arch's
# wine since 11) no longer pull this library in. ldconfig lists 32-bit libraries as "(libc6)".
for lc in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
    command -v "$lc" >/dev/null || continue
    [ "$("$lc" -p 2>/dev/null | grep -c 'libfreetype\.so\.6 (libc6)')" -gt 0 ] ||
        die "no 32-bit FreeType library: GE-Proton's 32-bit Wine processes would write corrupt window metrics into the prefix and Office's windows would stay invisible (Arch: pacman -S lib32-freetype2, from [multilib]; Debian/Ubuntu: dpkg --add-architecture i386 && apt install libfreetype6:i386; Fedora: dnf install freetype.i686)"
    break
done
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] ||
    die "no graphical session (DISPLAY and WAYLAND_DISPLAY are unset): Office's installer and apps need one"
if command -v vulkaninfo >/dev/null; then
    vulkaninfo --summary 2>/dev/null | grep -q deviceName ||
        warn "vulkaninfo finds no Vulkan device; Office draws through DXVK (Vulkan) and stays blank without one"
# (each folder on its own: one of them is usually missing, which would fail a single ls of both)
elif ! compgen -G '/usr/share/vulkan/icd.d/*.json' >/dev/null && ! compgen -G '/etc/vulkan/icd.d/*.json' >/dev/null; then
    warn "no Vulkan driver found; Office draws through DXVK (Vulkan) and stays blank without one"
fi
free_kb="$(df -Pk "$WINEPREFIX" | awk 'NR == 2 { print $4 }')"
[ "${free_kb:-0}" -ge $((15 * 1024 * 1024)) ] ||
    warn "only $(human $((free_kb * 1024))) free on $WINEPREFIX; a full install needs about 15 GB"

if [ -n "$(prefix_pids '(^|\\)(winword|excel|powerpnt|onenote|outlook|msaccess|mspub|officesetup)\.exe')" ]; then
    die "Office is running in this prefix; close it and run install.sh again"
fi

# ------------------------------------------------------- 1. GE-Proton -------
step "1/6 $GE_VERSION"
RUNNER="$WINEPREFIX/runner/$GE_VERSION-x86_64"
if [ ! -x "$RUNNER/files/bin/wine" ]; then
    tarball="$CACHE/$GE_VERSION-x86_64.tar.gz"
    fetch "$GE_URL" "$tarball" sha512 "$GE_SHA512" "$GE_VERSION (550 MB)" ||
        die "downloading $GE_VERSION failed ($GE_URL)"
    say "Unpacking $GE_VERSION into $WINEPREFIX/runner"
    mkdir -p "$WINEPREFIX/runner"
    run tar -C "$WINEPREFIX/runner" -xzf "$tarball" || die "unpacking $tarball failed"
fi
[ -x "$RUNNER/files/bin/wine" ] || die "$RUNNER/files/bin/wine is missing"
say "OK ($("$RUNNER/files/bin/wine" --version 2>/dev/null))"

# --------------------------------------------- 2. prefix and runtimes -------
step "2/6 Wine prefix and runtimes"
L="$WINEPREFIX/wine-office-fixes"
if [ "$HERE" != "$(readlink -f "$L" 2>/dev/null)" ]; then
    mkdir -p "$L"
    tar -C "$HERE" --exclude=.git --exclude=install-logs --exclude='*.exe' --exclude='*.cab' -cf - . |
        tar -C "$L" -xf - || die "copying $HERE to $L failed"
    say "Copied $HERE to $L"
fi
# A download without file modes loses the executable bits; menu entries run
# the office launcher directly.
chmod +x "$L/office" "$L/apply-fixes.sh" "$L/install-menu-entries.sh" "$L/powershell" \
         "$L/install.sh" "$L/bin/winepath" "$L/shim/build.sh" || die "making the scripts in $L executable failed"
# GE-Proton's Wine on PATH (and its winepath stand-in), WINEPREFIX, WINEARCH=win64
. "$L/env.sh"
[ "$WINEPREFIX" = "$PREFIX" ] || die "env.sh resolved the prefix to $WINEPREFIX instead of $PREFIX"
# No Linux menu entries or file associations for every Windows program
# (office-wine.reg turns winemenubuilder off for good).
export WINEDLLOVERRIDES="winemenubuilder.exe=d"

if [ ! -f "$WINEPREFIX/system.reg" ]; then
    say "Creating a 64-bit prefix"
    # Without Wine Gecko (no program here uses Wine's IE engine); Wine Mono
    # comes with the prefix update in apply-fixes.sh, as in the tested setup.
    # (GE-Proton has no wineboot command; a bare wineboot would be the system Wine's)
    WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d" run wine wineboot -i || die "wineboot failed"
    run wineserver -w
fi
grep -q '^#arch=win64' "$WINEPREFIX/system.reg" || die "$WINEPREFIX is not a 64-bit Wine prefix"

VERBS=(win10 corefonts msxml6 msxml3)
todo=()
for v in "${VERBS[@]}"; do
    grep -qx "$v" "$WINEPREFIX/winetricks.log" 2>/dev/null || todo+=("$v")
done
if [ ${#todo[@]} -gt 0 ]; then
    say "winetricks ${todo[*]} (downloads from Microsoft and SourceForge)"
    run winetricks -q "${todo[@]}" ||
        die "winetricks failed; fix the cause shown in the log and run install.sh again"
fi
# Microsoft's VC++ runtime. Once Office is installed its own redist is
# registered as newer and vc_redist refuses (status 102); apply-fixes.sh then
# extracts the DLLs from the downloaded redist packages instead.
if ! grep -qx vcrun2022 "$WINEPREFIX/winetricks.log" 2>/dev/null; then
    say "winetricks vcrun2022"
    run winetricks -q vcrun2022 || say "  (vcrun2022 did not finish; apply-fixes.sh installs its DLLs instead)"
fi
for a in x64 x86; do
    [ -s "$VCRT_CACHE/vc_redist.$a.exe" ] && continue
    mkdir -p "$VCRT_CACHE"
    run curl -fsSL --retry 3 -o "$VCRT_CACHE/vc_redist.$a.exe" "https://aka.ms/vs/17/release/vc_redist.$a.exe" ||
        die "downloading Microsoft's VC++ runtime (vc_redist.$a.exe) failed"
done
run wineserver -k
say "OK"

# ------------------------------------------------ 3. Wine workarounds -------
step "3/6 Wine workarounds (apply-fixes.sh)"
run "$L/apply-fixes.sh" || die "apply-fixes.sh failed"
say "OK"

# ------------------------------------------------------- 4. WebView2 --------
step "4/6 Microsoft Edge WebView2 runtime $WV2_VERSION"
# Office's sign-in page is a WebView2 window. This Fixed Version runtime is
# selected for all programs by a policy in office-wine.reg.
WV2="$WINEPREFIX/drive_c/Program Files/WebView2Fixed/Microsoft.WebView2.FixedVersionRuntime.$WV2_VERSION.x64"
if [ ! -f "$WV2/msedgewebview2.exe" ]; then
    cab="$CACHE/Microsoft.WebView2.FixedVersionRuntime.$WV2_VERSION.x64.cab"
    fetch "$WV2_URL" "$cab" sha256 "$WV2_SHA256" "WebView2 Fixed Version $WV2_VERSION (370 MB)" ||
        die "downloading the WebView2 runtime failed ($WV2_URL)"
    mkdir -p "$(dirname "$WV2")"
    run cabextract -q -d "$(dirname "$WV2")" "$cab"
    [ -f "$WV2/msedgewebview2.exe" ] || die "unpacking $cab failed"
fi
say "OK"

# --------------------------------------------------- 5. Microsoft 365 -------
step "5/6 Microsoft 365"
DRIVE_C="$WINEPREFIX/drive_c"
OFFICEDIR="$DRIVE_C/Program Files/Microsoft Office"
# Click-to-Run's logs, followed by c2rlog.py: only those newer than $STAMP
# belong to this attempt.
c2r_scan() { python3 -I "$L/c2rlog.py" scan "$STAMP.json" "$STAMP" "$DRIVE_C/users" "$DRIVE_C/windows/temp"; }

# One run of Office's installer, in a subshell so its traps don't outlive it.
# Returns 0 when Click-to-Run reports the installation complete, 3 when it
# stalled, 4 when the installer quit without finishing, 5 when a Click-to-Run
# task failed, 6 when Click-to-Run can't reach Microsoft's servers.
office_attempt() (
    trap 'wineserver -k; exit 130' INT TERM HUP
    locker="$DRIVE_C/ProgramData/Microsoft/Office/ClickToRunPackageLocker"
    [ -e "$locker" ] && chmod 644 "$locker"
    run wineserver -k
    # The registry has per-program settings for this file name (office-wine.reg).
    setup_dir="$DRIVE_C/windows/temp/office-setup"
    mkdir -p "$setup_dir" && cp -f "$SRC" "$setup_dir/OfficeSetup.exe" || exit 4
    rm -f "$STAMP.json"; touch "$STAMP"
    printf '+ wine OfficeSetup.exe\n' >>"$LOG"
    (cd "$setup_dir" && exec wine OfficeSetup.exe) </dev/null >>"$LOG" 2>&1 &

    used() { du -sk "$@" 2>/dev/null | awk '{ s += $1 } END { print s * 1024 }'; }
    t0=$(date +%s) last_progress=$t0 last_report=$t0 gone=0 sig="" net0=0
    pct=0 complete=0 failed=0 neterr=0 tasks=-
    size0=$(used "$OFFICEDIR")
    while sleep 10; do
        now=$(date +%s)
        read -r pct complete failed neterr tasks < <(c2r_scan)
        if [ "$failed" = 1 ]; then
            sleep 20; wineserver -k; exit 5
        fi
        if [ "$complete" = 1 ]; then
            # let Click-to-Run finish its last tasks, then make sure none failed
            sleep 30
            read -r pct complete failed neterr tasks < <(c2r_scan)
            [ "$failed" = 1 ] && { wineserver -k; exit 5; }
            say "  Click-to-Run reports the installation complete"
            exit 0
        fi
        # The bootstrapper (OfficeSetup.exe) and Click-to-Run's client show
        # the progress window; Click-to-Run's service keeps running afterwards.
        if [ -z "$(prefix_pids '(^|\\)(officesetup|officec2rclient)\.exe')" ]; then
            gone=$((gone + 1))
            [ $gone -ge 6 ] && { wineserver -k; exit 4; }
        else
            gone=0
        fi
        if [ $((now - last_report)) -ge 60 ]; then
            size=$(used "$OFFICEDIR")
            if [ "$pct $size" != "$sig" ]; then sig="$pct $size" last_progress=$now net0=$neterr; fi
            say "  $(( (now - t0) / 60 )) min: $pct%, $(human $(( size - size0 ))) in Program Files/Microsoft Office"
            last_report=$now
        fi
        # Without a connection Click-to-Run retries thousands of times a minute.
        if [ $((now - last_progress)) -ge 300 ] && [ $((neterr - net0)) -ge 1000 ]; then
            say "  Click-to-Run can't connect to Microsoft's servers (internet connection?); stopping this attempt"
            wineserver -k; exit 6
        fi
        if [ $((now - last_progress)) -ge 1800 ]; then
            say "  no progress for 30 minutes; stopping this attempt"
            wineserver -k; exit 3
        fi
    done
)

STAMP="$(mktemp)"
trap 'rm -f "$STAMP" "$STAMP.json"' EXIT
if office_installed && [ $REINSTALL = 0 ]; then
    say "Office is already installed ($(c2r_config ProductReleaseIds) $(c2r_config VersionToReport)); use --reinstall to run its installer again"
elif [ -z "$SRC" ]; then
    die "no Office installed in $WINEPREFIX yet: pass OfficeSetup.exe, downloaded from office.com (install.sh --help)"
else
    say "Downloading and installing Office; this takes 20-60 minutes. Office's installer"
    say "window opens: leave it alone, this script closes it when it has finished."
    ok=0
    for attempt in 1 2 3; do
        [ $attempt -gt 1 ] && say "Attempt $attempt of 3"
        office_attempt; rc=$?
        [ $rc -eq 130 ] && { wineserver -k; die "interrupted"; }
        # Ends the installer (it can wait on a final dialog) and Click-to-Run's
        # service; wineserver writes the registry files as it exits.
        wineserver -k 2>/dev/null; run wineserver -w
        if [ $rc -eq 0 ] && office_installed; then ok=1; break; fi
        case $rc in
            0) say "  Click-to-Run finished, but no Office product is registered" ;;
            4) say "  Office's installer quit without finishing" ;;
            5) read -r _ _ _ _ tasks < <(c2r_scan)
               say "  a Click-to-Run task failed: ${tasks//,/ }" ;;
        esac
        # Click-to-Run's log lines about the failure, for the install log
        python3 -I "$L/c2rlog.py" errors "$STAMP.json" >>"$LOG" 2>&1
    done
    [ $rc = 6 ] && die "Office's installer could not download Office: check the internet connection, then run install.sh again (it resumes)"
    [ $ok = 1 ] || die "Office's installer did not succeed after 3 attempts. Click-to-Run's logs: $DRIVE_C/users/*/AppData/Local/Temp/*.log and $DRIVE_C/windows/temp/*.log"
    rm -rf "$DRIVE_C/windows/temp/office-setup"
    printf '%s %s installed %s from %s\n' "$(c2r_config ProductReleaseIds)" "$(c2r_config VersionToReport)" \
        "$(date -I)" "$SRC" >"$WINEPREFIX/.office-installed"
fi
say "OK: $(c2r_config ProductReleaseIds), version $(c2r_config VersionToReport)"

# ------------------------------------------------------- 6. finish ----------
step "6/6 Workarounds for the installed Office, desktop integration"
run "$L/apply-fixes.sh" || die "apply-fixes.sh failed"
for p in $(c2r_config ProductReleaseIds | tr ',' ' '); do
    grep -qF "\"$p\"=dword:00000002" "$WINEPREFIX/user.reg" ||
        warn "token licensing (LicensingNext) is not set for $p; Office may refuse to activate"
done
for f in vcruntime140.dll msvcp140.dll; do
    grep -qa 'Wine builtin DLL' "$DRIVE_C/windows/system32/$f" 2>/dev/null &&
        warn "system32/$f is still Wine's builtin; Office will not start (see the log)"
done

if [ $PWSH = 1 ]; then
    if ! grep -qx powershell "$WINEPREFIX/winetricks.log" 2>/dev/null; then
        say "winetricks powershell"
        run winetricks -q powershell || warn "winetricks powershell failed"
    fi
    # PSReadLine's signature check crashes in Wine; the prompt works without it.
    m="$DRIVE_C/Program Files/PowerShell/7/Modules"
    [ -d "$m/PSReadLine" ] && [ ! -e "$m/PSReadLine.disabled-under-wine" ] &&
        mv "$m/PSReadLine" "$m/PSReadLine.disabled-under-wine"
    run wineserver -w
    [ -d "$DRIVE_C/Program Files/PowerShell/7" ] && say "PowerShell 7: $L/powershell"
fi

if [ $DESKTOP = 1 ]; then
    apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    run "$L/install-menu-entries.sh" || warn "adding the menu entries failed"
    # Menu entries and file associations Wine's winemenubuilder may have made
    # for this prefix: they would start Office with the wrong Wine.
    n=0
    while IFS= read -r -d '' f; do
        if grep -qF -e "\"WINEPREFIX=$WINEPREFIX\"" -e "WINEPREFIX=\"$WINEPREFIX\"" -e "WINEPREFIX=$WINEPREFIX " "$f"; then
            printf 'removing %s\n' "$f" >>"$LOG"; rm -f "$f"; n=$((n + 1))
        fi
    done < <(find "$apps" \( -path "$apps/wine/*" -o -name 'wine-extension-*' -o -name 'wine-protocol-*' \) \
                  -name '*.desktop' -print0 2>/dev/null)
    [ -d "$apps/wine" ] && find "$apps/wine" -mindepth 1 -type d -empty -delete 2>/dev/null
    [ $n -gt 0 ] && say "Removed $n menu entries/associations Wine had created for this prefix"
    command -v update-desktop-database >/dev/null && run update-desktop-database "$apps"
    say "Menu entries: Word, Excel, PowerPoint ($apps/ms365-*.desktop)"
fi

size=$(du -scb "$CACHE" 2>/dev/null | tail -1 | cut -f1)
if [ $CLEAN = 1 ]; then
    rm -rf "$CACHE"
    say "Deleted the download cache ($(human "${size:-0}"))"
elif [ "${size:-0}" -gt $((100 * 1024 * 1024)) ]; then
    say "Downloads kept in $CACHE ($(human "$size")); re-run with --clean-cache to delete them"
fi

say ""
say "Done: Microsoft 365 is installed in $WINEPREFIX."
say "Start it with:  $L/office word|excel|powerpoint [file]"
[ $DESKTOP = 1 ] && say "or from the application menu (Word, Excel, PowerPoint)."
say "On first start, sign in with the Microsoft account that has your Microsoft 365"
say "subscription: Office then activates itself."
