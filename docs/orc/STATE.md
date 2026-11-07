# orc 状态模型

`orc` 的所有机械流程都按这一页读写状态。规则只有三条：

1. **状态的唯一来源是 `events.jsonl`。** `state` 文件只是缓存；`orc` 每次运行先从头回放日志、再对齐缓存。回放时**逐条校验**每个状态事件：`from` 必须等于上一状态，转换必须在下表里；有一条不合法就报错停下（`next: error …第 N 行…`），不按它走。
2. **所有改动都在同一把锁里。** 用复用的 `coordinator_lifecycle_lock.py`，锁文件在 mission 的 `control/` 下；commit broker 和 integrate-task 也拿这把锁，所以 orc、broker、集成三者互斥。
3. **只追加，不改写。** 事件只追加；冻结文件只在 go 之后写一次；mission 记录的模型不再改变。
4. **只有 orc 能写 mission 目录。** 信任层的 guard 拦截 agent 工具对 `$ORC_HOME`（默认 `~/.orc`）的写入，不管当前仓库有没有 `.northstar/`。文本匹配挡不住刻意绕过，所以还有第 5 条。
5. **go 之后每一步都重新验签。** mission 处于 `approved`、`executing`、`reviewing`、`accepted`（或从这些状态进入 `blocked`）时，每次 `orc step` 先跑 `northstar verify-mission` 和 `verify-approved-authority.py`；任一失败就 `next: error`，不执行任何流程。伪造一串合法的状态事件也绕不过签名。

## mission 目录

默认放在 `~/.orc/missions/<mission>/`（环境变量 `ORC_HOME` 可改根目录）。

```
<mission>/
  state               当前 mission 状态（一个词），events.jsonl 的缓存
  events.jsonl        只追加的事件日志
  request.md          用户的原始请求
  repo                产品仓库的绝对路径
  models.json         mission 开始时从 orc/config/models.toml 解析的模型，之后不变
  questions/<n>.md    orc 输出 ask-user / mediate 时的问题
  answers/<n>.md      orc answer 写回的回答
  plan/               规划会话的产出（阶段 3）：design.md、plan.md、task-dag.json
  verify/             验证会话的产出：checks.json、files/<测试文件>、results.json（检查在实现前的运行结果）
  control/            coordinator 的权威目录 = 复用脚本的 control root；锁文件也在这里
    approved-design.md  approved-plan.md  brief-exec.md  approved-task-dag.json
    approved.sha256     approved.sha256.sig（northstar approve-mission 的签名）
    approved-checks.json  approved-tests/<测试文件>   冻结的验收测试；哈希写在 brief-exec.md 里，随它一起签名
    tasks/<node>/     每个节点的控制目录（broker、integrate-task 的 --control-dir）
  nodes/<node>/       每个节点的工作侧目录（broker 的 --mission-dir、integrate-task 的 --task-dir）
```

节点的 git worktree **不在 mission 目录里**，放在 `~/.orc-worktrees/<mission>/<node>/`（环境变量 `ORC_WORKTREES` 可改根目录）。原因：guard 拦截 agent 对 `$ORC_HOME` 的一切写入，worktree 放在里面，节点就写不了代码；guard 也不给任何路径开例外，例外路径容易被利用。`ORC_WORKTREES` 落在 `$ORC_HOME` 之内时 orc 直接报错，`orc doctor` 也会检查。worktree 在阶段 4 创建，路径登记在 `control/tasks/<node>/worktrees.txt`；清理只删登记过的。

`control/` 和 `nodes/` 里的文件格式沿用复用脚本的约定（`worktrees.txt` 一行四列：worktree、分支、base、仓库，用制表符分隔；`generation`、`state` 等单行文件），orc 不另起一套。

## mission 状态

```
new → planning → verifying → plan-review → approved → executing → reviewing → accepted → cleaned
```
外加 `blocked`（等用户）和 `failed`（不可恢复，终态）。

