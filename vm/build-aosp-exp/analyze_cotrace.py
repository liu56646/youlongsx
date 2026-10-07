#!/usr/bin/env python3
# 逐线程重放 COTRACE，找出“切出去没切回来”的协程
import re, sys, collections

path = sys.argv[1]
lines = open(path, encoding='utf-8', errors='replace').read().splitlines()

pat = re.compile(r'COTRACE seq=(\d+) tid=(-?\d+) (OUT|IN ) from=\(nil\)|COTRACE')
full = re.compile(r'COTRACE seq=(\d+) tid=(-?\d+) (OUT|IN ) from=(0x[0-9a-f]+) to=(0x[0-9a-f]+) action=(\d+) cur=(0x[0-9a-f]+) leader=(0x[0-9a-f]+)')

events = []
for ln in lines:
    m = full.search(ln)
    if m:
        events.append((int(m.group(1)), int(m.group(2)), m.group(3).strip(),
                       m.group(4), m.group(5), int(m.group(6))))

print("COTRACE 事件数 =", len(events))
if not events:
    sys.exit(0)

# 每个线程维护一个“当前在跑”的栈（from 侧）
# OUT from=A to=B : A 被挂起, 期望之后有 IN from=A ...
pending = collections.defaultdict(list)   # tid -> [(seq, A, B, action)]
issues = []
last = collections.defaultdict(int)
for seq, tid, ph, a, b, act in events:
    last[tid] = seq
    if ph == 'OUT':
        pending[tid].append((seq, a, b, act))
    else:
        # IN from=A to=B : A 恢复；匹配最近一次 A/B 相同的 OUT
        for i in range(len(pending[tid]) - 1, -1, -1):
            s, pa, pb, pact = pending[tid][i]
            if pa == a and pb == b:
                pending[tid].pop(i)
                break

print("\n各线程最后活动序号：")
for tid, s in sorted(last.items(), key=lambda kv: kv[1]):
    print("  tid=%-8d last_seq=%d" % (tid, s))

print("\n未匹配的 OUT（= 切出去没切回来）：")
total = 0
for tid, st in pending.items():
    for (s, a, b, act) in st:
        print("  tid=%-8d seq=%d  from=%s to=%s action=%d" % (tid, s, a, b, act))
        total += 1
print("合计未匹配 =", total)

# 打印最后 12 条事件
print("\n最后 12 条事件：")
for e in events[-12:]:
    print("  seq=%d tid=%d %s from=%s to=%s action=%d" % e)
