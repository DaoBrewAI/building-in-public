#!/usr/bin/env bash
# install.sh —— 由你执行：sudo bash install.sh（agent 不得执行）
# 把信任层装进 root 所有的 /opt/northstar，并注册 Claude Code / Codex / git 的 hook
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行"; exit 1; }
U="${SUDO_USER:?}"; UH=$(dscl . -read /Users/"$U" NFSHomeDirectory | awk '{print $2}')
S="$(cd "$(dirname "$0")" && pwd)"
[ -f "$S/northstar_signing.pub" ] || { echo "缺少 northstar_signing.pub（从 Secretive 复制公钥保存到这里）"; exit 1; }
[ -f "$S/allowed_signers" ] || echo "linhan namespaces=\"northstar,northstar-mission\" $(cat "$S/northstar_signing.pub")" > "$S/allowed_signers"
MODELS="$S/../../../orc/config/models.toml"   # 唯一写模型名的地方；提交前的对齐评审按它选模型
[ -f "$MODELS" ] || { echo "缺少 $MODELS（在 building-in-public 的 worktree 里运行 install.sh）"; exit 1; }

# 1. 工具包：root 所有，你和 agent 都只读
mkdir -p /opt/northstar/bin /opt/northstar/hooks /opt/northstar/git /opt/northstar/templates
cp "$S"/bin/* /opt/northstar/bin/
cp "$S"/hooks/*.sh /opt/northstar/hooks/
cp "$S"/git/commit-msg /opt/northstar/git/
cp "$S"/templates/*.md /opt/northstar/templates/
cp "$S"/allowed_signers "$S"/northstar_signing.pub /opt/northstar/
cp "$MODELS" /opt/northstar/models.toml
chown -R root:wheel /opt/northstar
chmod -R 755 /opt/northstar
chmod 644 /opt/northstar/allowed_signers /opt/northstar/northstar_signing.pub /opt/northstar/models.toml /opt/northstar/templates/*.md

# 2. Claude Code 系统级 hook（用户和项目设置覆盖不了）
M="/Library/Application Support/ClaudeCode"
mkdir -p "$M"
[ -f "$M/managed-settings.json" ] && cp "$M/managed-settings.json" "$M/managed-settings.json.bak"
cp "$S"/managed-settings.json "$M/managed-settings.json"; chmod 644 "$M/managed-settings.json"

# 3. 用户级：Codex hook、git hook、PATH
sudo -u "$U" mkdir -p "$UH/.codex"
[ -f "$UH/.codex/hooks.json" ] && sudo -u "$U" cp "$UH/.codex/hooks.json" "$UH/.codex/hooks.json.bak"
sudo -u "$U" cp "$S"/codex-hooks.json "$UH/.codex/hooks.json"
sudo -u "$U" git config --global core.hooksPath /opt/northstar/git
grep -q /opt/northstar/bin "$UH/.zshrc" 2>/dev/null \
  || echo 'export PATH="/opt/northstar/bin:$PATH"' | sudo -u "$U" tee -a "$UH/.zshrc" >/dev/null

echo "安装完成。下一步：在 Codex 里运行 /hooks，审核并信任这四个 hook。"