| 状态 | 含义 | 离开的条件（由 `orc step` 判断） | 下一个状态 |
| --- | --- | --- | --- |
| `new` | 刚建好目录，记录了请求和模型 | 无条件 | `planning` |
| `planning` | 规划会话在产出设计、计划、DAG（阶段 3） | 产出齐全且 `validate-task-dag.sh` 通过 | `verifying` |
| `verifying` | 验证会话在实现之前写验收测试和 `checks.json`（阶段 3） | 产出通过校验，且每个检查在当前代码上的结果符合 `expect_before` | `plan-review` |
| `plan-review` | 审阅页已发布，等用户说 go 并签名 | `northstar verify-mission` 通过，且 `verify-approved-authority.py` 校验哈希通过 | `approved` |
| `approved` | 冻结文件已签名 | 无条件，开始调度 | `executing` |
| `executing` | 节点并行执行、提交、集成（阶段 4） | 所有节点都 `integrated` | `reviewing` |
| `reviewing` | 最终审查（阶段 5） | 审查通过，状态页已发布 | `accepted` |
| `accepted` | 已验收 | 清理完成 | `cleaned` |
| `cleaned` | 终态 | — | — |
| `blocked` | 需要用户或 coordinator 决定（熔断、升级的问题）。**进入时必须带一个问题**（状态事件的 `question` 字段），只能经 `block()` 进入 | **这个问题**有了 `answer` 事件（别的问题的回答不算） | 进入 blocked 之前的状态 |
| `failed` | 不可恢复的错误，终态 | — | — |

只有上表里的转换是合法的；`orc` 遇到其他转换直接报错，不写日志。

## 节点状态

```
pending → running → submitted → integrated
```
外加 `rework`（被打回）和 `blocked`（熔断或需要裁决）。

节点状态**不单独存一份**，由 orc 从复用脚本的协议文件推出来，避免两份状态打架：

| 节点状态 | 判定 |
| --- | --- |
| `pending` | `control/tasks/<node>/` 还不存在 |
| `running` | 控制目录的 `state` 是 `ready`，且子任务进程在运行 |
| `submitted` | 工作侧 `nodes/<node>/state` 是 `completed` |
| `integrated` | 控制目录的 `state` 是 `integrated`、`cleanup_pending` 或 `collected` |
| `rework` | 控制目录里有 `unresolved-rework` |
| `blocked` | 控制目录里有 `blocked`（orc 写入，内容是原因） |

每次节点状态变化，orc 追加一条 `node-state` 事件。

## events.jsonl

每行一个 JSON 对象，只追加。共同字段：

| 字段 | 说明 |
| --- | --- |
| `ts` | 带时区的 ISO 时间 |
| `mission` | mission 名 |
| `kind` | 事件类型，见下表 |
| `by` | 谁触发的：`orc step`、`orc answer`、`broker`、`integrate` 等 |

| `kind` | 额外字段 |
| --- | --- |
| `created` | `request`、`repo`、`models`（models.json 的 sha256） |
| `state` | `from`、`to`、`reason`（可选）；进入 `blocked` 时另有 `question`（问题 id）和 `type`（ask-user / mediate） |
| `node-state` | `node`、`from`、`to` |
| `commit` | `node`、`sha`、`files` |
| `review` | `node`、`verdict`（ALIGNED / DRIFT）、`reason` |
| `correction` | `node`、`count`（连续第几次）、`card`（纠偏单文件） |
| `check` | `node`（可选）、`id`、`passed`、`log` |
| `ask` | `id`、`type`（ask-user / mediate）、`file` |
| `answer` | `id`、`file` |
| `error` | `message` |
| `planner-start` | `run`（第几次运行）、`session`、`pid`、`mode`（new / resume）、`delivers`（这次发给会话的回答、意见 id） |
| `planner-exit` | `run`、`rc`、`outcome`（question / invalid / ready / failed）、`problems`（可选） |
| `plan-ready` | `files`（文件名 → sha256） |
| `verify-snapshot` | `cycle`（第几轮验证）、`base`（验证会话拿到的代码副本对应的提交） |
| `verifier-start` / `verifier-exit` | 同 `planner-start` / `planner-exit`，另带 `cycle` |
| `verify-ready` | `base`、`checks`（checks.json 的 sha256）、`tests`（测试文件 → sha256）、`results`（检查 id → 实现前的退出码） |
| `feedback` | `id`、`text`：用户审阅后的修改意见 |
| `published` | `route`、`url`、`sha256` |
| `frozen` | `files`（冻结文件名 → sha256） |

状态页和排查都只读这个文件。

## models.json

`orc step --new` 时解析 `orc/config/models.toml`，写成：

