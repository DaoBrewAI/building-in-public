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
# 写入类命令按“整个命令词”匹配：node_modules、platform、perlman 这类普通单词不算；/bin/rm、xargs rm 照样算
WRITE='>|(^|[^[:alnum:]_.-])(tee|mv|cp|rm|ln|chmod|chflags|truncate|perl|node|ruby|python[0-9.]*)([[:space:]]|$)|sed[[:space:]]+-i|git[[:space:]]+(checkout|restore|reset|rm|mv)'
tool=$(jq -r '.tool_name // empty' <<<"$payload")
# 写文件类工具要写的路径，一行一个（apply_patch 包括 Move to 的目标）
files="$(jq -r '.tool_input | (.file_path // empty), (.notebook_path // empty)' <<<"$payload" 2>/dev/null)
$(grep -oE '\*\*\* ((Add|Update|Delete) File|Move to): [^\\"]+' <<<"$payload" | sed -E 's/^\*\*\* [^:]+: //')"
files="$(grep -v '^$' <<<"$files")"
case "$tool" in
  Bash|shell|exec_command|local_shell)
    cmd=$(jq -r '.tool_input.command | if type=="array" then join(" ") else (. // "") end' <<<"$payload" 2>/dev/null || echo "$payload")
    grep -qE "$BYPASS" <<<"$cmd" && deny "禁止签名或绕过校验的命令"
    # 受保护文件只读：丢到 /dev/null、2>&1 这类重定向不算写入
    wcmd=$(sed -E 's#(&|[0-9]*)>>?[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9-]+##g' <<<"$cmd")
    grep -qE "$PROTECTED" <<<"$cmd" && grep -qE "$WRITE" <<<"$wcmd" && deny "禁止用命令写入受保护文件" ;;
  *)  # 写文件类工具：Edit / Write / MultiEdit / NotebookEdit / apply_patch
    # 只看要写的路径，不看内容：普通文件里提到受保护路径不算；认不出路径时才退回整段匹配
    grep -qE "$PROTECTED" <<<"${files:-$payload}" && deny "禁止修改受保护文件" ;;
esac

# —— 范围围栏与停止条件（只对写文件类工具）——
if [ "$tool" != Bash ] && [ -f .northstar/missions/ACTIVE ]; then
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
