#!/bin/bash
echo "=== vendor /build.prop ==="
debugfs -R 'cat /build.prop' /root/vmbuild/vendor30_ext4.img 2>&1 | head -40
echo "=== vendor /default.prop ==="
debugfs -R 'cat /default.prop' /root/vmbuild/vendor30_ext4.img 2>&1 | head -40