```json
{"source": "<models.toml 的路径>", "sha256": "<文件哈希>", "resolved_at": "<时间>",
 "roles": {"implement":    {"cli": "claude", "model": "…", "effort": "high"},
           "plan":         {"cli": "claude", "model": "…", "effort": "high"},
           "review":       {"cli": "claude", "model": "…", "effort": "high", "deep_review_over_lines": "300"},
           "review_light": {"cli": "claude", "model": "…", "effort": "high"}}}
```

之后 orc 只读 `models.json`，不再读 `models.toml`；改 `models.toml` 只影响新 mission。

## 规划与 go（阶段 3）

**规划会话**：`plan` 角色，`claude -p` 在后台运行。

- **工作目录**：`~/.orc-worktrees/<mission>/plan-work/`，不在 `$ORC_HOME` 里，因为 guard 不让 agent 写 `$ORC_HOME`。
- **可读**：规划会话能读产品仓库的代码（Read、Grep、`git -C`）。
- **可写**：Write / Edit 只放行 `plan-work/`。Bash 在沙箱里跑，只能写 `plan-work/` 和临时目录；产品仓库在沙箱里 `denyWrite`。**不用 `--add-dir`**：实测它会把目录加进沙箱的可写白名单。
- **记录**：会话 id、pid 和每次运行的序号写进 `planner-start` 事件。包装脚本在会话结束时写 `.runs/<n>.rc`。
- **判断状态**：有 rc 文件，就是“结束了”；没有 rc 文件但进程还在，就是“在运行”；没有 rc 文件、进程也不在，就是“丢了”，按失败处理。拿不准时一律当它还在运行，不重复启动。

**规划会话的产出**写在 `plan-work/` 下：

| 文件 | 内容 |
| --- | --- |
| `design.md` | 设计，外部 PRD 也并进来 |
| `plan.md` | 计划 |
| `task-dag.json` | `validate-task-dag.sh` 的格式。每个节点另外要有：`acceptance`（验收标准列表）、`clauses`（对应的 N# 列表；产品仓库有 NORTHSTAR 时不能为空）、`component`（所属组件）。`mission` 字段必须等于 mission 名，`state` 必须是 `ready` |
| `northstar-constraints.md` | 可选：从设计里挑出的少数关键决定，写成 N# 约束 |
| `QUESTION.md` | 规划需要问用户时只写这一个文件，然后结束本次运行 |

**每次规划会话结束后，orc 做的事**（写 `planner-exit` 事件）：

- **有 `QUESTION.md`**：调用 `block(ask-user)`。用户用 `orc answer` 回答后，orc 用 `claude --resume <同一个会话>` 把回答发回规划会话。
- **产出校验不通过**：把问题发回同一个会话让它修，最多修 2 次；还不通过，就 `block(mediate)`，交给 coordinator 裁决。
- **通过**：把产出复制进 mission 的 `plan/`，写 `plan-ready` 事件，状态进入 `verifying`。

**验证会话**（`verifying`）：在实现之前写好验收测试。见 `proposals/2026-11-07-tests-before-implement.md`。

- **模型**：`review` 角色（目前 Fable 5.1），和执行用的模型不同。启动方式、沙箱、提问、自动修 2 次再 `mediate`，都和规划会话一样。
- **每一轮从头开始**：每次 `planning → verifying` 都清空 `~/.orc-worktrees/<mission>/verify-work/`，新开会话（不 resume 上一轮）。轮内的提问回答和修复仍回到同一个会话。
- **只给**：`spec/design.md`、`spec/task-dag.json`（orc 从 `plan/` 复制）、`repo/`（产品仓库当前提交的副本，没有 `.git`，提交号写进 `verify-snapshot`）、用户在审阅时提过的意见。**不给** `plan.md`，也看不到规划会话的过程。
- **产出**：`repo/` 里新建的测试文件，和工作目录根上的 `checks.json`（`test_files`、`checks`：每个检查有 `id`、`node`、`acceptance`（第几条验收标准）、`command`、`expect_before`（fail / pass））。
- **orc 校验**：每条验收标准至少一个检查；每个节点至少一个 `fail` 检查；测试文件只能是新文件，不能和任何节点的 `files` 重叠，不能在 `.northstar/`、`.github/`、`.git/` 下。
- **实际运行**：orc 从当前提交导出一份干净的代码，只放入列出的测试文件，在 macOS 沙箱（`sandbox-exec`）里逐条运行：只能写这份副本（`TMPDIR` 也指向里面），不能联网，每条最多 300 秒。`fail` 的必须失败，`pass` 的必须通过。产品仓库在验证期间有新提交时停下，`next: error`。
- **通过**：复制进 mission 的 `verify/`，写 `verify-ready`，状态进入 `plan-review`。

