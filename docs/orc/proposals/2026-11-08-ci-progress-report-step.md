# 提案：签了画布之后，CI 的「进度报告与代码一致」会让每个 orc 的 PR 都失败

状态：**待林翰决定**（2026-11-08）

## 发生了什么

阶段 6 要把画布签进产品仓库的 `.northstar/architecture.json`。核对 northstar-trial 和 daoharness-core 的 CI（`.github/workflows/northstar.yml`，来自阶段 1 的模板）时发现，`verify` 里这一步：

```
[ -f .northstar/architecture.json ] || exit 0
cp status/status.json /tmp/claimed.json
python3 .github/workflows/northstar_status.py
...
```

只要有了 `architecture.json` 就会运行，并要求仓库里有 `status/status.json`。这个文件属于阶段 1 的「单个 mission」流程：`northstar start` → agent 写 `status/narrative.md`、stop-gate 生成进度报告 → `northstar finish`。orc 不走这个流程（orc 的进度由阶段 5 的状态页给出，同样是脚本生成、说明逐条核对），所以 orc 的 mission 分支上没有 `status/status.json`，这一步会在 `cp` 那里失败，`verify` 不过，每个 orc 的 PR 都过不了 CI。还没有实跑到这里，是读 workflow 时发现的。

## 需要你定

- **A（推荐）**：这一步只在有进度报告可查时运行：`.northstar/missions/ACTIVE` 存在（单个 mission 流程进行中）或者 `status/status.json` 存在（已经有报告）时才查；两者都没有就跳过。单个 mission 流程里这一步照旧（ACTIVE 由你 `northstar start` 签进去，`status/status.json` agent 删不掉：guard 保护它），orc 的流程里跳过，由 orc 的状态页代替。要改模板，并由你用自己的账号推到 northstar-trial 和 daoharness-core。
- B：去掉这一步。单个 mission 流程就没有这道 CI 检查了，不推荐。
- C：orc 也生成 `status/status.json`。`northstar_status.py` 要求有 `[NS] start <mission>` 提交，和 orc 的流程对不上，要大改，不推荐。

## 影响

- 改 `docs/orc/northstar-staging/repo-template/.github/workflows/northstar.yml` 的一行判断，在 `tests/test_ci.sh` 加两条测试（orc 流程跳过；单个 mission 流程照旧检查）。
- 你把新的 workflow 推到 northstar-trial（这次实跑要用）和 daoharness-core（阶段 7 用）。
