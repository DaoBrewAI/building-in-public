#!/usr/bin/env bash
# 运行 northstar-staging 的全部功能测试：bash docs/orc/northstar-staging/tests/run_all.sh
# 只在临时目录里操作，不需要 sudo，不碰 /opt/northstar、Secretive 或你的 git 全局配置。
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; S="$(dirname "$D")"
for c in jq ssh-keygen ssh-agent python3 git; do
  command -v "$c" >/dev/null || { echo "缺少 $c"; exit 1; }
done

rc=0
echo "== 语法检查"
for f in "$S"/install.sh "$S"/bin/northstar "$S"/bin/northstar-review "$S"/hooks/*.sh "$S"/git/commit-msg; do
  bash -n "$f" && echo "  ok   bash -n ${f#$S/}" || { echo "  FAIL bash -n ${f#$S/}"; rc=1; }
done
for f in "$S"/bin/northstar-scope "$S"/bin/northstar-status; do
  python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" \
    && echo "  ok   python ${f#$S/}" || { echo "  FAIL python ${f#$S/}"; rc=1; }
done
for f in "$S"/managed-settings.json "$S"/codex-hooks.json; do
  jq -e . "$f" >/dev/null && echo "  ok   json ${f#$S/}" || { echo "  FAIL json ${f#$S/}"; rc=1; }
done
cmp -s "$S/bin/northstar-status" "$S/repo-template/.github/workflows/northstar_status.py" \
  && echo "  ok   CI 里的 northstar_status.py 与 bin/northstar-status 是同一份" \
  || { echo "  FAIL CI 里的 northstar_status.py 与 bin/northstar-status 不一致"; rc=1; }

for t in "$D"/test_*.sh; do
  echo; echo "######## $(basename "$t")"
  bash "$t" || rc=1
done
echo; [ $rc -eq 0 ] && echo "全部通过" || echo "有失败，见上面的 FAIL"
exit $rc
