#!/usr/bin/env bash
set -e
CIL=/tmp/plat.cil
[ -f "$CIL" ] || { echo "no cil"; exit 1; }
echo "=== permissive domains ==="
grep -oE '\(permissive [a-z0-9_]+\)' "$CIL" | sort -u | head -40 || true
echo "=== 'su' allows (sample) ==="
grep -oE '\(allow su [a-z0-9_]+ \([a-z_]+ \(find\)\)\)' "$CIL" | head -20 || true
echo "--- su -> activity_service ---"
grep -oE '\(allow su activity_service .*\)' "$CIL" | head -5 || true
echo "--- su -> system_server ---"
grep -oE '\(allow su system_server .*\)' "$CIL" | head -5 || true
echo "=== domains that can binder-call system_server (sample) ==="
grep -oE '\(allow [a-z0-9_]+ system_server \(binder \(call\)\)\)' "$CIL" | sort -u | head -40 || true
echo "=== who can find activity_service (full) ==="
grep -oE '\(allow [a-z0-9_]+ activity_service \(service_manager \(find\)\)\)' "$CIL" | sort -u || true
echo "=== 'shell' domain rules sample ==="
grep -oE '\(allow shell [a-z0-9_]+ \(service_manager \(find\)\)\)' "$CIL" | sort -u | head -20 || true