**`plan-review`**：

1. orc 用 `plan/` 和 `verify/` 生成审阅页 HTML（验收测试一节列出每个检查、对应的验收标准、实现前的结果和测试全文），交给发布适配层，发布成仅本人可见的 Claude Artifact（`claude -p`，只放行 Read 和 Artifact）。页面变了就带原链接更新，链接不变。
2. 发布成功后写 `published` 事件，发布回执记在 `publish.json`。回执里的哈希和当前页面一致时，不重复发布。
3. 输出 `next: go-gate <链接>`。
4. 发布失败时输出 `next: error`。**不能拿本地文件代替链接去要 go。**

**go 之前的两条路**：

- `orc revise "<意见>"`：只能在 go 之前用。写 `feedback` 事件，状态回到 `planning`，orc 把意见发回同一个规划会话；规划产出再次通过后，验证从头再写一轮（新会话，带上全部意见）。
- `orc go`：用户说 go 之后由 coordinator 运行。orc 依次做这些事：
  1. 把验收测试写进 `control/approved-tests/` 和 `approved-checks.json`；`brief-exec.md` 末尾追加「冻结的验收测试」一节，写明 checks 清单和每个测试文件的 sha256。
     签名的哈希清单仍是复用脚本约定的四个文件（不改复用脚本）；`brief-exec.md` 在清单里，签名就连带覆盖了验收测试。
  2. 写 `control/approved-design.md`、`approved-plan.md`、`brief-exec.md` 和 `approved.sha256`。
  3. 调用 `validate-task-dag.sh --freeze`，把 DAG 冻结成第 4 个文件。
  4. 写 `frozen` 事件。
  5. 如果规划产出了 N# 约束，而且产品仓库有 `.northstar/`，就把约束追加到产品仓库的 `drafts/NORTHSTAR.md`，等用户 `northstar seal`。
  6. 输出 `next: sign <control 目录>`。

**签名**：用户在自己的终端运行 `northstar approve-mission <control 目录>`，按 Touch ID。之后 `orc step` 先跑 `northstar verify-mission`，再跑 `verify-approved-authority.py`，再按 `brief-exec.md` 里的哈希核对 `approved-checks.json` 和 `approved-tests/`（多一个、少一个、改一个都不行），全部通过才进入 `approved`。进入 `approved` 之后每次 step 都重新做这三项。没签名时一直是 `next: sign …`；签名无效时输出 `next: error`，状态停在 `plan-review`。

## 执行（阶段 4）

### 进入 `executing` 时一次性准备

- 产品仓库必须有 `.northstar/NORTHSTAR.md`，而且签名有效（`northstar verify`）：对齐评审（`northstar-review`）要读它，信任层也会在每个会话启动时校验签名，不通过就让 agent 停下。不满足就 `next: error`，请用户签名。`new → planning` 时也做同样的签名校验（仓库有 `.northstar/` 时），免得规划白跑。
- 读 `orc/config/orc.toml` 的 `[execution]`（并发上限、执行会话超时、崩溃重试次数），写进 `exec-setup` 事件，之后不变。
- 从产品仓库当前提交开出 **mission 分支** `orc/<mission>`，放在父 worktree `~/.orc-worktrees/<mission>/integration/`。orc 把冻结的验收测试（`control/approved-tests/`）提交到这个分支上（提交说明 `[orc] 冻结的验收测试`）。节点都从这个分支开出来，所以测试在节点里是**已跟踪的文件**：执行会话改了它，就是改了声明文件以外的文件，提交关口和 broker 都会拒绝。

### 节点

