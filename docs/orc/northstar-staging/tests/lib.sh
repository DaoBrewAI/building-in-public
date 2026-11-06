#!/usr/bin/env bash
# tests/lib.sh —— northstar-staging 功能测试的公共部分
#
# 不安装任何东西、不用真实密钥：
#   - 把 staging 的 bin/ hooks/ git/ templates/ 复制到临时目录 $ROOT，
#     只把 "/opt/northstar" 和 Secretive 的 socket 路径替换成临时值；
#   - 用临时 ed25519 密钥 + 临时 ssh-agent 代替 Secretive + Touch ID；
#   - git 全局配置指向临时文件，不读写你的 ~/.gitconfig；
#   - PATH 最前面放假的 osascript / open / claude / codex，避免弹通知、开窗口、调用真实模型。
set -uo pipefail

STAGING="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$STAGING/tests"
PASS=0; FAIL=0; FAILED=()

setup_env() {
  T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ns-test.XXXXXX")" && pwd -P)"
  ROOT="$T/opt-northstar"; FAKEBIN="$T/fakebin"
  mkdir -p "$ROOT"/{bin,hooks,git,templates} "$FAKEBIN"

  ssh-keygen -q -t ed25519 -N '' -C ns-test -f "$T/key"
  ssh-keygen -q -t ed25519 -N '' -C ns-wrong -f "$T/wrong-key"
  eval "$(ssh-agent -a "$T/agent.sock" -s)" >/dev/null
  ssh-add -q "$T/key" 2>/dev/null
  cp "$T/key.pub" "$ROOT/northstar_signing.pub"
  # 与 install.sh 第 9 行相同的格式
  echo "linhan namespaces=\"northstar,northstar-mission\" $(cat "$ROOT/northstar_signing.pub")" > "$ROOT/allowed_signers"

  local rewrite=(-e "s#/opt/northstar#$ROOT#g"
                 -e "s#^export SSH_AUTH_SOCK=.*#export SSH_AUTH_SOCK=\"$T/agent.sock\"#")
  for f in "$STAGING"/bin/* "$STAGING"/hooks/*.sh "$STAGING"/git/commit-msg; do
    local rel="${f#$STAGING/}"
    sed "${rewrite[@]}" "$f" > "$ROOT/$rel"; chmod 755 "$ROOT/$rel"
  done
  cp "$STAGING"/templates/*.md "$ROOT/templates/"

  # 假命令
  printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/osascript"
  printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/open"
  for r in claude codex; do
    cat > "$FAKEBIN/$r" <<EOF
#!/bin/sh
# 假评审：记录被调用的命令和 prompt，输出 \$T/verdict 的内容
echo "$r" >> "$T/reviewer-calls"
for a; do last="\$a"; done
printf '%s' "\$last" > "$T/last-prompt"
cat "$T/verdict" 2>/dev/null
EOF
    chmod 755 "$FAKEBIN/$r"
  done
  export PATH="$FAKEBIN:$ROOT/bin:$PATH"

  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.name ns-test
  git config --global user.email ns-test@example.invalid
  git config --global init.defaultBranch main
  git config --global commit.gpgsign false
  unset CLAUDE_PROJECT_DIR
}

teardown_env() {
  [ -n "${SSH_AGENT_PID:-}" ] && kill "$SSH_AGENT_PID" 2>/dev/null
  [ -n "${T:-}" ] && rm -rf "$T"
}

# 新建一个空的测试产品仓库，cd 进去
new_repo() {
  R="$T/repo-$RANDOM$RANDOM"; mkdir -p "$R"; cd "$R" || exit 1
  git init -q
  git config core.hooksPath "$ROOT/git"
  echo seed > README.md; git add README.md; git commit -qm "[NS] seed" --no-verify
}

# 在伪终端里运行命令，并把 $1 作为一行输入发给它（模拟你在终端里输入 SEAL）
tty_run() { local input="$1"; shift; python3 -I "$TESTS/pty_run.py" "$input" "$@"; }

# 直接写一个已有 mission 的 .northstar（不签名，给 hook 测试用）
write_mission_fixture() {
  mkdir -p .northstar/missions/archive .northstar/checks
  cat > .northstar/NORTHSTAR.md <<'EOF'
# NORTHSTAR — test
## 目标
- N1: 原文条款一
EOF
  cat > .northstar/missions/m1.md <<'EOF'
# MISSION: m1
服务的条款: N1
scope: core   # 注释会被忽略
forbid: db/migrations/*, package.json

## 验收标准（必须可验证）
- [ ] core 模块返回 42

## 本次范围外
- 不动 ui
EOF
  echo m1 > .northstar/missions/ACTIVE
  cat > .northstar/architecture.json <<'EOF'
{"components": [
  {"id": "core", "name": "Core", "paths": ["src/core/*"]},
  {"id": "ui", "name": "UI", "paths": ["src/ui/*"], "depends_on": ["core"]}
]}
EOF
}

# ---- 断言 ----
_ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); FAILED+=("$CURRENT: $1"); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# 运行命令，捕获 $OUT 和 $RC
run() { OUT="$("$@" 2>&1)"; RC=$?; }
# 从 stdin 读 payload 运行
run_in() { local in="$1"; shift; OUT="$(printf '%s' "$in" | "$@" 2>&1)"; RC=$?; }

expect_rc()       { [ "$RC" = "$1" ] && _ok "$2" || _fail "$2" "期望退出码 $1，实际 $RC；输出：$(head -c 400 <<<"$OUT")"; }
expect_out()      { grep -qF -- "$1" <<<"$OUT" && _ok "$2" || _fail "$2" "输出里没有「$1」；输出：$(head -c 400 <<<"$OUT")"; }
expect_true()     { if eval "$1"; then _ok "$2"; else _fail "$2" "条件不成立：$1"; fi; }

begin() { CURRENT="$1"; echo "== $1"; }

summary() {
  echo; echo "通过 $PASS，失败 $FAIL"
  for f in "${FAILED[@]+"${FAILED[@]}"}"; do echo "  - $f"; done
  [ "$FAIL" -eq 0 ]
}
