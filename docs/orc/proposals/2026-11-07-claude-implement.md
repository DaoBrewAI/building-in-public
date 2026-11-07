# 提案：执行改用 Claude Code（Opus），评审分级

状态：**林翰 2026-11-07 已决定**，已改进 PLAN「已确定的决定」的模型、子任务、提交三行。

## 决定

| 角色 | 模型 | 不可用时 |
| --- | --- | --- |
| `implement`：写代码、修复、rework | Claude Opus（目前 `claude-opus-5-5`） | — |
| `plan`：brainstorm、设计、计划、DAG | Claude Opus | — |
| `review`：重要、复杂的评审 | Claude 当前最强（目前 `claude-fable-5-1`） | **不降级**，orc 停下来问用户 |
| `review_light`：简单评审 | Claude Opus | — |

模型名只写在 `orc/config/models.toml`。

**哪些评审算“重要、复杂”**：这由代码按固定规则判断（`orc` 的 `review_role()` 和 `northstar-review --role auto`），不交给模型自己定：

- 节点进入 submitted 时的整体评审
- 阶段 5 的最终审查
- 上一次被判 DRIFT 之后的复审
- 单次提交的改动超过 `deep_review_over_lines` 行（默认 300，写在 models.toml 的 `[review]` 里）

其余每次提交前的小步对齐评审，都用 `review_light`。

**独立性规则**：`review` 的模型不能和 `implement` 相同，也不能降级成它。orc 在解析 models.toml 时会检查这一点。两个 Claude 账号解决不了这个问题：同一个模型在同样的设计上会有同样的盲区，换账号只能把额度分开。

## 原来靠 Codex 顺带得到、现在要自己补上的两件事

1. **提交必须走 broker**：原来 Codex 沙箱里 git 是只读的；Claude Code 默认可以直接 `git commit`。
2. **执行会话只能写自己的 worktree**：原来 Codex 的 workspace-write 沙箱自带这个限制；Claude Code 默认没有。

## 实测：Claude Code 沙箱（2026-11-07，Claude Code 2.1.318，macOS）

做法：在临时仓库里建一个 linked worktree，进入后用 `claude -p --settings '{"sandbox":{...}}'` 运行命令。为了单独测沙箱，权限检查用 `bypassPermissions` 跳过（只用于这个临时测试）。

| 沙箱配置 | 写 worktree 外 | 写主仓库 `.git/` | 写 `.git/hooks/` | `git status` / `diff` | `git add` / `commit` |
| --- | --- | --- | --- | --- | --- |
| 关 | 能写 | 能写 | 能写 | 正常 | 成功 |
| 开（`enabled`、`failIfUnavailable`、`allowUnsandboxedCommands:false`） | operation not permitted | **能写** | operation not permitted | 正常 | **成功** |
| 开 + `filesystem.denyWrite: ["<主仓库>/.git"]` | operation not permitted | operation not permitted | operation not permitted | **正常** | **失败**：`Unable to create '…/.git/worktrees/wt/index.lock': Operation not permitted` |

结论：

- 无界面的 `claude -p` 下沙箱生效。
- 官方文档写明：在 linked worktree 里，沙箱会自动允许写主仓库共享的 `.git`（`hooks/` 和 `config` 除外），好让 `git commit` 能更新 refs 和 index。所以默认配置下提交**能成功**，单靠沙箱挡不住直接提交。
- 加上 `denyWrite` 主仓库 `.git` 之后，git 变成只读，效果和 Codex 一样：执行会话提交不了，只能由 orc 的 broker（不在沙箱里）代为提交。

参考：<https://code.claude.com/docs/en/sandboxing>。用户报告过同类现象：claudeissues.com 上的 issue 64792、62551、46000。

## 实测 2：`--add-dir` 会放开 Bash 写入（2026-11-07，阶段 3 规划会话）

规划会话最初用 `--add-dir <产品仓库>` 让它能读代码，同时用权限规则把 Write / Edit 限定在工作目录。之后做了一次对抗测试：明确要它写产品仓库。

| 配置 | Write 写产品仓库 | Bash `echo x > 产品仓库/…` | Read / Grep / `git -C` 读产品仓库 |
| --- | --- | --- | --- |
| `--add-dir` 产品仓库 | 被拒（没有权限） | **写成了** | 能读 |
| 不用 `--add-dir`，沙箱对产品仓库 `denyWrite` | 被拒（没有权限） | 被拒（`operation not permitted`） | **能读** |

原因：文档写明，沙箱允许写工作目录和 `--add-dir` 加入的目录。所以 **`--add-dir` 加入的目录对 Bash 是可写的**。规划会话已改为第二种配置。阶段 4 的执行会话同理：只有本节点的 worktree 可写，其余目录一律不用 `--add-dir`，需要保护的路径设 `denyWrite`。

## 阶段 4 怎么用（写进 PLAN）

orc 用 `claude -p` 启动执行会话，带一份只给这次会话用的设置：

- `sandbox.enabled: true`、`failIfUnavailable: true`、`allowUnsandboxedCommands: false`
- `sandbox.filesystem.denyWrite: ["<主仓库>/.git"]`：git 只读，提交必须走 broker
- 网络默认全关，按需在 `allowedDomains` 里放行
- 沙箱只管 Bash：Edit / Write 等工具要另用权限规则限制在自己的 worktree 里。**阶段 4 实测**
- 环境变量 `ORC_ROLE=implement`、`ORC_NODE=<node>`，便于 hook 识别

## 还没验证、阶段 4 要实测的

- 用权限规则把 Edit / Write 限制在 worktree 内，在 `claude -p` 下是否生效
- `claude --resume <session>` 能否用于纠偏和 rework，是否回到同一个会话
- 用 `--output-format json` 拿结构化结果
- 并行跑多个 Opus 会话时的额度消耗（执行和评审都用 Claude 账号）

## 其他影响

- 信任层：`align.sh` 不再按“谁写的交给另一家审”选评审，改为 `northstar-review --role auto`；模型从 `/opt/northstar/models.toml` 读，由 `install.sh` 从 `orc/config/models.toml` 复制。改完要重新 sudo 安装。
- `orc doctor`：codex 只在有角色用它时才检查；`--live` 时每个模型只调用一次。
- ~~Sites 发布仍然是 OpenAI Sites。如果调研结果是只能通过 Codex 发布，Codex 就保留，专门用于发布。~~ 2026-11-07 改为 Claude Artifacts，见 `2026-11-07-review-page-artifacts.md`。
