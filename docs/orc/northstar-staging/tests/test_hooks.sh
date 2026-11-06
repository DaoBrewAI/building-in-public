#!/usr/bin/env bash
# hooks/inject.sh、git/commit-msg、hooks/stop-gate.sh
source "$(dirname "$0")/lib.sh"
setup_env; trap teardown_env EXIT
SG="$ROOT/hooks/stop-gate.sh"; IJ="$ROOT/hooks/inject.sh"

# 签好名、有进行中 mission m1 的仓库
mission_repo() {
  new_repo; northstar init >/dev/null
  printf '# NORTHSTAR — test\n- N1: 原文条款一\n' > drafts/NORTHSTAR.md
  printf '{"components":[{"id":"core","name":"Core","paths":["src/core/*"]},{"id":"ui","name":"UI","paths":["src/ui/*"]}]}\n' > drafts/architecture.json
  printf '# MISSION: m1\nscope: core\n\n## 验收标准\n- [ ] core 返回 42\n' > drafts/missions/m1.md
  printf '#!/usr/bin/env bash\nset -e\n%s\n' "${1:-true}" > drafts/checks/run_all.sh
  tty_run SEAL northstar start m1 >/dev/null
  git add -A && git commit -qm "[NS] start m1"
  mkdir -p src/core status
}
narrate() { mkdir -p status; echo "- 说明 [commit:$(git log -1 --format=%h)] [file:src/core/a.py:1]" > status/narrative.md; }

begin "inject.sh"
new_repo
run_in '{}' "$IJ"; expect_true '[ -z "$OUT" ]' "没有 .northstar 时不注入"
mission_repo
run_in '{"hook_event_name":"SessionStart"}' "$IJ"
expect_rc 0 "注入成功"
expect_out "原文条款一" "注入 NORTHSTAR 原文"
expect_out "当前 MISSION：m1" "注入当前 mission"
expect_out "core 返回 42" "注入 mission 原文"
expect_true '! grep -q "签名校验失败" <<<"$OUT"' "签名正常时没有警告"
echo x >> .northstar/NORTHSTAR.md
run_in '{}' "$IJ"
expect_out "NORTHSTAR 签名校验失败" "受保护文件被改时警告不要开工"

begin "commit-msg"
new_repo
echo x > a; git add a
run git commit -qm "随便写"; expect_rc 0 "没有 .northstar 时不检查格式"
printf '#!/bin/sh\ngrep -q PROJECT-OK "$1" || { echo project-hook-rejected >&2; exit 1; }\n' > .git/hooks/commit-msg
chmod +x .git/hooks/commit-msg
echo y > a; git add a
run git commit -qm "[N1] 没有标记"; expect_rc 1 "没有 .northstar 时仍转发到项目自己的 hook"
expect_out "project-hook-rejected" "项目 hook 的输出可见"
rm .git/hooks/commit-msg
mkdir -p .northstar; echo n > .northstar/NORTHSTAR.md; git add -A
run git commit -qm "没有条款编号"; expect_rc 1 "缺少 [N#] 被拒"
expect_out "commit 首行必须以 [N#] 开头" "提示正确格式"
for m in "[N1] a" "[N1,N12] b" "[NS] c"; do
  echo "$m" >> a; git add a
  run git commit -qm "$m"; expect_rc 0 "接受：$m"
done
printf '#!/bin/sh\ngrep -q PROJECT-OK "$1" || { echo project-hook-rejected >&2; exit 1; }\n' > .git/hooks/commit-msg
chmod +x .git/hooks/commit-msg
echo z >> a; git add a
run git commit -qm "[N1] 格式对但项目 hook 不通过"; expect_rc 1 "有 .northstar 时也转发到项目 hook"
git worktree add -q "$T/wt-cm" -b cm 2>/dev/null; cd "$T/wt-cm"
echo w >> a; git add a
run git commit -qm "[N1] worktree 里提交"
expect_rc 1 "在 worktree 里同样转发到项目 hook（.git 是文件）"
expect_out "project-hook-rejected" "worktree 里项目 hook 生效"
run git commit -qm "[N1] PROJECT-OK"; expect_rc 0 "worktree 里格式和项目 hook 都通过时接受"
cd "$R"

begin "stop-gate.sh"
new_repo
run_in '{}' "$SG"; expect_rc 0 "没有 .northstar 时放行"
mission_repo
echo 42 > src/core/a.py; git add -A; git commit -qm "[N1] core 42"; narrate
run_in '{}' "$SG"; expect_rc 0 "签名正常、已提交、范围内、检查和进度报告通过时放行"
echo 43 > src/core/a.py
run_in '{}' "$SG"
expect_rc 2 "有未提交改动时拦下"
expect_out "还有未提交的改动" "提示先提交"
git checkout -q -- src/core/a.py
mkdir -p src/ui; echo ui > src/ui/b.py; git add -A; git commit -qm "[N1] 越界"; narrate
run_in '{}' "$SG"
expect_rc 2 "已提交的越界改动被拦下"
expect_out "越界：src/ui/b.py" "列出越界文件"
git reset -q --hard HEAD~1; narrate
echo x >> .northstar/NORTHSTAR.md
run_in '{}' "$SG"
expect_rc 0 "签名不一致时不让 agent 自己修，直接结束并通知用户"
git checkout -q -- .northstar/NORTHSTAR.md
rm status/narrative.md
run_in '{}' "$SG"
expect_rc 2 "进度报告不通过时拦下"
expect_out "缺少 status/narrative.md" "输出进度报告的问题"
for i in 2 3 4; do run_in '{}' "$SG"; done
expect_out "第 4 次" "连续失败计数"
run_in '{}' "$SG"; expect_rc 0 "连续 5 次失败后放行并通知用户"

begin "stop-gate.sh：并行的 worktree 不共用检查日志"
mission_repo 'sleep 1.5; echo A-FAIL-SHORT; exit 1'; RA="$R"
echo 42 > src/core/a.py; git add -A; git commit -qm "[N1] a"; narrate
mission_repo 'echo B-FAIL-A-MUCH-LONGER-MESSAGE-LINE-1; echo B-FAIL-LINE-2; exit 1'; RB="$R"
echo 42 > src/core/a.py; git add -A; git commit -qm "[N1] b"; narrate
( cd "$RA" && printf '{}' | "$SG" >"$T/outA" 2>&1 ) &
sleep 0.4
( cd "$RB" && printf '{}' | "$SG" >"$T/outB" 2>&1 )
wait
expect_true 'grep -q A-FAIL-SHORT "$T/outA" && ! grep -q "B-FAIL" "$T/outA"' "A 的结果里只有 A 的检查输出"
expect_true 'grep -q B-FAIL-LINE-2 "$T/outB" && ! grep -q "A-FAIL" "$T/outB"' "B 的结果里只有 B 的检查输出"

summary
