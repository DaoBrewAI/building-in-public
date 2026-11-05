#!/usr/bin/env bash
# /opt/northstar/hooks/inject.sh —— SessionStart：新会话、恢复、压缩后都重新注入原文
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -d .northstar ] || exit 0
cat >/dev/null
echo "=== NORTHSTAR（原文，不得转述、不得修改）==="
cat .northstar/NORTHSTAR.md
if [ -f .northstar/missions/ACTIVE ]; then
  m=$(cat .northstar/missions/ACTIVE)
  echo; echo "=== 当前 MISSION：$m ==="; cat ".northstar/missions/$m.md"
fi
echo; echo "规则：引用目标写 [N#] + 原文；commit 首行以 [N#] 开头；目标需要调整时写 proposals/ 并停止。"
/opt/northstar/bin/northstar verify >/dev/null 2>&1 || echo "⚠️ NORTHSTAR 签名校验失败：不要开始工作，先通知用户。"
