# 提案：orc 跑检查用的副本没有 `.git`，daoharness-core 自己的检查跑不起来

状态：**等林翰定**。FinTelli 第一个真实 mission（`fintelli-p1-1`）的验证阶段发现。

## 发生了什么

orc 在三个地方把产品代码复制一份、在副本上跑检查，三处的副本都**没有 `.git`**（STATE.md 第 160、268 行写明的做法）：

| 时点 | 函数 | 副本怎么来 |
| --- | --- | --- |
| 验证：实现前跑一遍检查 | `snapshot_repo` | `git archive` |
| 执行：提交关口 | `copy_worktree` | 只复制文件 |
| 最终审查：合并后重跑全部检查和 `.northstar/checks/run_all.sh` | `export_tree` | `git archive` |

daoharness-core 签名的检查（`.northstar/checks/core_checks.py`）离不开 git：列文件用 `git ls-files`；N9「已有测试只增不删」、N11「新文件不超过 600 行」、N12「commit 正文写根因」都要和起点比（`git merge-base origin/main HEAD`、`git diff`、`git rev-list`）。在没有 `.git` 的副本里，`git ls-files` 报 `fatal: not a git repository`，检查直接报错退出。

- **已经发生**：第 1 轮验证，验证会话把三条扫描（`no-tax-words`、`no-tax-pack-ref`、`no-raw-speech-match`）写成调用 `core_checks.py`、标成「已有行为，应通过」，orc 实际跑全部报错，退回。第 2 轮验证会话改写成不用 git 的 pytest 扫描（`test_scan_acceptance.py`），才通过。也就是说，验收标准 7 现在由验证会话自己重写的扫描把关，不是你签名的 `core_checks.py`。
- **一定会发生**：最终审查要在合并后的代码上跑 `run_all.sh`，它调用 `core_checks.py`，同样会因为没有 `.git` 失败，而且「落不到某个节点」，P1-1 会停在最终审查。之后每个 mission 都一样。
- trial 没发现：trial 的 `run_all.sh` 只跑 pytest，不用 git。

## 需要你定

- **A（推荐）**：三处副本都换成带 git 历史的副本：`git clone --shared` 产品仓库到副本目录，检出对应提交（验证用 base、最终审查用 mission tip、提交关口用节点 worktree 的 HEAD，再把 worktree 里没提交的改动盖上去）。沙箱规则不变：检查只能写这份副本、不能联网；产品仓库本身不被写（`--shared` 只读它的对象）。副本里的 `origin/main` 就是产品仓库本地的 main，`core_checks.py` 用它算起点，正好是这个 mission 开始时的 main。改 orc 三个函数和 STATE.md 两行，加契约测试（副本里 `git ls-files`、`git merge-base origin/main HEAD` 能用；产品仓库没被写）。
- B：改 daoharness-core 的 `core_checks.py`，没有 git 时退回到列目录、跳过和起点比较的三条（N9、N11、N12）。要你重新签名，而且这三条在 orc 里就永远不查了，只剩 CI 查。不推荐。
- C：不改，最终审查时由你看过后手动放行 `run_all.sh`。每个 mission 都要人工介入，违背「全流程无人工修补」。不推荐。

## 对正在跑的 P1-1

P1-1 现在停在审阅页（`go-gate`）。orc 每一步都重新读自己的代码，所以：

- 选 A 的话，你可以现在就看审阅页、说 go：执行要一阵子，修复在执行期间合并进 main，P1-1 走到最终审查时用的就是修好的 orc。
- 审阅时留意验收标准 7（三条扫描）：现在由验证会话重写的 `test_scan_acceptance.py` 把关。修好之后，最终审查还会再跑一遍你签名的 `run_all.sh`，两道都要过。
