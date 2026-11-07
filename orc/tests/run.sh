#!/usr/bin/env bash
# orc 的全部测试：bash orc/tests/run.sh
# - orc 骨架（test_orc.py）：用默认 python3 跑；机器上有 3.11+ 时再用它跑一遍（覆盖 tomllib 分支）
# - 从旧 orchestrator 搬来的脚本测试（reused/）
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
rc=0

run() { local name="$1"; shift; echo "######## $name"; "$@" || { echo "FAILED: $name"; rc=1; }; }

for t in test_orc.py test_planning.py test_execution.py; do
  run "$t ($(python3 --version 2>&1))" python3 "$D/$t"
  for py in python3.14 python3.13 python3.12 python3.11; do
    if command -v "$py" >/dev/null && [ "$("$py" -c 'import sys; print(sys.version_info >= (3, 11))')" = True ]; then
      run "$t ($("$py" --version 2>&1))" "$py" "$D/$t"
      break
    fi
  done
done
for t in "$D"/reused/test-*.sh; do
  run "reused/$(basename "$t")" bash "$t"
done

echo; [ $rc -eq 0 ] && echo "全部通过" || echo "有失败，见上面的 FAILED"
exit $rc
