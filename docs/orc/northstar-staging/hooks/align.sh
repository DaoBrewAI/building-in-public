#!/usr/bin/env bash
# /opt/northstar/hooks/align.sh —— PreToolUse：每次 git commit 之前，由另一家模型审查这次要提交的改动
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -f .northstar/missions/ACTIVE ] || exit 0
payload=$(cat)
cmd=$(jq -r '.tool_input.command | if type=="array" then join(" ") else (. // "") end' <<<"$payload" 2>/dev/null)
grep -qE 'git[[:space:]]+commit' <<<"$cmd" || exit 0

MAXF=8                                    # 小步提交：一次最多几个文件
# 交叉评审：Claude Code 写的交给 Codex 审，Codex 写的交给 Claude 审
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then REVIEW=(codex exec --sandbox read-only); else REVIEW=(claude -p); fi
m=$(cat .northstar/missions/ACTIVE); MF=".northstar/missions/$m.md"
GD=$(git rev-parse --git-dir); CTR="$GD/northstar-drift-count"; LAST="$GD/northstar-drift-last"
notify() { osascript -e "display notification \"$1\" with title \"NORTHSTAR\"" 2>/dev/null || true; }
KEEP=(-- . ':!proposals' ':!drafts' ':!status')

# 这次要提交的改动：有暂存就看暂存，否则（git commit -a）看全部未提交改动
if git diff --cached --quiet; then DIFF=(git diff HEAD); else DIFF=(git diff --cached); fi
nf=$("${DIFF[@]}" --name-only | wc -l | tr -d ' ')
[ "$nf" -le "$MAXF" ] || { echo "NORTHSTAR：这次要提交 $nf 个文件，超过 $MAXF 个。按验收标准拆成更小的提交。" >&2; exit 2; }

prev=$(cat "$LAST" 2>/dev/null)
prompt="$(cat .northstar/NORTHSTAR.md "$MF")
=== 待提交的改动 ===
$("${DIFF[@]}" --stat --patch | head -c 60000)

你是独立评审，只依据上面的 NORTHSTAR、mission 和待提交的改动判断：这些改动是否在推进 mission 的验收标准，且没有违反任何条款、非目标或停止条件？${prev:+上一次被判定偏离的原因是：$prev。请特别确认它已经消除。}
第一行只输出 ALIGNED 或 DRIFT。若 DRIFT，第二行写违反的条款编号和原因，第三行写涉及的文件和行号。"
out=$("${REVIEW[@]}" "$prompt" 2>/dev/null)
v=$(grep -m1 -oE '^(ALIGNED|DRIFT)' <<<"$out")
[ -n "$v" ] || { echo "NORTHSTAR：对齐评审没有返回结果。稍后重试提交；持续失败就停止并告诉用户。" >&2; exit 2; }
[ "$v" = DRIFT ] || { rm -f "$CTR" "$LAST"; exit 0; }      # 通过：连续偏离计数清零

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