- **调度**：节点 `pending`，前置节点都 `integrated`，声明文件不和任何已启动、未集成的节点重叠，运行中的节点数没到上限，就启动它。每次 step 都重新算。
- **启动**：从 mission 分支当前的提交开出分支 `orc-task/<mission>/<node>`，worktree 在 `~/.orc-worktrees/<mission>/<node>/`。按复用脚本的约定写好控制文件：`control/tasks/<node>/` 的 `worktrees.txt`、`task-state-dir`、`generation`、`accepted-thread-id`、`outcome-nonce`、`state`；`nodes/<node>/` 的 `worktrees.txt`、`state`。
- **执行会话**：`implement` 角色，`claude -p` 在后台运行，工作目录是节点的 worktree。沙箱开、`failIfUnavailable`、不允许脱离沙箱；主仓库 `.git` denyWrite（git 只读）；网络关；Write / Edit 只放行 worktree；环境变量 `ORC_ROLE=implement`、`ORC_NODE=<node>`（Stop hook 据此放行未提交的改动）。实测见 `proposals/2026-11-07-stop-gate-implement.md`。
- **一条验收标准一轮**：执行会话做完一条验收标准就结束这一轮，最后输出一个 JSON 结果（见下）。orc 处理完再用 `claude --resume` 回到同一个会话，发下一条指示。
- **超时和崩溃**：一轮超过 `session_timeout_seconds` 就结束整个进程组，按崩溃处理（提交关口、整体评审、集成内部各有超时：检查每条 300 秒、评审 1800 秒、broker 600 秒）。崩溃（退出码非 0、进程不见了、超时）按 `crash_retries` 重试，重试用同一个会话；再失败，节点 `blocked`。

**执行会话每轮最后输出的 JSON**（只认最后一条消息里的这个对象）：

| `status` | 其他字段 | orc 怎么处理 |
| --- | --- | --- |
| `commit` | `acceptance`（这次完成的第几条，从 1 开始；rework 时可以为空）、`files`（改了哪些文件）、`message`（提交说明）、`notes`（遗留问题，可以为空；写进节点的 `report.md`） | 交给提交关口 |
| `question` | `question` | 节点 `blocked`，mission 进入 `blocked`（ask-user），回答发回同一个会话 |
| `test-wrong` | `check`（检查 id）、`reason` | 交给 `review` 模型判断冻结的测试有没有错（见下） |

格式不对、`files` 和 worktree 里实际改动的文件对不上，都算这一轮没完成，把问题发回同一个会话修，最多修 2 次；第 3 次还不对，节点 `blocked`、mission `mediate`。

### 提交关口（锁外的后台任务；`proposals/2026-11-07-commit-gate.md`）

依次检查，任何一项不过就拒绝，后面的不再做：

1. **文件范围**：worktree 里实际改动的文件都在本节点的 `files` 里；动了冻结的验收测试直接拒绝。
2. **测试哈希**：worktree 里每个冻结的测试文件，和 `brief-exec.md` 里签名的哈希一致。
3. **检查**：跑这次声明完成的验收标准对应的冻结检查，加上本节点此前已经通过的检查。在 worktree 当前内容的副本上、沙箱里运行（同阶段 3：只能写副本、不能联网、每条最多 300 秒），必须全部通过。不通过就拒绝，**不调用评审模型**。
4. **对齐评审**：`northstar-review --role auto`，在节点的 worktree 里运行（它从这里读 NORTHSTAR）；评审模型本身没有任何工具，在仓库外的空临时目录里运行，只看提示词里的材料（`proposals/2026-11-07-reviewer-stop-hook.md`）。输入是本节点的 DAG 条目、签名的 `approved-design.md`、检查结果和这次的 diff；上一次被判 DRIFT 时带上 `--prev`。退出码 0 ALIGNED、1 DRIFT（拒绝，发纠偏单）。退出码 2 时：diff 超过上限就拒绝、要求拆小；其他原因（评审模型不可用等）**不放行、不降级**，节点 `blocked`，mission `ask-user`。
   - 验收标准已经被之前的提交满足（worktree 没有改动，`files` 是 `[]`）：第 3 步的检查通过就记为完成（`satisfied`），没有 diff，不评审、不提交。2026-11-07 真实运行里遇到：第一次提交的实现顺带满足了后面几条验收标准。
5. 全部通过：算出 `diff_sha256`，写提交请求 `nodes/<node>/COMMIT-REQUEST-<n>.json`，把两份 `state` 设成 `ready_for_commit`，运行 `commit-broker.sh --once`。broker 在锁里再做一遍它自己的全部校验，并核对 `diff_sha256`：评审之后改了一个字节都提交不进去。

**连续被拒**（检查不过、DRIFT、范围不对都算；评审服务出错不算）：

