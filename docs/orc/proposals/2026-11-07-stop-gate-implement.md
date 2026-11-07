# 提案：信任层的 Stop hook 对 orc 的执行会话放行「未提交的改动」

状态：**林翰 2026-11-07 选 A**。`stop-gate.sh` 已改，测试已加（见文末「实测」和「实现」）；要你重新 sudo 安装才生效。

## 要解决的问题

信任层的 Stop hook（`/opt/northstar/hooks/stop-gate.sh`）在会话结束前把关。仓库有 `.northstar/` 并且签名有效时：

- 第 2 条：工作区还有未提交的改动，就 `exit 2`，不让会话结束（「按验收标准小步提交后再结束」）。
- 第 4 条：跑 `.northstar/checks/run_all.sh` 和 `northstar-status`，不通过也不让结束。

这两条是给**直接在仓库里干活的 agent** 设计的：它自己提交，每次提交前过 `align.sh` 的对齐评审。

orc 的执行会话不一样：

- 它在节点的 worktree 里改代码，**提交不了**（沙箱对主仓库 `.git` 设了 denyWrite，这是「已确定的决定」）。
- 提交由 orc 在会话这一轮结束之后做：提交关口跑检查、做对齐评审，再交给 broker 提交。
- 所以执行会话每次结束时，工作区里**一定**有还没提交的改动。

结果是第 2 条每次都会拦下执行会话：它会被要求提交，提交又被沙箱拒绝，就这样一直卡着。玩具仓库没有签名，第 1 条校验失败就直接放行了，所以阶段 3 没碰到这个问题。我是读代码确认的；实测要等 Claude Code 重新登录后再做。

## 方案

- **A（推荐）**：`stop-gate.sh` 在 `ORC_ROLE=implement` 时跳过第 2 条和第 4 条。第 1 条（签名）和第 3 条（越界改动）照常执行。
  - 理由：这两条要保证的事，orc 做得更严。每次提交都要过提交关口：只跑冻结的检查，并对照签名的设计做对齐评审；节点完成时还有整体评审。
  - `ORC_ROLE` 是启动 Claude Code 时设的环境变量，会话里的 agent 改不了自己进程的环境变量。
  - 改动：`stop-gate.sh` 加两行判断，`northstar-staging/tests` 加对应的测试，你重新运行一次 `install.sh`。
- **B**：不改信任层，让执行会话在会话里面等提交完成：会话把提交请求写到 worktree 外的一个收件目录，orc 常驻一个进程跑提交关口和 broker，会话轮询结果，提交完再结束。
  - 不用动信任层，但多一个常驻进程，会话要在 Bash 里循环等评审（一次几分钟），收件目录还得在沙箱和 guard 里单独开口子。

## 影响

- 选 A：改 `docs/orc/northstar-staging/hooks/stop-gate.sh` 和它的测试，你重新 sudo 安装。PLAN 阶段 4 的「启动子任务」一条注明这一点。
- 选 B：阶段 4 加常驻进程和收件目录，「启动子任务」一条要重写。

## 实测（2026-11-07，Claude Code 2.1.318，已签名的 northstar-trial 仓库的本地克隆）

执行会话的配置：沙箱开、主仓库 `.git` denyWrite、Write / Edit 只放行 worktree，`ORC_ROLE=implement`，Opus effort low。

| 操作 | 结果 |
| --- | --- |
| Write 写 worktree 里的文件 | 成功 |
| Write 写 worktree 外 | 被拒（没有权限） |
| Bash 写 worktree 外（另一个目录、家目录） | 被拒（`operation not permitted`） |
| Bash 写 `/tmp` 下 | **成功**：沙箱默认放行临时目录。worktree 默认放在 `~/.orc-worktrees/`，不在临时目录里，节点之间写不到对方 |
| `git add` / `git commit` | 失败：`Unable to create …/.git/worktrees/n1/index.lock` |
| 联网（curl） | 被拒（沙箱的网络代理拒绝） |
| `--resume` 同一个会话 | 回到同一个会话，记得上一轮的结果 |
| 工作区有未提交改动时结束 | **Stop hook 连续拦了 9 次**，Claude Code 强制结束，结果为空 |

## 实现

- `stop-gate.sh`：`ORC_ROLE=implement` 时跳过第 2 条（未提交的改动）和第 4 条（验收检查、进度报告）；第 1 条签名、第 3 条越界照常。
- `northstar-staging/tests/test_hooks.sh` 加一组测试：普通会话和其他 orc 角色有未提交改动时仍被拦；执行会话有未提交改动、进度报告不通过时放行；执行会话的越界改动照样被拦；签名不一致时照常结束并通知。
