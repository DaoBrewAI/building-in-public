#!/usr/bin/env bash
# bin/northstar：init / seal / verify / start / finish / approve-mission / verify-mission
source "$(dirname "$0")/lib.sh"
setup_env; trap teardown_env EXIT

# 初始化并签好第一版 NORTHSTAR，供后面的测试复用
sealed_repo() {
  new_repo
  northstar init >/dev/null
  printf '# NORTHSTAR — test\n- N1: 原文条款一\n' > drafts/NORTHSTAR.md
  tty_run SEAL northstar seal >/dev/null
  git add -A && git commit -qm "[NS] seal"
}

begin "init"
new_repo
run northstar init
expect_rc 0 "init 成功"
expect_true '[ -f drafts/NORTHSTAR.md ] && [ -f drafts/checks/run_all.sh ]' "模板放进 drafts/"
expect_true '[ -d .northstar/missions/archive ] && [ -d proposals ]' "建好 .northstar 与 proposals 目录"
run northstar verify
expect_rc 1 "init 后、未签名时 verify 失败"
expect_out "缺少签名" "verify 提示缺少签名"

begin "seal"
run northstar seal </dev/null
expect_rc 1 "非终端调用 seal 被拒"
expect_out "只能在你自己的终端里交互运行" "提示必须交互运行"
expect_true '[ ! -f .northstar/MANIFEST.sig ]' "非终端调用不产生签名"
run tty_run nope northstar seal
expect_rc 1 "输入不是 SEAL 时取消"
expect_true '[ ! -f .northstar/MANIFEST.sig ]' "取消后没有签名"
run tty_run SEAL northstar seal
expect_rc 0 "输入 SEAL 后签名成功"
expect_true '[ -f .northstar/MANIFEST ] && [ -f .northstar/MANIFEST.sig ]' "生成 MANIFEST 和 MANIFEST.sig"
expect_true '[ -z "$(find drafts -type f)" ]' "签名后清空 drafts/ 里的文件"
expect_true 'grep -q "NORTHSTAR.md" .northstar/MANIFEST' "MANIFEST 覆盖 NORTHSTAR.md"

begin "verify"
run northstar verify
expect_rc 0 "签名后 verify 通过"
expect_out "northstar verify: OK" "verify 输出 OK"
cp .northstar/NORTHSTAR.md "$T/ns.bak"
echo tampered >> .northstar/NORTHSTAR.md
run northstar verify
expect_rc 1 "篡改受保护文件后 verify 失败"
expect_out "受保护文件与签名不一致" "提示文件与签名不一致"
cp "$T/ns.bak" .northstar/NORTHSTAR.md
run northstar verify; expect_rc 0 "还原后 verify 重新通过"
echo extra > .northstar/extra.md
run northstar verify
expect_rc 1 "新增受保护文件后 verify 失败"
rm .northstar/extra.md
cp .northstar/MANIFEST "$T/manifest.bak"; cp .northstar/MANIFEST.sig "$T/sig.bak"
echo "0000  .northstar/fake" >> .northstar/MANIFEST
run northstar verify
expect_true '[ "$RC" -ne 0 ]' "篡改 MANIFEST 本身后签名校验失败"
cp "$T/manifest.bak" .northstar/MANIFEST
resign() { rm -f .northstar/MANIFEST.sig; ssh-keygen -q -Y sign -n "$1" -f "$2" .northstar/MANIFEST </dev/null 2>/dev/null; }
resign northstar "$T/wrong-key"
run northstar verify
expect_true '[ "$RC" -ne 0 ]' "用非授权密钥签名时 verify 失败"
resign northstar-mission "$T/key"
run northstar verify
expect_true '[ "$RC" -ne 0 ]' "用错误 namespace 签名时 verify 失败"
cp "$T/sig.bak" .northstar/MANIFEST.sig
run northstar verify; expect_rc 0 "恢复原签名后 verify 通过"

begin "verify 在子目录和无 .northstar 时"
mkdir -p sub; cd sub; run northstar verify; cd ..
expect_rc 0 "在子目录里运行 verify 也校验仓库根"
new_repo
run northstar verify; expect_rc 0 "没有 .northstar 的仓库 verify 直接通过"

