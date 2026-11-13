#!/usr/bin/env bash
set -e
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR/server"
export PYTHONPATH=.
echo "======================================================================="
echo "  STARTING ELYTRIVA CLINICAL SCREENING SERVER (PRODUCTION)"
echo "======================================================================="
echo "  URL: http://127.0.0.1:8000"
echo "  Swagger API Docs: http://127.0.0.1:8000/docs"
echo "  Health Status: http://127.0.0.1:8000/status"
echo "======================================================================="
uvicorn api.main:app --host 0.0.0.0 --port 8000
