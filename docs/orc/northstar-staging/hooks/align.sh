#!/usr/bin/env bash
# /opt/northstar/hooks/align.sh —— PreToolUse：每次 git commit 之前，由另一家模型审查这次要提交的改动
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -f .northstar/missions/ACTIVE ] || exit 0
payload=$(cat)
cmd=$(jq -r '.tool_input.command | if type=="array" then join(" ") else (. // "") end' <<<"$payload" 2>/dev/null)
grep -qE 'git[[:space:]]+commit' <<<"$cmd" || exit 0
# hook 在命令执行前运行：同一条命令里的 git add 还没生效，评审会看不到真正要提交的内容
grep -qE 'git[[:space:]]+add' <<<"$cmd" && { echo "NORTHSTAR：把 git add 和 git commit 分成两条命令运行：先 git add，再单独 git commit，对齐评审才能看到要提交的内容。" >&2; exit 2; }

MAXF=8                                    # 小步提交：一次最多几个文件
# 交叉评审：Claude Code 写的交给 Codex 审，Codex 写的交给 Claude 审
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then REVIEWER=codex; else REVIEWER=claude; fi
m=$(cat .northstar/missions/ACTIVE); MF=".northstar/missions/$m.md"
GD=$(git rev-parse --git-dir); CTR="$GD/northstar-drift-count"; LAST="$GD/northstar-drift-last"
notify() { osascript -e "display notification \"$1\" with title \"NORTHSTAR\"" 2>/dev/null || true; }
KEEP=(-- . ':!proposals' ':!drafts' ':!status')

# 这次要提交的改动：有暂存就看暂存，否则（git commit -a）看全部未提交改动
if git diff --cached --quiet; then DIFF=(git diff HEAD); else DIFF=(git diff --cached); fi
nf=$("${DIFF[@]}" --name-only | wc -l | tr -d ' ')
[ "$nf" -le "$MAXF" ] || { echo "NORTHSTAR：这次要提交 $nf 个文件，超过 $MAXF 个。按验收标准拆成更小的提交。" >&2; exit 2; }

prev=$(cat "$LAST" 2>/dev/null)
# 评审和 orc 的 broker 共用 northstar-review：mission 就是本节点条目；签名的设计放在 .northstar/design.md（随 seal 签名）
args=(--entry "$MF" --reviewer "$REVIEWER")
[ -f .northstar/design.md ] && args+=(--design .northstar/design.md)
[ -n "$prev" ] && args+=(--prev "$prev")
out=$("${DIFF[@]}" --stat --patch | /opt/northstar/bin/northstar-review "${args[@]}" 2>&1); rc=$?
[ $rc -eq 2 ] && { echo "$out" >&2; exit 2; }              # 不能评审（超长、没有结果）：不放行
[ $rc -eq 0 ] && { rm -f "$CTR" "$LAST"; exit 0; }         # 通过：连续偏离计数清零

n=$(( $(cat "$CTR" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CTR"
reason=$(grep -m1 -A2 '^DRIFT' <<<"$out" | tail -n +2); head -n 1 <<<"$reason" > "$LAST"
card() {
  echo "NORTHSTAR 纠偏 · mission $m · 连续第 $n 次"
  echo "违反与证据："; echo "$reason"
  echo "目标（mission 原文）："; cat "$MF"
  echo "禁止：通过修改测试、检查或扩大文件范围来让评审通过。"
}
if [ "$n" -eq 1 ]; then
  { card; echo "处理：按上面的原文修正这些改动，再重新提交。"; } >&2
elif [ "$n" -eq 2 ]; then
  git stash push --include-untracked -m "northstar-drift-$m-2" "${KEEP[@]}" >/dev/null
  { card; echo "处理：你的改动已 stash 保存（northstar-drift-$m-2），工作区已回到上一次通过评审的状态。按目标原文从头实现，不要恢复这份 stash。"; } >&2
else
  git stash push --include-untracked -m "northstar-drift-$m-$n" "${KEEP[@]}" >/dev/null
  notify "mission $m 连续 $n 次偏离，已熔断"
  { card; echo "熔断：停止实现。在 proposals/ 写明你认为目标或计划哪里需要调整，然后结束本轮工作。"; } >&2
fi
exit 2
