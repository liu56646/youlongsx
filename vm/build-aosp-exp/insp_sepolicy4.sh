#!/usr/bin/env bash
set -e
CIL=/tmp/plat.cil
echo "=== system_server service_manager find (sample) ==="
grep -oE '\(allow system_server [a-z0-9_]+ \(service_manager \(find\)\)\)' "$CIL" | sort -u | head -30 || true
echo "--- system_server -> activity_service ---"
grep -oE '\(allow system_server activity_service [^)]*\)+' "$CIL" | head -5 || true
echo "=== does system_server find via attribute? ==="
grep -nE '\(allow system_server base_typeattr' "$CIL" | head -10 || true
echo "=== who has find on activity_service including attrs ==="
grep -nE 'activity_service' "$CIL" | head -40 || true
