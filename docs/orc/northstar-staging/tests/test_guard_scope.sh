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

begin "guard：orc 的 mission 状态目录（\$ORC_HOME，默认 ~/.orc）只能由 orc 自己写"
export ORC_HOME="$T/orc-home"; OH="$ORC_HOME"; mkdir -p "$OH/missions/t1"
for with_ns in no yes; do
  new_repo; [ "$with_ns" = yes ] && { mkdir -p .northstar; echo x > .northstar/NORTHSTAR.md; }
  guard "$(write_p Write "$OH/missions/t1/events.jsonl")"; expect_rc 2 "拦截 Write \$ORC_HOME 下的文件（仓库有 .northstar：$with_ns）"
  expect_out "只能由 orc 命令改写" "说明为什么拦（仓库有 .northstar：$with_ns）"
  guard "$(write_p Edit "$OH/missions/t1/state")";        expect_rc 2 "拦截 Edit \$ORC_HOME 下的文件（仓库有 .northstar：$with_ns）"
  guard "$(patch_p $'*** Begin Patch\n*** Update File: '"$OH"$'/missions/t1/state\n@@\n-planning\n+accepted\n*** End Patch')"
  expect_rc 2 "拦截 apply_patch 改 \$ORC_HOME 下的文件（仓库有 .northstar：$with_ns）"
  for c in "echo x >> $OH/missions/t1/events.jsonl" 'echo x >> $ORC_HOME/missions/t1/events.jsonl' \
           'echo x >> ${ORC_HOME}/missions/t1/events.jsonl' 'echo x >> ~/.orc/missions/t1/events.jsonl' \
           'rm -rf $HOME/.orc/missions/t1' "python3 -c \"open('$OH/missions/t1/state','w')\""; do
    guard "$(bash_p "$c")"; expect_rc 2 "拦截（仓库有 .northstar：$with_ns）：$c"
  done
  for c in "cat $OH/missions/t1/events.jsonl" 'tail -n 5 ~/.orc/missions/t1/events.jsonl 2>/dev/null' \
           'orc step --mission t1' 'orc answer "继续"' 'orc status'; do
    guard "$(bash_p "$c")"; expect_rc 0 "放行（仓库有 .northstar：$with_ns）：$c"
  done
  guard "$(write_p Write "$PWD/src/a.py")"; expect_rc 0 "放行普通文件（仓库有 .northstar：$with_ns）"
done
run_in "$(write_p Write "$T/h/.orc/missions/t1/state")" env -u ORC_HOME HOME="$T/h" "$G"
expect_rc 2 "没设 ORC_HOME 时保护默认的 ~/.orc"

begin "guard：节点 worktree（默认 ~/.orc-worktrees）里写代码放行，mission 状态照样拦"
# 节点 worktree 不在 $ORC_HOME 下（STATE.md）；guard 不给任何路径开例外，只是按整段路径匹配，.orc-worktrees 不算 .orc
H="$T/h"; WT="$H/.orc-worktrees/t1/n1"; mkdir -p "$WT" "$H/.orc/missions/t1"
git init -q "$WT"; cd "$WT"
hg() { run_in "$1" env -u ORC_HOME HOME="$H" "$G"; }
hg "$(write_p Write "$WT/src/a.py")";                     expect_rc 0 "worktree 里 Write 代码文件放行"
hg "$(write_p Edit "$WT/README.md")";                     expect_rc 0 "worktree 里 Edit 放行"
hg "$(patch_p $'*** Begin Patch\n*** Add File: '"$WT"$'/src/b.py\n+x\n*** End Patch')"; expect_rc 0 "worktree 里 apply_patch 放行"
for c in "echo x > src/a.py" "echo x > $WT/src/a.py" 'echo x > ~/.orc-worktrees/t1/n1/a.py' 'rm -f $HOME/.orc-worktrees/t1/n1/tmp.txt'; do
  hg "$(bash_p "$c")"; expect_rc 0 "worktree 里放行：$c"
done
hg "$(write_p Write "$H/.orc/missions/t1/events.jsonl")"; expect_rc 2 "在 worktree 里写 mission 状态文件照样拦"
hg "$(bash_p "echo x >> $H/.orc/missions/t1/events.jsonl")"; expect_rc 2 "在 worktree 里用命令写 mission 状态照样拦"
hg "$(bash_p 'echo x >> ~/.orc/missions/t1/events.jsonl')"; expect_rc 2 "在 worktree 里用 ~/.orc 写 mission 状态照样拦"
cd "$T"
unset ORC_HOME

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
# .northstar 下只读：读的时候丢掉输出或合并 stderr 不算写
for c in 'cat .northstar/NORTHSTAR.md 2>/dev/null' 'ls .northstar >/dev/null 2>&1' \
         'grep -r N1 .northstar &>/dev/null' 'cat .northstar/NORTHSTAR.md 2>&1 | head' 'cat .northstar/x 2> /dev/null'; do
  guard "$(bash_p "$c")"; expect_rc 0 "放行（只读）：$c"
done
# 读命令里出现含 node / rm / cp 等字母的普通单词，不算写（Codex 实测：rg -g '!node_modules' 被误拦）
for c in "rg --files -g '.northstar/**' -g '!node_modules' --hidden" 'ls platform .northstar' \
         'grep -r perlman .northstar' 'cat .northstar/NORTHSTAR.md | wc -l'; do
  guard "$(bash_p "$c")"; expect_rc 0 "放行（只读）：$c"
