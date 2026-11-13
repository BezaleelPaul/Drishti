#!/usr/bin/env bash
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR/server"
export PYTHONPATH=.
echo "======================================================================="
echo "  RUNNING 10-SUBSYSTEM CLINICAL AUDIT VERIFICATION"
echo "======================================================================="
python3 verify_complete_system.py
