#!/usr/bin/env bash
# hooks/guard.sh 的拦截与放行；bin/northstar-scope 的三种返回值
source "$(dirname "$0")/lib.sh"
setup_env; trap teardown_env EXIT
G="$ROOT/hooks/guard.sh"

# 伪造的 hook 输入（字段与 Claude Code / Codex 的 PreToolUse 输入一致）
bash_p()  { jq -nc --arg c "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:env.PWD,tool_input:{command:$c}}'; }
codex_p() { jq -nc --arg c "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:["bash","-lc",$c]}}'; }
write_p() { jq -nc --arg t "$1" --arg f "$2" '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:{file_path:$f,content:"x"}}'; }
patch_p() { jq -nc --arg p "$1" '{hook_event_name:"PreToolUse",tool_name:"apply_patch",tool_input:{command:$p}}'; }
guard()   { run_in "$1" "$G"; }

begin "guard：没有 .northstar 的仓库一律放行"
new_repo
guard "$(bash_p 'northstar seal')";               expect_rc 0 "无 .northstar 时不拦截"
guard "$(write_p Write "$PWD/.northstar/x")";     expect_rc 0 "无 .northstar 时写入放行"

begin "guard：签名与绕过类命令"
new_repo; mkdir -p .northstar; echo x > .northstar/NORTHSTAR.md
for c in 'northstar seal' 'northstar start m1' 'northstar finish' 'northstar approve-mission /tmp/c' \
         '/opt/northstar/bin/northstar  seal' 'ssh-keygen -Y sign -n northstar -f k f' \
         'git commit --no-verify -m x' 'git config --global core.hooksPath /tmp/h'; do
  guard "$(bash_p "$c")"; expect_rc 2 "拦截：$c"
done
expect_out "禁止签名或绕过校验的命令" "拦截原因写明"
expect_out "proposals/" "拦截信息告诉 agent 该怎么做"
guard "$(codex_p 'northstar seal')";      expect_rc 2 "拦截 Codex 数组形式的命令"
for c in 'northstar verify' 'northstar init' 'northstar verify-mission /tmp/c' 'ls -la' 'git status'; do
  guard "$(bash_p "$c")"; expect_rc 0 "放行：$c"
done

begin "guard：用命令写受保护文件"
for c in 'echo hi > .northstar/test' 'tee .northstar/test' 'cp a .northstar/NORTHSTAR.md' \
         'rm -rf .northstar/' 'sed -i "" s/a/b/ .github/workflows/x.yml' \
         'mv x .claude/settings.json' 'python3 -c "open(\".northstar/t\",\"w\")"' \
         'git checkout -- .northstar/NORTHSTAR.md' 'echo x > status/status.json' 'cp k /opt/northstar/allowed_signers'; do
  guard "$(bash_p "$c")"; expect_rc 2 "拦截：$c"
done
for c in 'rm -rf .northstar' 'mv .northstar /tmp/x' 'git rm -r .northstar' 'cp -r /tmp/evil .northstar' \
         'chmod -R 777 .northstar' 'rm -r .github/workflows' 'mv .northstar.bak .northstar'; do
  guard "$(bash_p "$c")"; expect_rc 2 "拦截（目录本身，不带 /）：$c"
done
guard "$(codex_p 'echo hi > .northstar/test')"; expect_rc 2 "拦截 Codex 的写入命令"
for c in 'cat .northstar/NORTHSTAR.md' 'ls .github/workflows' 'echo ok > src/a.py' 'git diff -- .northstar'; do
  guard "$(bash_p "$c")"; expect_rc 0 "放行：$c"
done

begin "guard：写文件类工具"
for f in .northstar/test .github/workflows/ci.yml .claude/settings.json status/STATUS.md; do
  guard "$(write_p Write "$PWD/$f")"; expect_rc 2 "拦截 Write：$f"
done
guard "$(write_p Edit "$PWD/.northstar/NORTHSTAR.md")";  expect_rc 2 "拦截 Edit .northstar/NORTHSTAR.md"
guard "$(write_p NotebookEdit "$PWD/.northstar/a.ipynb")"; expect_rc 2 "拦截 NotebookEdit"
guard "$(patch_p $'*** Begin Patch\n*** Add File: .northstar/x\n+hi\n*** End Patch')"; expect_rc 2 "拦截 apply_patch 新增 .northstar/x"
guard "$(write_p Write "$PWD/src/a.py")";   expect_rc 0 "无进行中 mission 时任意普通文件放行"

begin "guard：mission 范围围栏与停止条件"
new_repo; write_mission_fixture
guard "$(write_p Write "$PWD/src/core/a.py")";   expect_rc 0 "范围内写入放行"
guard "$(write_p Write "$PWD/drafts/x.md")";     expect_rc 0 "drafts/ 总是放行"
guard "$(write_p Write "$PWD/proposals/p.md")";  expect_rc 0 "proposals/ 总是放行"
guard "$(write_p Write "$PWD/src/ui/b.py")"
expect_rc 2 "越界写入被拦"
expect_out "NORTHSTAR 纠偏" "越界时给出纠偏"
expect_out "core 模块返回 42" "纠偏附上验收标准原文"
guard "$(write_p Write "$PWD/package.json")"
expect_rc 2 "触发停止条件被拦"
expect_out "NORTHSTAR 停止条件" "停止条件信息"
guard "$(write_p Write "$PWD/db/migrations/001.sql")"; expect_rc 2 "glob 形式的停止条件生效"
guard "$(patch_p $'*** Begin Patch\n*** Update File: src/ui/b.py\n@@\n-a\n+b\n*** End Patch')"; expect_rc 2 "apply_patch 越界被拦"
guard "$(patch_p $'*** Begin Patch\n*** Update File: src/core/a.py\n@@\n-a\n+b\n*** End Patch')"; expect_rc 0 "apply_patch 范围内放行"
guard "$(bash_p 'echo x > src/ui/b.py')";        expect_rc 0 "Bash 不走范围围栏（由 stop-gate 和 broker 兜底）"

begin "northstar-scope：三种返回值"
new_repo
run northstar-scope src/ui/b.py;                   expect_rc 0 "没有 .northstar 时返回 0"
write_mission_fixture
run northstar-scope src/core/a.py;                 expect_rc 0 "范围内返回 0"
run northstar-scope src/core/a.py src/ui/b.py;     expect_rc 1 "越界返回 1"
expect_out "越界：src/ui/b.py" "列出越界文件"
expect_out "只允许改：core" "说明允许的组件"
run northstar-scope src/core/a.py package.json;    expect_rc 3 "停止条件返回 3"
expect_out "触发停止条件：package.json" "列出触发停止条件的文件"
run northstar-scope db/migrations/001.sql;         expect_rc 3 "glob 停止条件返回 3"
run northstar-scope "$PWD/src/core/a.py";          expect_rc 0 "接受绝对路径"
run northstar-scope status/narrative.md proposals/p.md drafts/m.md; expect_rc 0 "说明、提案、草稿始终允许"
mkdir -p src/core; cd src/core; run northstar-scope src/core/a.py; cd "$R"
expect_rc 0 "在子目录运行时按仓库根解析"
rm .northstar/missions/ACTIVE
run northstar-scope src/ui/b.py package.json;      expect_rc 0 "没有进行中的 mission 时返回 0"
echo m1 > .northstar/missions/ACTIVE; sed -i '' 's/^scope:.*/scope:/' .northstar/missions/m1.md
run northstar-scope src/ui/b.py;                   expect_rc 0 "mission 没写 scope 时不设围栏"
run northstar-scope package.json;                  expect_rc 3 "没写 scope 时停止条件仍生效"
sed -i '' 's/^scope:.*/scope: core/; s/^forbid:.*/forbid:/' .northstar/missions/m1.md
run northstar-scope src/core/a.py;                 expect_rc 0 "forbid 为空时不吞下一行"
run northstar-scope src/ui/b.py;                   expect_rc 1 "forbid 为空时 scope 仍生效"

summary
