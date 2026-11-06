#!/usr/bin/env bash
# hooks/align.sh：评审命令换成假脚本（$T/verdict 决定返回 ALIGNED / DRIFT）
source "$(dirname "$0")/lib.sh"
setup_env; trap teardown_env EXIT
A="$ROOT/hooks/align.sh"

commit_p() { jq -nc --arg c "${1:-git commit -m \"[N1] x\"}" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}'; }
align()    { run_in "$(commit_p "${1:-}")" "$A"; }
verdict()  { printf '%s\n' "$@" > "$T/verdict"; }
DRIFT=(DRIFT "N1：改动与 core 返回 42 无关" "src/core/a.py:1")

setup_mission_repo() {
  new_repo; write_mission_fixture
  mkdir -p src/core; echo 1 > src/core/a.py
  git add -A && git commit -qm "[NS] start m1"
  GD=$(git rev-parse --git-dir); rm -f "$T/reviewer-calls"
}

begin "不需要评审的情况"
new_repo
verdict "${DRIFT[@]}"
align;                                   expect_rc 0 "没有进行中的 mission 时放行"
setup_mission_repo
run_in "$(commit_p 'git status')" "$A";   expect_rc 0 "不是 git commit 的命令放行"
expect_true '[ ! -f "$T/reviewer-calls" ]' "放行时没有调用评审"

begin "文件数上限"
for i in 1 2 3 4 5 6 7 8 9; do echo "$i" > "src/core/f$i.py"; done
git add src/core
align
expect_rc 2 "一次提交 9 个文件被拒"
expect_out "超过 8 个" "提示按验收标准拆小"
git reset -q; rm src/core/f*.py

begin "ALIGNED"
echo 42 > src/core/a.py; git add src/core/a.py
echo 1 > "$GD/northstar-drift-count"; echo old > "$GD/northstar-drift-last"
verdict ALIGNED
align
expect_rc 0 "ALIGNED 放行"
expect_true '[ ! -f "$GD/northstar-drift-count" ] && [ ! -f "$GD/northstar-drift-last" ]' "ALIGNED 后连续偏离计数清零"
expect_true 'grep -q "原文条款一" "$T/last-prompt" && grep -q "core 模块返回 42" "$T/last-prompt"' "评审看到 NORTHSTAR 和 mission 原文"
expect_true 'grep -q "^+42" "$T/last-prompt"' "评审看到暂存的 diff"

begin "评审出错时不放行"
verdict "我觉得还行"
align
expect_rc 2 "评审没有给出 ALIGNED/DRIFT 时拒绝"
expect_out "对齐评审没有返回结果" "提示评审没有结果"
rm -f "$T/verdict"
align
expect_rc 2 "评审没有输出时拒绝"

begin "交叉评审：谁写的交给另一家审"
verdict ALIGNED; rm -f "$T/reviewer-calls"
CLAUDE_PROJECT_DIR="$PWD" run_in "$(commit_p)" "$A"
expect_true '[ "$(cat "$T/reviewer-calls")" = codex ]' "Claude Code 提交时调用 codex 评审"
rm -f "$T/reviewer-calls"; align
expect_true '[ "$(cat "$T/reviewer-calls")" = claude ]' "Codex 提交时调用 claude 评审"

begin "DRIFT 第 1 次：拒绝并发纠偏单"
verdict "${DRIFT[@]}"
align
expect_rc 2 "DRIFT 拒绝提交"
expect_out "NORTHSTAR 纠偏 · mission m1 · 连续第 1 次" "纠偏单标题"
expect_out "N1：改动与 core 返回 42 无关" "纠偏单带违反条款"
expect_out "src/core/a.py:1" "纠偏单带证据"
expect_out "core 模块返回 42" "纠偏单带验收标准原文"
expect_true '[ "$(cat "$GD/northstar-drift-count")" = 1 ]' "计数为 1"
expect_true 'git diff --cached --quiet; [ $? -ne 0 ]' "第 1 次不动工作区"

begin "DRIFT 第 2 次：stash 回到上一次通过评审的状态"
align
expect_rc 2 "第 2 次仍拒绝"
expect_out "连续第 2 次" "纠偏单写明第 2 次"
expect_out "上一次通过评审的状态" "告诉 agent 工作区已回退"
expect_true 'grep -q "上一次被判定偏离的原因是：N1：改动与 core 返回 42 无关" "$T/last-prompt"' "第 2 次评审带上上次偏离的原因"
expect_true '[ -z "$(git status --porcelain -- src)" ]' "工作区回到 HEAD"
expect_true 'git stash list | grep -q "northstar-drift-m1-2"' "改动保存在 northstar-drift-m1-2"

begin "DRIFT 第 3 次：熔断"
echo 43 > src/core/a.py; git add src/core/a.py
align
expect_rc 2 "第 3 次拒绝"
expect_out "熔断" "输出熔断"
expect_out "proposals/" "熔断时要求写提案"
expect_true '[ "$(cat "$GD/northstar-drift-count")" = 3 ]' "计数为 3"

begin "通过一次后计数清零"
echo 42 > src/core/a.py; git add src/core/a.py
verdict ALIGNED
align
expect_rc 0 "ALIGNED 放行"
expect_true '[ ! -f "$GD/northstar-drift-count" ]' "计数清零"

begin "git add 和 git commit 写在同一条命令里"
setup_mission_repo
echo new > src/core/new.py
verdict ALIGNED
align 'git add src/core/new.py && git commit -m "[N1] new"'
expect_rc 2 "同一条命令里先 add 再 commit 被拒（评审看不到要提交的内容）"
expect_out "分成两条命令" "提示先单独 git add"
expect_true '[ ! -f "$T/reviewer-calls" ]' "被拒时没有调用评审"
align 'git commit -am "[N1] x"'
expect_rc 0 "git commit -a 仍然正常评审"

begin "worktree：每个 worktree 单独计数"
setup_mission_repo
git worktree add -q "$T/wt" -b node-a 2>/dev/null
cd "$T/wt"; echo 7 > src/core/a.py; git add src/core/a.py
verdict "${DRIFT[@]}"; align
WGD=$(git rev-parse --git-dir)
expect_true '[ "$(cat "$WGD/northstar-drift-count")" = 1 ] && [ ! -f "$GD/northstar-drift-count" ]' "偏离计数记在该 worktree 自己的 git 目录"
cd "$R"

summary
