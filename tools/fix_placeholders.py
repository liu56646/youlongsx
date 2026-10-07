import os, re, sys

root = r"k:\youlongsx\project\res"
# 只匹配带 type 属性的空占位条目（资源混淆残留），把 false 改成 @null
pat = re.compile(
    r'(<item type="(?:drawable|layout|anim|animator|menu|interpolator|transition|xml|raw)" name="[^"]*">)false(</item>)'
)

n = 0
files = 0
for dp, dn, fn in os.walk(root):
    if "values" not in dp:
        continue
    for f in fn:
        if not f.endswith(".xml"):
            continue
        p = os.path.join(dp, f)
        with open(p, encoding="utf-8") as fh:
            s = fh.read()
        s2, c = pat.subn(lambda m: m.group(1) + "@null" + m.group(2), s)
        if c:
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(s2)
            n += c
            files += 1

print("replaced", n, "items in", files, "files")
