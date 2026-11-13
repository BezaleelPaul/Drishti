#!/usr/bin/env bash
# Drishti AI - Clinical rehearsal suite launcher
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR/server"
export PYTHONPATH=.
echo "======================================================================="
echo "  RUNNING END-TO-END DEMO REHEARSAL (23 ASSERTIONS, 13 STEPS)"
echo "======================================================================="
python3 demo_rehearsal.py --runs 1 --port 8092
