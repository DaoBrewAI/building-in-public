#!/usr/bin/env bash
# repo-template/.github/workflows/northstar.yml 的契约测试
# 按 GitHub pull_request 事件的行为在本地重放 workflow：
#   - GitHub 会生成一个“把 PR 合进 main”的合并 commit（refs/pull/N/merge）；
#     checkout 没写 ref 时检出它，写了 ref 时检出那个 ref
#   - 逐个运行 workflow 里每一步的 run 脚本（${{ github.base_ref }} 换成 main，变量换成测试签名公钥）
source "$(dirname "$0")/lib.sh"
python3 -c 'import yaml' 2>/dev/null || { echo "缺少 PyYAML（python3 -m pip install pyyaml）"; exit 1; }
setup_env; trap teardown_env EXIT
WF="$STAGING/repo-template/.github/workflows"

# 从 workflow 里取出 checkout 的 ref，以及每一步的名字和 run 脚本（\0 分隔）
wf_ref()   { python3 -c 'import sys,yaml; s=yaml.safe_load(open(sys.argv[1]))["jobs"]["verify"]["steps"]; print(next((x.get("with") or {}).get("ref","") for x in s if "checkout" in x.get("uses","")))' "$WF/northstar.yml"; }
wf_steps() { python3 -c '
import sys,yaml
for x in yaml.safe_load(open(sys.argv[1]))["jobs"]["verify"]["steps"]:
    if "run" in x: sys.stdout.write(x["name"] + "\0" + x["run"] + "\0")' "$WF/northstar.yml"; }

# 产品仓库：main 上带着 repo-template 的 workflow
ci_repo() {
  new_repo
  mkdir -p .github/workflows; cp "$WF"/* .github/workflows/
  git add -A; git commit -qm "[NS] workflow" --no-verify
  git checkout -q -b pr
}

# ci：在 $R 的 pr 分支上模拟一次 PR 检查。$CI_FAIL 是第一个失败的步骤名（全部通过时为空）
ci() {
  local head base merge ref target d name script
  head=$(git -C "$R" rev-parse pr); base=$(git -C "$R" rev-parse main)
  d="$T/ci-$RANDOM$RANDOM"; git clone -q "$R" "$d"; cd "$d" || exit 1
  git checkout -q --detach origin/main
  git -c core.hooksPath=/dev/null merge -q --no-ff -m "Merge $head into $base" "$head" 2>/dev/null   # GitHub 的合并引用
  merge=$(git rev-parse HEAD)
  ref=$(wf_ref)
  case "$ref" in
    "") target=$merge ;;
    *pull_request.head.sha*) target=$head ;;
    *) echo "  不认识的 checkout ref：$ref"; target=$merge ;;
  esac
  git checkout -q --detach "$target"
  CI_FAIL=; CI_OUT=
  while IFS= read -r -d '' name && IFS= read -r -d '' script; do
    script=${script//'${{ github.base_ref }}'/main}
    if ! out=$(SIGNERS="$(cat "$ROOT/allowed_signers")" bash -e -c "$script" 2>&1); then
      CI_FAIL=$name; CI_OUT=$out; break
    fi
  done < <(wf_steps)
  cd "$R" || exit 1
}
expect_ci_pass() { [ -z "$CI_FAIL" ] && _ok "$1" || _fail "$1" "失败步骤：$CI_FAIL；输出：$(head -c 300 <<<"$CI_OUT")"; }
expect_ci_fail() { [ "$CI_FAIL" = "$1" ] && _ok "$2" || _fail "$2" "期望在「$1」失败，实际：${CI_FAIL:-全部通过}"; }

seal_northstar() {   # 起草并签名（可选带进度报告和 mission）
  northstar init >/dev/null
  printf '# NORTHSTAR\n- N1: core 返回 42\n' > drafts/NORTHSTAR.md
  if [ "${1:-}" = canvas ]; then     # orc 的流程：只签画布，不 northstar start（没有 ACTIVE、没有 status/）
    printf '{"components":[{"id":"core","name":"Core","paths":["src/core/*"]}]}\n' > drafts/architecture.json
    tty_run SEAL northstar seal >/dev/null; git add -A; git commit -qm "[NS] seal 画布"
  elif [ "${1:-}" = mission ]; then
    printf '{"components":[{"id":"core","name":"Core","paths":["src/core/*"]}]}\n' > drafts/architecture.json
    printf '# MISSION: m1\nscope: core\n\n## 验收标准\n- [ ] core 返回 42\n' > drafts/missions/m1.md
    tty_run SEAL northstar start m1 >/dev/null; git add -A; git commit -qm "[NS] start m1"
  else
    tty_run SEAL northstar seal >/dev/null; git add -A; git commit -qm "[NS] seal"
  fi
}
report() {   # 本地生成进度报告（stop-gate 里做的事），单独提交
  mkdir -p status
  git log --format=%h main..HEAD -- src | while read -r h; do echo "- core 的改动 [commit:$h] [file:src/core/a.py:1]"; done > status/narrative.md
  northstar-status >/dev/null || return 1
  git add status; git commit -qm "[NS] 进度报告"
}

begin "PR 合并引用：commit 检查只看 PR 自己的 commit"
ci_repo; seal_northstar
mkdir -p src/core; echo 42 > src/core/a.py; git add -A; git commit -qm "[N1] core 42"
ci; expect_ci_pass "签名正确、commit 都带 [N#] 的 PR 通过（不被 GitHub 的合并 commit 卡住）"
echo x > b.txt; git add b.txt; git commit -qm "没有条款编号" --no-verify
ci; expect_ci_fail "commit 必须带 [N#]" "PR 里有不带 [N#] 的 commit 时失败"

begin "签名校验"
ci_repo; seal_northstar
echo x >> .northstar/NORTHSTAR.md; git add -A; git commit -qm "[NS] 篡改" --no-verify
ci; expect_ci_fail "签名校验" "受保护文件和签名不一致时失败"

begin "进度报告：status.json 随提交进仓库"
ci_repo; seal_northstar mission
mkdir -p src/core; echo 42 > src/core/a.py; git add -A; git commit -qm "[N1] core 42"
report
ci; expect_ci_pass "本地生成的进度报告单独提交后，CI 重新生成的结果一致"
echo 43 > src/core/a.py; git add -A; git commit -qm "[N1] core 43"
ci; expect_ci_fail "进度报告与代码一致" "报告生成后又有代码提交（报告过期）时失败"
report
ci; expect_ci_pass "重新生成并提交报告后再次通过"

begin "进度报告：orc 的流程（签了画布、没有 northstar start）跳过这一步（proposals/2026-11-08-ci-progress-report-step.md）"
ci_repo; seal_northstar canvas
mkdir -p src/core; echo 42 > src/core/a.py; git add -A; git commit -qm "[N1] core 42"
ci; expect_ci_pass "有画布、没有 ACTIVE 也没有 status/status.json 时，进度报告这一步跳过"

summary