begin "start"
sealed_repo
run tty_run SEAL northstar start m1
expect_rc 1 "mission 草稿不存在时 start 失败"
expect_out "先让 agent 起草 drafts/missions/m1.md" "提示先起草 mission"
mkdir -p drafts/missions
printf '# MISSION: m1\nscope: core\n\n## 验收标准\n- [ ] x\n' > drafts/missions/m1.md
GD=$(git rev-parse --git-dir); echo 2 > "$GD/northstar-drift-count"; echo why > "$GD/northstar-drift-last"
run northstar start m1 </dev/null
expect_rc 1 "非终端调用 start 被拒"
expect_true '[ ! -f drafts/missions/ACTIVE ] && [ ! -f .northstar/missions/ACTIVE ]' "非终端调用 start 不写 ACTIVE"
expect_true '[ "$(cat $GD/northstar-drift-count)" = 2 ]' "非终端调用 start 不清零偏离计数"
run tty_run SEAL northstar start m1
expect_rc 0 "start 成功"
expect_true '[ "$(cat .northstar/missions/ACTIVE)" = m1 ] && [ -f .northstar/missions/m1.md ]' "ACTIVE=m1，mission 进入 .northstar"
expect_true '[ ! -f "$GD/northstar-drift-count" ] && [ ! -f "$GD/northstar-drift-last" ]' "start 清零偏离计数"
run northstar verify; expect_rc 0 "start 后 verify 通过"
git add -A && git commit -qm "[NS] start m1"

begin "finish（无 architecture.json）"
run northstar finish </dev/null
expect_rc 1 "非终端调用 finish 被拒"
expect_true '[ -f .northstar/missions/ACTIVE ] && [ -f .northstar/missions/m1.md ]' "非终端调用 finish 不归档 mission"
run tty_run SEAL northstar finish
expect_rc 0 "finish 成功"
expect_true '[ ! -f .northstar/missions/ACTIVE ] && [ -f .northstar/missions/archive/m1.md ]' "mission 归档、ACTIVE 删除"
run northstar verify; expect_rc 0 "finish 后 verify 通过"

begin "finish（有 architecture.json，进度报告必须通过）"
sealed_repo
mkdir -p drafts/missions
printf '{"components":[{"id":"core","name":"Core","paths":["src/core/*"]}]}\n' > drafts/architecture.json
printf '# MISSION: m2\nscope: core\n' > drafts/missions/m2.md
tty_run SEAL northstar start m2 >/dev/null
git add -A && git commit -qm "[NS] start m2"
mkdir -p src/core && echo 42 > src/core/a.py && git add -A && git commit -qm "[N1] core 返回 42"
run tty_run SEAL northstar finish
expect_rc 1 "没有 status/narrative.md 时 finish 被拒"
expect_out "进度报告未通过校验" "提示进度报告未通过"
expect_true '[ -f .northstar/missions/ACTIVE ]' "被拒时 mission 不归档"
mkdir -p status
echo "- core 现在返回 42 [commit:$(git log -1 --format=%h)] [file:src/core/a.py:1]" > status/narrative.md
run tty_run SEAL northstar finish
expect_rc 0 "说明带引用后 finish 成功"
expect_true '[ -f status/STATUS.md ] && [ -f .northstar/missions/archive/m2.md ]' "生成 STATUS.md 并归档"

begin "approve-mission / verify-mission"
C="$T/control"; mkdir -p "$C"
echo design > "$C/approved-design.md"; echo plan > "$C/approved-plan.md"
( cd "$C" && shasum -a 256 approved-design.md approved-plan.md > approved.sha256 )
run northstar verify-mission "$C"
expect_true '[ "$RC" -ne 0 ]' "未签名时 verify-mission 失败"
run northstar approve-mission "$C" </dev/null
expect_rc 1 "非终端调用 approve-mission 被拒"
run tty_run no northstar approve-mission "$C"
expect_rc 1 "输入不是 SEAL 时取消"
expect_true '[ ! -f "$C/approved.sha256.sig" ]' "取消后没有签名"
run tty_run SEAL northstar approve-mission "$C"
expect_rc 0 "输入 SEAL 后签名成功"
expect_out "approved-design.md" "签名前展示了冻结文件"
run northstar verify-mission "$C"; expect_rc 0 "签名后 verify-mission 通过"
cp "$C/approved.sha256" "$T/a.bak"; echo "0000  x" >> "$C/approved.sha256"
run northstar verify-mission "$C"; expect_true '[ "$RC" -ne 0 ]' "改动 approved.sha256 后 verify-mission 失败"
cp "$T/a.bak" "$C/approved.sha256"
rm -f "$C/approved.sha256.sig"; ssh-keygen -q -Y sign -n northstar -f "$T/key" "$C/approved.sha256" </dev/null 2>/dev/null
run northstar verify-mission "$C"; expect_true '[ "$RC" -ne 0 ]' "用 northstar namespace（而非 northstar-mission）签的名不被接受"
rm -f "$C/approved.sha256.sig"; ssh-keygen -q -Y sign -n northstar-mission -f "$T/wrong-key" "$C/approved.sha256" </dev/null 2>/dev/null
run northstar verify-mission "$C"; expect_true '[ "$RC" -ne 0 ]' "非授权密钥签的名不被接受"

summary
