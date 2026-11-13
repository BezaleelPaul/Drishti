#!/usr/bin/env bash
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# 1. Ensure backend server is running on port 8000
if ! ss -tulpn 2>/dev/null | grep -q ":8000 "; then
  echo "Starting local Drishti AI backend server on http://127.0.0.1:8000..."
  (cd "$DIR/server" && PYTHONPATH=. uvicorn api.main:app --host 127.0.0.1 --port 8000 > /tmp/drishti_server.log 2>&1) &
  sleep 2
fi

# 2. Launch Linux Desktop Workstation App
export DISPLAY="${DISPLAY:-:0}"
echo "Launching Drishti Linux Workstation UI..."
exec "$DIR/linux_app/bundle/drishti" "$@"
