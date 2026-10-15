#!/bin/zsh
# Builds DevSweep, replaces /Applications/DevSweep.app and opens it.
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build-app.sh
osascript -e 'quit app "DevSweep"' 2>/dev/null || true
sleep 1
rm -rf /Applications/DevSweep.app
cp -R build/DevSweep.app /Applications/DevSweep.app
open /Applications/DevSweep.app
echo "Installed /Applications/DevSweep.app. After an update, turn DevSweep off and on again in Full Disk Access."
