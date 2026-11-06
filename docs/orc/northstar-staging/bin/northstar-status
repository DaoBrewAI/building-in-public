#!/usr/bin/env python3
# northstar-status：进度报告的事实部分由脚本生成；agent 只写带引用的说明，脚本逐条核对
# 本机：/opt/northstar/bin/northstar-status；CI：.github/workflows/northstar_status.py（同一份）
import fnmatch, json, os, re, subprocess, sys
def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True)
os.chdir(sh("git rev-parse --show-toplevel").stdout.strip() or os.getcwd())
NS, OUT = ".northstar", "status"
if not os.path.exists(f"{NS}/architecture.json"):
    sys.exit(0)                                   # 这个项目没启用进度报告
arch = json.load(open(f"{NS}/architecture.json"))
checks = json.load(open(f"{NS}/checks.json")) if os.path.exists(f"{NS}/checks.json") else []
if os.path.exists(f"{NS}/missions/ACTIVE"):
    mission = open(f"{NS}/missions/ACTIVE").read().strip()
else:                                             # finish 之后 ACTIVE 已归档，沿用上次报告里的 mission
    mission = json.load(open(f"{OUT}/status.json"))["mission"]
base = sh(f"git log -1 --format=%H --grep='^\\[NS\\] start {mission}$'").stdout.strip()
if not base: sys.exit(f"找不到 [NS] start {mission} 这个 commit")

# ---- 事实层 ----
# 只改了 status/ 的 commit（提交进度报告本身）不算：否则报告一提交，CI 重新生成的 commit 列表就多一条
commits = [l.split(" ", 1) for l in sh(f"git log --format='%h %s' {base}..HEAD -- . ':!{OUT}'").stdout.splitlines()]
skip = (NS + "/", OUT + "/", "drafts/", "proposals/")
changed = [f for f in sh(f"git diff --name-only {base}..HEAD").stdout.split() if not f.startswith(skip)]
ok = {k["id"]: sh(k["cmd"]).returncode == 0 for k in checks}
comps = {}
for c in arch["components"]:
    files = [f for f in changed if any(fnmatch.fnmatch(f, p) for p in c["paths"])]
    cks = {k["id"]: ok[k["id"]] for k in checks if c["id"] in k.get("components", [])}
    st = ("fail" if not all(cks.values()) else "pass" if files and cks
          else "unverified" if files else "untouched")
    comps[c["id"]] = {"status": st, "files": files, "checks": cks}
mapped = {f for v in comps.values() for f in v["files"]}
unmapped = [f for f in changed if f not in mapped]
clauses = {}
for k in checks:
    for n in k.get("clauses", []):
        clauses.setdefault(n, {})[k["id"]] = ok[k["id"]]
facts = {"mission": mission, "base": base[:12], "commits": commits,
         "components": comps, "clauses": clauses, "unmapped_changes": unmapped}

# ---- 说明层校验 ----
errors, p = [], f"{OUT}/narrative.md"
nar = open(p).read() if os.path.exists(p) else ""
if not nar.strip(): errors.append("缺少 status/narrative.md")
shas = {c[0] for c in commits}
for i, line in enumerate(nar.splitlines(), 1):
    if not line.strip().startswith(("-", "*")): continue
    refs = re.findall(r"\[(commit|check|file):([^\]]+)\]", line)
    if not refs: errors.append(f"第 {i} 行没有引用证据")
    if re.search(r"完成|done|complete|passed|100%", line, re.I):
        errors.append(f"第 {i} 行含进度判断，进度只能由脚本给出")
    for kind, val in refs:
        if kind == "commit" and val not in shas: errors.append(f"第 {i} 行：commit {val} 不在本次 mission 内")
        if kind == "check" and val not in ok: errors.append(f"第 {i} 行：检查 {val} 不存在")
        if kind == "file":
            fp, _, ln = val.partition(":")
            if not os.path.exists(fp): errors.append(f"第 {i} 行：文件 {fp} 不存在")
            elif ln.isdigit() and int(ln) > sum(1 for _ in open(fp)): errors.append(f"第 {i} 行：{fp} 没有第 {ln} 行")
cited = set(re.findall(r"\[commit:([0-9a-f]+)\]", nar))
errors += [f"commit {s} 没有在说明里交代" for s in sorted(shas - cited)]
errors += [f"架构外改动 {f} 没有在说明里解释" for f in unmapped if f"[file:{f}" not in nar]

# ---- 输出：架构图 + 条款表 + 说明 ----
color = {"pass": "#2e7d32", "fail": "#c62828", "unverified": "#f9a825", "untouched": "#9e9e9e"}
label = {"pass": "检查通过", "fail": "检查失败", "unverified": "有改动无检查", "untouched": "未改动"}
mm = ["flowchart LR"]
for c in arch["components"]:
    s = comps[c["id"]]["status"]
    mm.append(f'  {c["id"]}["{c["name"]}<br/>{label[s]} · {len(comps[c["id"]]["files"])} 个文件"]')
    mm += [f'  {c["id"]} --> {d}' for d in c.get("depends_on", [])]
    mm.append(f'  style {c["id"]} stroke:{color[s]},stroke-width:3px')
if unmapped:
    mm += [f'  OUT["架构外改动：{len(unmapped)} 个文件"]', "  style OUT stroke:#c62828,stroke-width:3px"]
os.makedirs(OUT, exist_ok=True)
json.dump(facts, open(f"{OUT}/status.json", "w"), ensure_ascii=False, indent=2, sort_keys=True)
rows = "\n".join(f"| {n} | {'通过' if all(v.values()) else '未通过'} | {', '.join(v)} |" for n, v in sorted(clauses.items()))
open(f"{OUT}/STATUS.md", "w").write(
    f"# 进度报告：{mission}\n\n以下架构图和条款表由脚本生成；说明由 agent 撰写，每条引用都已核对。\n\n"
    "```mermaid\n" + "\n".join(mm) + "\n```\n\n| 条款 | 检查 | 检查项 |\n| --- | --- | --- |\n" + rows
    + "\n\n## 说明（agent 撰写）\n\n" + nar)
if errors:
    print("进度报告校验失败：\n" + "\n".join(errors), file=sys.stderr); sys.exit(1)
print(f"进度报告已生成：{OUT}/STATUS.md")