- 第 1 次：纠偏单发回同一个会话。
- 第 2 次：把 worktree 里未提交的改动存成补丁（`nodes/<node>/discarded-<n>.patch`），worktree 回到上一次提交通过的状态；新开会话（`generation` 加 1），发完整 brief 和纠偏单。
- 第 3 次：节点 `blocked`，mission `mediate`。裁决之后同样先撤回被拒的改动，再新开会话，带上裁决。
- 提交成功一次，计数清零。

纠偏单写在 `nodes/<node>/correction-<n>.md`：违反了什么（检查 id 和输出、N# 或设计的哪一节）、证据、相关验收标准的原文。

### 冻结的测试有错时

执行会话输出 `test-wrong` 后，orc 用 `review` 模型新开一个只读会话（`claude -p`，只放行 Read），给它设计、本节点的 DAG 条目、测试全文、检查输出和执行会话的理由，要它输出 `{"verdict": "test-ok" | "test-wrong", "reason": "…"}`。

- `test-ok`：带着理由发回执行会话，继续修实现。
- `test-wrong`：节点 `blocked`，mission `ask-user`：改测试要回到写验证这一步，重新审阅、go、签名，由用户决定。

### 整体评审和集成

- 节点每条验收标准都有一次通过的提交后，进入 `submitted`（`nodes/<node>/state` 设成 `completed`，写 `report.md`）。orc 在后台做整体评审：先在节点分支的最新提交上跑本节点全部冻结检查，不通过就 `rework`，不调用模型；通过后用 `northstar-review --role review`，拿整个节点的累计 diff 和检查结果对照签名的设计。DRIFT 时写 `unresolved-rework`，节点回到 `rework`，纠偏单发回执行会话；rework 的提交通过提交关口后，清掉 `unresolved-rework`，再做一次整体评审。
- 整体评审通过：orc 写 `verification.sha`、`coordinator-verification.sha/.md`、`parent-verification.sha`，然后在后台运行复用的 `integrate-task.sh`。集成一次只跑一个，脚本自己再拿集成锁，普通 merge，不改写历史。
- 所有节点都 `integrated` 后，进入 `reviewing` 之前，orc 不只信日志，从协议文件重新算一遍：每个节点 `control/tasks/<node>/state` 是 `integrated`，记录的 `integrated_sha` 确实在 mission 分支上。和日志不一致就 `next: error`。

### 后台任务和事件

执行会话、提交关口、整体评审、集成、判断测试对错，都是后台任务：orc 在锁里启动它，写 `job-start`；任务自己跑（broker 和 integrate-task 会自己拿锁）；下一次 `orc step` 读到它的退出码文件，处理结果，写 `job-exit`。运行文件放在 `~/.orc-worktrees/<mission>/.jobs/`。`orc wait` 等到任何一个后台任务结束就返回。

| `kind` | 额外字段 |
| --- | --- |
| `exec-setup` | `base`、`branch`、`parent_worktree`、`tests_commit`、`config` |
| `node-start` | `node`、`base`、`branch`、`worktree` |
| `job-start` | `job`、`type`（executor / gate / submit / dispute / integrate）、`node`、`pid`；执行会话另有 `session`、`mode`、`generation` |
| `job-exit` | `job`、`type`、`node`、`rc`、`outcome`，以及按类型的结果（执行会话的 JSON、关口的结论和理由、提交的 sha） |

`node-state`、`commit`、`review`、`correction`、`check` 沿用上表。

## `orc step` 的约定

- 每次运行：拿锁 → 对齐 `state` 与日志 → 执行当前状态的一段机械流程 → 写日志和状态 → 放锁 → 最后一行打印 `next: …`。
- **可以重复运行**：同一状态下重复运行，输出相同，不追加重复事件。
- **中断后再跑一次就能接上**：先写事件再更新 `state`；中断在两者之间时，下次运行按日志补齐。
- `next:` 只有这几种：`ask-user <问题>`、`go-gate <链接>`、`sign <control 目录>`、`mediate <文件>`、`report <链接>`、`wait`、`error <错在哪、该怎么做>`。
- `wait` 表示后台有进程在跑（规划会话或验证会话）。coordinator 在后台运行 `orc wait --mission <m>`，它返回后再运行 `orc step`。
- 所有拒绝和报错都写明错在哪、该怎么做。