done
for c in 'echo x > .northstar/a 2>/dev/null' 'cat a 2>/dev/null > .northstar/b' 'echo x >> .northstar/a 2>&1' \
         'echo x 2>/dev/null >.northstar/a' '/bin/rm .northstar/NORTHSTAR.md' 'node -e "1" .northstar/x' \
         'python3.11 -c "open(\".northstar/t\",\"w\")"' 'find .northstar -type f | xargs rm' 'truncate -s0 .northstar/NORTHSTAR.md'; do
  guard "$(bash_p "$c")"; expect_rc 2 "拦截（重定向写进 .northstar）：$c"
done
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
guard "$(write_p MultiEdit "$PWD/.github/workflows/ci.yml")"; expect_rc 2 "拦截 MultiEdit .github/workflows/ci.yml"
guard "$(patch_p $'*** Begin Patch\n*** Update File: src/a.py\n*** Move to: .northstar/x\n@@\n-a\n+b\n*** End Patch')"
expect_rc 2 "拦截 apply_patch 把文件移到 .northstar/"
# 只看要写的文件路径，不看内容：普通文件里提到受保护路径不拦
guard "$(jq -nc '{tool_name:"Write",tool_input:{file_path:"src/a.py",content:"# 读取 .northstar/architecture.json\nx = 42"}}')"
expect_rc 0 "放行：Write 普通文件，内容提到 .northstar/"
guard "$(jq -nc '{tool_name:"Edit",tool_input:{file_path:"docs/ci.md",old_string:"a",new_string:"见 .github/workflows/ci.yml 和 status/STATUS.md"}}')"
expect_rc 0 "放行：Edit 普通文件，内容提到受保护路径"
guard "$(patch_p $'*** Begin Patch\n*** Update File: src/a.py\n@@\n-a\n+path = \".northstar/NORTHSTAR.md\"\n*** End Patch')"
expect_rc 0 "放行：apply_patch 改普通文件，内容提到 .northstar/"

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

begin "orc mission：范围来自签名的 control 目录（ORC_MISSION_CONTROL），不用 ACTIVE"
new_repo; write_mission_fixture; rm .northstar/missions/ACTIVE
# 两个 mission 的 control 目录：brief-exec.md 里写范围，approved.sha256 记它的哈希，用测试密钥按 northstar-mission 签名
make_control() {   # make_control <mission> <scope> <forbid>
  local c="$T/missions/$1/control"; mkdir -p "$c"
  printf '# 执行规则：mission %s\n\n## mission 的范围\n\nscope: %s\nforbid: %s\n' "$1" "$2" "$3" > "$c/brief-exec.md"
  printf 'x\n' > "$c/approved-design.md"
  ( cd "$c" && shasum -a 256 approved-design.md brief-exec.md > approved.sha256 )
  ssh-keygen -Y sign -n northstar-mission -f "$T/key" "$c/approved.sha256" >/dev/null 2>&1
  echo "$c"
}
C1=$(make_control m-core core package.json)
C2=$(make_control m-ui ui "src/core/*")
export ORC_MISSION_CONTROL="$C1"
run northstar-scope src/core/a.py;                 expect_rc 0 "签名的 control：范围内返回 0（没有 ACTIVE）"
run northstar-scope src/ui/b.py;                   expect_rc 1 "签名的 control：越界返回 1"
expect_out "当前 mission「m-core」只允许改：core" "越界信息里是 orc 的 mission 名"
run northstar-scope package.json;                  expect_rc 3 "签名的 control：forbid 返回 3"
guard "$(write_p Write "$PWD/src/ui/b.py")";       expect_rc 2 "guard：orc 执行会话越界写入被拦"
expect_out "只改你这个节点的声明文件" "guard：orc 会话的纠偏提示"
guard "$(write_p Write "$PWD/package.json")";      expect_rc 2 "guard：orc 执行会话碰到 forbid 被停下"
expect_out "NORTHSTAR 停止条件" "guard：停止条件信息"
guard "$(write_p Write "$PWD/src/core/a.py")";     expect_rc 0 "guard：orc 执行会话范围内写入放行"
export ORC_MISSION_CONTROL="$C2"
run northstar-scope src/ui/b.py;                   expect_rc 0 "同一个仓库里另一个 mission 用它自己的范围（并行）"
run northstar-scope src/core/a.py;                 expect_rc 3 "另一个 mission 的 forbid 生效"
echo "scope: core, ui" >> "$C2/brief-exec.md"
run northstar-scope src/ui/b.py;                   expect_rc 3 "brief-exec.md 被改过（哈希不符）：停下"
expect_out "签名或哈希校验失败" "说明校验失败"
C3=$(make_control m-unsigned core ""); rm "$C3/approved.sha256.sig"
export ORC_MISSION_CONTROL="$C3"
run northstar-scope src/core/a.py;                 expect_rc 3 "control 没有签名：停下"
ssh-keygen -Y sign -n northstar -f "$T/key" "$C3/approved.sha256" >/dev/null 2>&1
run northstar-scope src/core/a.py;                 expect_rc 3 "签名的命名空间不是 northstar-mission：停下"
unset ORC_MISSION_CONTROL
guard "$(write_p Write "$PWD/.northstar/architecture.json")"; expect_rc 2 "签名后的画布 agent 改不了（Write）"
guard "$(bash_p 'echo {} > .northstar/architecture.json')";  expect_rc 2 "签名后的画布 agent 改不了（Bash）"
guard "$(write_p Write "$PWD/drafts/architecture.json")";    expect_rc 0 "画布草稿写在 drafts/ 放行"
run northstar-scope src/ui/b.py package.json;      expect_rc 0 "不带 ORC_MISSION_CONTROL、也没有 ACTIVE 时不设围栏"

summary
