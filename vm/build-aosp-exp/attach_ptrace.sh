#!/system/bin/sh
# 找 qemu pid 并附加 ptrace 捕捉器
QPID=$(ps -A | awk '/qemu-system/ {print $2; exit}')
echo "qemu pid=$QPID"
/data/local/tmp/ptrace_catcher $QPID 150
