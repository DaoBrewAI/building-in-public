#!/usr/bin/env bash
# /opt/northstar/hooks/stop-gate.sh —— Stop：结束前的总闸门
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -d .northstar ] || exit 0
cat >/dev/null
notify() { osascript -e "display notification \"$1\" with title \"NORTHSTAR\"" 2>/dev/null || true; }
CNT="$(git rev-parse --git-dir)/northstar-stop-count"

# 1. 签名：不一致就让 agent 停下并通知你，不让它自己修
if ! /opt/northstar/bin/northstar verify >/dev/null 2>&1; then
  notify "签名校验失败：受保护文件被改动，需要你处理"
  exit 0
fi
# 2. 所有改动必须已提交（提交时都过了对齐评审）
if [ -n "$(git status --porcelain -- . ':!status' ':!drafts' ':!proposals')" ]; then
  echo "NORTHSTAR：还有未提交的改动。按验收标准小步提交（每次提交都会经过对齐评审）后再结束。" >&2; exit 2
fi
# 3. 越界改动必须为零
if [ -f .northstar/missions/ACTIVE ]; then
  base=$(git log -1 --format=%H --grep="^\[NS\] start $(cat .northstar/missions/ACTIVE)$")
  if [ -n "$base" ] && ! out=$(/opt/northstar/bin/northstar-scope $(git diff --name-only "$base" -- . ':!.northstar' ':!status') 2>&1); then
    echo "NORTHSTAR 纠偏：$out。撤回这些越界改动后再结束。" >&2; exit 2
  fi
fi
# 4. 验收检查 + 进度报告
ok=1
if [ -f .northstar/checks/run_all.sh ]; then bash .northstar/checks/run_all.sh >/tmp/ns-checks.log 2>&1 || ok=0; else : >/tmp/ns-checks.log; fi
/opt/northstar/bin/northstar-status >>/tmp/ns-checks.log 2>&1 || ok=0
if [ $ok -eq 1 ]; then rm -f "$CNT"; exit 0; fi
n=$(( $(cat "$CNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CNT"
if [ "$n" -ge 5 ]; then rm -f "$CNT"; notify "验收检查连续 5 次未通过，需要你介入"; exit 0; fi
echo "NORTHSTAR 验收检查或进度报告未通过（第 $n 次），修复后再结束：" >&2
tail -n 40 /tmp/ns-checks.log >&2
exit 2
