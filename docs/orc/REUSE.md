# 旧 orchestrator 的复用清单

来源：github.com/DaoBrewAI/building-in-public 的 `orchestrator/`。

## 直接复用（连同测试一起搬，只改路径和目录约定）

| 脚本 | 用途 | 说明 |
| --- | --- | --- |
| `scripts/commit-broker.sh` | 子任务的提交代理 | **必须保留**：执行会话的沙箱对主仓库 `.git` 设 denyWrite，git 是只读的（2026-11-07 起执行改用 Claude Code；原先是 Codex 沙箱的 git 只读），子任务自己提交不了。对齐评审、纠偏单也挂在这里 |
| `scripts/integrate-task.sh` | 校验并合并单个子任务，不改写历史 | 并行后按锁顺序调用 |
| `scripts/validate-task-dag.sh` | 校验 DAG 并冻结 | 含节点间文件重叠检查，正好用于并行调度 |
| `scripts/coordinator_lifecycle_lock.py` | 所有状态变更共用的一把锁 | 并行之后更需要 |
| `scripts/verify-approved-authority.py` | 校验冻结的设计文件 | 前面加一步签名校验（`northstar verify-mission`） |

## 参考思路，重写成更简单的版本

| 脚本 | 原来做什么 | 新版怎么做 |
| --- | --- | --- |
| `scripts/task-worktree.sh`（1,029 行） | 创建和接管子任务 worktree | 新版只需要：按节点创建 worktree、记录、清理时只删记录过的 |
| `scripts/task-outcome.py`（1,489 行） | 校验 Codex app 子任务的结果 | 改为校验执行会话（`claude -p`）最后输出的结构化结果 |
| `scripts/native-task-health.py` | Codex app 子任务的健康检查 | 改为进程监管：PID、超时、退出码 |
| `scripts/spawn-worker.sh` | 启动规划和评审阶段 | 改为按 models.toml 用 `claude -p` 启动 |
| `scripts/orchestrator-gc.sh`（2,325 行） | 清理已完成 mission 的资源 | 新版状态都在文件里，清理只删 orc 记录过的 worktree 和分支 |
| `hooks/codex-continuation*`（约 100KB） | 上下文压缩后的续接 | 新版 `orc step` 可以从断点续跑，压缩后再跑一次就接上，不再需要 |
| `skills/orchestrating/references/html-sites-delivery.md` | 发布到 OpenAI Sites | 保留思路，改成独立的 publish 适配层 |

## 不要了

| 脚本 | 原因 |
| --- | --- |
| `scripts/planning-output.py` | 只服务于已删除的 codex-ultra 分支 |
| `scripts/classify-mission-version.sh` | 旧 0.4.0 版本校验，新版只有一个版本 |
| `scripts/codex-task-client.py` | 只服务于 Codex app 可见任务，新版用 codex exec |
| `scripts/worker-guard.sh`、`scripts/install-worker-settings.sh` | 被信任层的 guard 和系统级 hook 取代 |
| `scripts/pipeline-gate.sh` | 被 `orc step` 的状态检查和信任层的 stop-gate 取代 |
| `skills/` 下的 SKILL.md 和 5 份 reference | 换成约 450 词的薄 skill |

## 保留的经验（写进新代码的注释和测试里）

- 执行会话的 git 只读（沙箱 denyWrite 主仓库 `.git`，已实测）→ 提交必须走 broker。
- 合并只做普通 merge，不 rebase、不 squash、不改写历史。
- 清理是不可逆操作：只动自己记录过的资源，先列清单再执行。
- 任何不确定的进程状态都当作还活着，复查一次，绝不重复启动同一个节点。
