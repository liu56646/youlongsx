#!/usr/bin/env bash
set -e
CIL=/tmp/plat.cil
for d in incidentd statsd notify_traceur mediaserver audioserver system_app; do
  echo "=== $d ==="
  grep -oE "\(allow system_server $d \(binder \([a-z ]+\)\)\)" "$CIL" | head -3 || true
  grep -oE "\(allow $d kmsg_device \(file \([a-z ]+\)\)\)" "$CIL" | head -2 || true
  grep -oE "\(allow $d (activity_service|app_api_service|system_server_service) \(service_manager \(find\)\)\)" "$CIL" | head -3 || true
done
echo "=== who has binder call to system_server (attr forms) ==="
grep -oE '\(allow [a-z0-9_]+ (appdomain|base_typeattr_[0-9]+) \(binder \([a-z ]+\)\)\)' "$CIL" | sort -u | head -20 || true
