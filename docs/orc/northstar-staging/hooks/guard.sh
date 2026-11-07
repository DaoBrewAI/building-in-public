#!/usr/bin/env bash
# /opt/northstar/hooks/guard.sh —— PreToolUse，Claude Code 与 Codex 共用
# 文本匹配：挡得住误操作，挡不住刻意绕过；真正的保证在签名和 CI
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
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
    # 只读不算写：丢到 /dev/null、2>&1 这类重定向去掉后再判断
    wcmd=$(sed -E 's#(&|[0-9]*)>>?[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9-]+##g' <<<"$cmd") ;;
esac

# —— orc 的 mission 状态（$ORC_HOME，默认 ~/.orc）只能由 orc 命令写。
#    不管当前仓库有没有 .northstar 都要拦：状态由 events.jsonl 推出，agent 改得了它就改得了 mission 走到哪一步
orc_home="${ORC_HOME:-$HOME/.orc}"; orc_home="${orc_home%/}"
orc_phys="$(cd "$orc_home" 2>/dev/null && pwd -P || echo "$orc_home")"
deny_orc() { echo "NORTHSTAR 保护：orc 的 mission 状态（$orc_home）只能由 orc 命令改写。用 orc step / orc answer，不要直接写这些文件。" >&2; exit 2; }
case "$tool" in
  Bash|shell|exec_command|local_shell)
    ORC_RE='(~|\$HOME|\$\{HOME\})/\.orc([/[:space:]"]|$)|\$ORC_HOME|\$\{ORC_HOME\}'
    if { grep -qE "$ORC_RE" <<<"$cmd" || grep -qF -e "$orc_home" -e "$orc_phys" <<<"$cmd"; } \
       && grep -qE "$WRITE" <<<"$wcmd"; then deny_orc; fi ;;
  *)
    if [ -z "$files" ]; then   # 认不出要写的路径：退回整段匹配
      grep -qF -e "$orc_home/" -e "$orc_phys/" <<<"$payload" && deny_orc
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in "~/"*) f="$HOME/${f#\~/}" ;; esac
      case "$f" in "$orc_home"|"$orc_home"/*|"$orc_phys"|"$orc_phys"/*) deny_orc ;; esac
    done <<<"$files" ;;
esac

[ -d .northstar ] || exit 0
case "$tool" in
  Bash|shell|exec_command|local_shell)
    grep -qE "$BYPASS" <<<"$cmd" && deny "禁止签名或绕过校验的命令"
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
