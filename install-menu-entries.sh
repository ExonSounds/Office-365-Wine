#!/bin/bash
# Add Word, Excel and PowerPoint to the desktop's app menu (and as "Open with" handlers), launched
# through wine-office-fixes/office with GE-Proton.
#   install-menu-entries.sh            add the entries
#   install-menu-entries.sh --remove   remove them (~/.local/share/applications/ms365-*.desktop)
set -euo pipefail
FIXES="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
OFFICE16="$(dirname "$FIXES")/drive_c/Program Files/Microsoft Office/root/Office16"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

if [ "${1:-}" = --remove ]; then
    rm -f "$APPS"/ms365-{word,excel,powerpoint}.desktop
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" || true
    echo "menu entries removed from $APPS"
    exit 0
fi
mkdir -p "$APPS"

entry() { # entry <id> <name> <exe> <logo> <wm class> <mime types>
    [ -f "$OFFICE16/$3" ] || { echo "skipping $2: $3 is not installed" >&2; return 0; }
    local icon="$OFFICE16/LogoImages/$4.scale-180.png"
    [ -f "$icon" ] || icon=wine
    cat > "$APPS/ms365-$1.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Comment=Microsoft 365 $2 (Wine)
Exec="$FIXES/office" $1 %f
Icon=$icon
Terminal=false
Categories=Office;
StartupWMClass=$5
MimeType=$6
EOF
}

entry word "Word" WINWORD.EXE WinWordLogo winword.exe \
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/msword;application/vnd.ms-word.document.macroEnabled.12;application/rtf;"
entry excel "Excel" EXCEL.EXE ExcelLogo excel.exe \
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;application/vnd.ms-excel;application/vnd.ms-excel.sheet.macroEnabled.12;text/csv;"
entry powerpoint "PowerPoint" POWERPNT.EXE PowerPntLogo powerpnt.exe \
    "application/vnd.openxmlformats-officedocument.presentationml.presentation;application/vnd.ms-powerpoint;application/vnd.ms-powerpoint.presentation.macroEnabled.12;"

command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" || true
echo "menu entries written to $APPS"
