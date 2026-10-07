#!/system/bin/sh
# 检查 QEMU 各线程的 wchan/stat，定位挂起线程
P=$1
for t in /proc/$P/task/*; do
    tid=${t##*/}
    wc=$(cat $t/wchan 2>/dev/null)
    st=$(cat $t/stat 2>/dev/null)
    state=${st%% *}
    # stat 格式: pid (comm) state ...
    s=$(cat $t/stat 2>/dev/null | awk '{print $3}')
    c=$(cat $t/comm 2>/dev/null)
    echo "$tid state=$s wchan=$wc comm=$c"
done | sort
