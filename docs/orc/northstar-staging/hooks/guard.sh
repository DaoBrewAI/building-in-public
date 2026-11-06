#!/usr/bin/env bash
# /opt/northstar/hooks/guard.sh —— PreToolUse，Claude Code 与 Codex 共用
# 文本匹配：挡得住误操作，挡不住刻意绕过；真正的保证在签名和 CI
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -d .northstar ] || exit 0
payload=$(cat)
deny() { echo "NORTHSTAR 保护：$1。目标需要调整时，把提案写进 proposals/ 并停止，等待人工处理。" >&2; exit 2; }
# 目录名后面不要求 /：rm -rf .northstar、mv .northstar x 也要拦
PROTECTED='\.northstar([^[:alnum:]_-]|$)|\.github/workflows([^[:alnum:]_-]|$)|/opt/northstar|allowed_signers|managed-settings|\.codex/hooks|\.claude/settings|status/status\.json|status/STATUS\.md'
BYPASS='northstar[[:space:]]+(seal|start|finish|approve-mission)|ssh-keygen.*-Y[[:space:]]*sign|--no-verify|core\.hooksPath'
WRITE='>|tee[[:space:]]|mv[[:space:]]|cp[[:space:]]|rm[[:space:]]|sed[[:space:]]+-i|chmod|chflags|truncate|ln[[:space:]]|python|perl|node|ruby|git[[:space:]]+(checkout|restore|reset|rm|mv)'
tool=$(jq -r '.tool_name // empty' <<<"$payload")
case "$tool" in
  Bash|shell|exec_command|local_shell)
    cmd=$(jq -r '.tool_input.command | if type=="array" then join(" ") else (. // "") end' <<<"$payload" 2>/dev/null || echo "$payload")
    grep -qE "$BYPASS" <<<"$cmd" && deny "禁止签名或绕过校验的命令"
    grep -qE "$PROTECTED" <<<"$cmd" && grep -qE "$WRITE" <<<"$cmd" && deny "禁止用命令写入受保护文件" ;;
  *)  # 写文件类工具：Edit / Write / MultiEdit / NotebookEdit / apply_patch
    grep -qE "$PROTECTED" <<<"$payload" && deny "禁止修改受保护文件" ;;
esac

# —— 范围围栏与停止条件（只对写文件类工具）——
if [ "$tool" != Bash ] && [ -f .northstar/missions/ACTIVE ]; then
  files="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$payload")"
  files="$files $(grep -oE '\*\*\* (Add|Update|Delete) File: [^\\"]+' <<<"$payload" | sed 's/.*File: //')"
  msg=$(/opt/northstar/bin/northstar-scope $files 2>&1); rc=$?
  m=$(cat .northstar/missions/ACTIVE)
  if [ $rc -eq 3 ]; then
    echo "NORTHSTAR 停止条件：$msg。立即停止实现，在 proposals/ 写明原因，然后结束。" >&2; exit 2
  elif [ $rc -ne 0 ]; then
    { echo "NORTHSTAR 纠偏：$msg"; echo "回到 mission 的验收标准（原文）："
      sed -n '/^## 验收标准/,/^## [^验]/p' ".northstar/missions/$m.md"; } >&2
    exit 2
  fi
fi
exit 0
