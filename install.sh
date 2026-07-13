#!/usr/bin/env bash
set -euo pipefail

kpackagetool6 -t Plasma/Applet -u .

echo ""
echo "Installed. Reload plasmashell when you are ready:"
echo "  systemctl --user restart plasma-plasmashell.service"