#!/usr/bin/env bash
# tests/sandbox.sh —— 安装前自己动手试：bash docs/orc/northstar-staging/tests/sandbox.sh
# 在临时目录里搭一个已签名、mission m1 进行中的产品仓库，进入一个子 shell。
# 和功能测试一样：不需要 sudo，不碰 /opt/northstar、Secretive、你的 git 全局配置；exit 后全部删除。
source "$(dirname "$0")/lib.sh"
setup_env; trap teardown_env EXIT
export T ROOT

new_repo; northstar init >/dev/null
printf '# NORTHSTAR — sandbox\n## 目标\n- N1: core 模块返回 42\n' > drafts/NORTHSTAR.md
printf '{"components":[{"id":"core","name":"Core","paths":["src/core/*"]},{"id":"ui","name":"UI","paths":["src/ui/*"]}]}\n' > drafts/architecture.json
printf '# MISSION: m1\n服务的条款: N1\nscope: core\nforbid: db/migrations/*, package.json\n\n## 验收标准（必须可验证）\n- [ ] core 模块返回 42\n' > drafts/missions/m1.md
tty_run SEAL northstar start m1 >/dev/null || { echo "沙盒初始化失败"; exit 1; }
git add -A && git commit -qm "[NS] start m1"
mkdir -p src/core src/ui
echo ALIGNED > "$T/verdict"

cat > "$T/rc" <<'EOF'
PS1='[northstar 沙盒] \W $ '
# 把一次工具调用交给 hook 判断（只判断，不真的执行）
_judge() {
  local hook="$1" payload="$2" out rc
  out=$(printf '%s' "$payload" | "$ROOT/hooks/$hook" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then echo "→ 放行（$hook）"; else echo "→ 拦下（$hook，退出码 $rc）"; fi
  [ -n "$out" ] && sed 's/^/   /' <<<"$out"
  return $rc
}
# agent-write <文件> [内容]：agent 用 Write 工具写这个文件
agent-write() {
  _judge guard.sh "$(jq -nc --arg f "$1" --arg c "${2:-x}" '{tool_name:"Write",tool_input:{file_path:$f,content:$c}}')"
}
# agent-bash '<命令>'：agent 用 Bash 工具运行这条命令；含 git commit 时再过对齐评审
agent-bash() {
  local p; p=$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')
  _judge guard.sh "$p" || return
  grep -qE 'git[[:space:]]+commit' <<<"$1" && _judge align.sh "$p"
}
# agent-stop：agent 想结束本轮
agent-stop() { _judge stop-gate.sh '{}'; }
# review-says aligned|drift：设定假评审的下一次结论
review-says() {
  case "$1" in
    aligned) echo ALIGNED > "$T/verdict" ;;
    drift)   printf 'DRIFT\nN1：改动和 core 返回 42 无关\nsrc/core/a.py:1\n' > "$T/verdict" ;;
    *) echo "用法：review-says aligned|drift"; return 1 ;;
  esac
  echo "假评审下一次返回：$1"
}
ns-help() { cat <<'HELP'
这是一个临时的产品仓库：NORTHSTAR 已签名，mission m1 进行中（scope: core，forbid: db/migrations/*、package.json）。
签名用的是临时密钥，不弹 Touch ID。northstar 命令可以直接用，比如 northstar verify。

模拟 agent 的操作（只判断会不会被拦，不真的执行）：
  agent-write .northstar/NORTHSTAR.md          改受保护文件          → 拦下
  agent-write src/core/a.py 'x = 42'           mission 范围内        → 放行
  agent-write src/ui/b.py 'x'                  越界                  → 拦下，附验收标准原文
  agent-write db/migrations/1.sql 'x'          停止条件              → 拦下，要求写 proposal
  agent-bash 'northstar seal'                  agent 自己签名        → 拦下
  agent-bash 'cat .northstar/NORTHSTAR.md'     只读                  → 放行
  agent-bash 'rm -rf .northstar'               用命令删受保护文件    → 拦下
  agent-bash 'git commit --no-verify -m x'     绕过 hook             → 拦下
  agent-stop                                   想结束本轮            → 按 stop-gate 判断

对齐评审（假评审，不调用真实模型）：
  echo 42 > src/core/a.py; git add src/core/a.py
  review-says drift;   agent-bash 'git commit -m "[N1] core"'   → 拦下，打印纠偏单
  review-says aligned; agent-bash 'git commit -m "[N1] core"'   → 放行（只判断，要真提交就自己运行 git commit）

你自己的操作（真的执行）：
  echo x >> .northstar/NORTHSTAR.md; northstar verify   篡改后签名校验失败
  git checkout .northstar; northstar verify             恢复后通过

ns-help 再看一遍；exit 退出并删除整个沙盒。
HELP
}
cd "$R"; ns-help
EOF

echo "沙盒：$R"
bash --noprofile --rcfile "$T/rc" -i
