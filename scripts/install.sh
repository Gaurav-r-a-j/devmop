#!/bin/zsh
# Builds DevMop, replaces /Applications/DevMop.app and opens it.
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build-app.sh
osascript -e 'quit app "DevMop"' 2>/dev/null || true
sleep 1
rm -rf /Applications/DevMop.app
cp -R build/DevMop.app /Applications/DevMop.app
open /Applications/DevMop.app
echo "Installed /Applications/DevMop.app. After an update, turn DevMop off and on again in Full Disk Access."
