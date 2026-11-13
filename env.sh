# Environment for running this Office prefix with GE-Proton's Wine. Source it: . env.sh
# (this folder is PREFIX/wine-office-fixes; the prefix is its parent folder)
OFFICE_FIXES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WINEPREFIX="$(dirname "$OFFICE_FIXES")"
GE_VERSION=GE-Proton11-7
GE_PROTON="$WINEPREFIX/runner/$GE_VERSION-x86_64/files"
export PATH="$OFFICE_FIXES/bin:$GE_PROTON/bin:$PATH"
export LD_LIBRARY_PATH="$GE_PROTON/lib/x86_64-linux-gnu:$GE_PROTON/lib/i386-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEARCH=win64
# Grayscale font antialiasing for Wine (see Xresources): with the desktop's subpixel setting
# (Xft.rgba: rgb, KDE's default) Word freezes in the ribbon's font list.
export XENVIRONMENT="$OFFICE_FIXES/Xresources"
# Settings for this machine, kept when install.sh replaces this folder: PREFIX/local-env.sh
# (README: "Settings for this machine"), e.g. the GPU Office renders on.
if [ -f "$WINEPREFIX/local-env.sh" ]; then . "$WINEPREFIX/local-env.sh"; fi
