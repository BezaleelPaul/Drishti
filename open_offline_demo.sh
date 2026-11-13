#!/usr/bin/env bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
DEMO_PATH="$DIR/presentation/OFFLINE_DEMO_BACKUP.html"
echo "======================================================================="
echo "  OPENING OFFLINE VISUAL DEMO BACKUP IN DEFAULT BROWSER"
echo "======================================================================="
echo "  Path: $DEMO_PATH"
if command -v xdg-open > /dev/null; then
    xdg-open "$DEMO_PATH"
elif command -v open > /dev/null; then
    open "$DEMO_PATH"
else
    echo "Please open $DEMO_PATH in any web browser."
fi
