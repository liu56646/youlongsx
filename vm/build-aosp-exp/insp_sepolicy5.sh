#!/usr/bin/env bash
set -e
CIL=/tmp/plat.cil
echo "=== find on app_api_service / system_server_service ==="
grep -oE '\(allow [a-z0-9_]+ (app_api_service|ephemeral_app_api_service|system_server_service|system_server_service) \(service_manager \(find\)\)\)' "$CIL" | sort -u | head -30 || true
echo "=== appdomain find rules (attr based) ==="
grep -oE '\(allow appdomain [a-z0-9_]+ \(service_manager \(find\)\)\)' "$CIL" | sort -u | head -20 || true
echo "=== system_app find rules ==="
grep -oE '\(allow system_app [a-z0-9_]+ \(service_manager \(find\)\)\)' "$CIL" | sort -u | head -20 || true
echo "=== platform_app find rules ==="
grep -oE '\(allow platform_app [a-z0-9_]+ \(service_manager \(find\)\)\)' "$CIL" | sort -u | head -20 || true
echo "=== binder call to system_server (any form) ==="
grep -oE '\(allow [a-z0-9_]+ system_server \(binder \(call[a-z ]*\)\)\)' "$CIL" | sort -u | head -30 || true
