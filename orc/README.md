# orc

新 workflow 的机械流程：流程交给代码，判断留给模型。计划见 `docs/orc/PLAN.md`，状态模型见 `docs/orc/STATE.md`。

| 路径 | 内容 |
| --- | --- |
| `bin/orc` | 命令行：`step`、`answer`、`status`、`doctor`（Python，只用标准库，3.9+） |
| `config/models.toml` | 唯一写模型名的地方；mission 开始时解析并记进 mission 目录 |
| `scripts/` | 从旧 orchestrator 原样搬来的 5 个脚本（见 `docs/orc/REUSE.md`） |
| `templates/task-dag.json` | DAG 模板 |
| `tests/` | `bash orc/tests/run.sh` 跑全部测试 |

mission 默认放在 `~/.orc/missions/<mission>/`，可用环境变量 `ORC_HOME` 改。

## 当前进度（阶段 2）

`orc step --new "<请求>"` 建好 mission 并走到 `planning`。规划会话（阶段 3）、执行（阶段 4）、最终审查和状态页（阶段 5）还没有实现：走到这些状态时 `orc step` 会输出 `next: error …还没有实现（PLAN 阶段 N）`，实现后再运行 `orc step --mission <m>` 即可接上。
