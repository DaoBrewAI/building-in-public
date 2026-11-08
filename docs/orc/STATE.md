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
| `reviewing` | 最终审查、开 PR、等 CI、写状态页（阶段 5） | 审查通过、CI 通过、重新核对一致、状态页已发布；审查打回节点时回到 `executing` | `accepted`（或 `executing`） |
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
- **检查挂在哪个节点上**（2026-11-08 加，brief 里的规则，orc 不自动判断）：挂在节点 X 上的检查只能依赖 X 和它前置节点的改动；跑整套测试这类检查挂在依赖了所有相关节点的节点上。起因：mission `subtract` 实跑时，跑整套测试的检查挂在了前置节点上，要等后续节点做完才会通过，节点永远完成不了。
- **orc 校验**：每条验收标准至少一个检查；每个节点至少一个 `fail` 检查；测试文件只能是新文件，不能和任何节点的 `files` 重叠，不能在 `.northstar/`、`.github/`、`.git/` 下。
- **检查用的副本**（验证、提交关口、最终审查都一样）：`git clone --shared` 产品仓库再检出对应提交，不跑 git hook。产品仓库自己的检查要用 git（daoharness-core 的 `core_checks.py` 用 `git ls-files`、`git merge-base origin/main HEAD` 比起点），所以副本不能只是文件（`proposals/2026-11-08-checks-need-git.md`）。`--shared` 只读产品仓库的对象，不写它；副本里的 `origin/<分支>` 就是产品仓库本地的分支。给验证会话读的 `repo/` 和给评审模型看的副本仍然只有文件。
- **实际运行**：orc 用当前提交做一份干净的副本（带 git 历史，见下面「检查用的副本」），只放入列出的测试文件，在 macOS 沙箱（`sandbox-exec`）里逐条运行：只能写这份副本（`TMPDIR` 也指向里面），不能联网，每条最多 300 秒。`fail` 的必须失败，`pass` 的必须通过。产品仓库在验证期间有新提交时停下，`next: error`。
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
| `commit` | `acceptance`（这次完成的第几条，从 1 开始；rework 时可以为空）、`files`（改了哪些文件）、`message`（提交说明：第一行一句话；仓库约定要求的正文空一行写在后面，orc 原样保留，第一行前面加 `[N#] 节点名：`）、`notes`（遗留问题，可以为空；写进节点的 `report.md`） | 交给提交关口 |
| `question` | `question` | 节点 `blocked`，mission 进入 `blocked`（ask-user），回答发回同一个会话 |
| `test-wrong` | `check`（检查 id）、`reason` | 交给 `review` 模型判断冻结的测试有没有错（见下） |

格式不对、`files` 和 worktree 里实际改动的文件对不上，都算这一轮没完成，把问题发回同一个会话修，最多修 2 次；第 3 次还不对，节点 `blocked`、mission `mediate`。

### 提交关口（锁外的后台任务；`proposals/2026-11-07-commit-gate.md`）

依次检查，任何一项不过就拒绝，后面的不再做：

1. **文件范围**：worktree 里实际改动的文件都在本节点的 `files` 里；动了冻结的验收测试直接拒绝。
2. **测试哈希**：worktree 里每个冻结的测试文件，和 `brief-exec.md` 里签名的哈希一致。
3. **检查**：跑这次声明完成的验收标准对应的冻结检查，加上本节点此前已经通过的检查。在 worktree 当前内容的副本上（worktree 的 HEAD 带 git 历史，再盖上没提交的改动）、沙箱里运行（同阶段 3：只能写副本、不能联网、每条最多 300 秒），必须全部通过。不通过就拒绝，**不调用评审模型**。
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

## 验收（阶段 5）

四件事开工前由林翰定下，见 `proposals/2026-11-08-phase5-open-points.md`：orc 开 PR、你合并；集成的合并提交带 `[N#]`；隐藏考题放在 agent 的 token 访问不到的 `DaoBrewAI/LY_orchestrator-hub`；最终审查不通过时重新打开节点。

`reviewing` 里按顺序做下面几步。每一步的结果都按 mission 分支当时的 tip 记在日志里：同一个 tip 已经通过的步骤不重做；没通过、停下问过用户之后再运行，就重做这一步。

### 1. 最终审查（后台任务 `final`）

- 用 mission 分支的 tip 做一份检查用的副本（带 git 历史），在沙箱里重跑**全部**冻结检查，再跑产品仓库自己的 `.northstar/checks/run_all.sh`（有的话）。规则同提交关口：只能写副本、不能联网、每条最多 300 秒。
- 有冻结检查没通过：按检查所属的节点打回，**不调用模型**。`run_all.sh` 没通过时落不到节点，停下 `mediate`。
- 检查都通过：`review` 角色的模型（`claude -p`，只放行 Read）在仓库外的临时目录里看代码副本。副本不带 `.northstar/` 和 `.github/`，Stop hook 不会拦它。提示词里有 NORTHSTAR、签名的设计、DAG、检查结果和整个 mission 的 diff；diff 超过 60000 字节就只给文件列表，让它用 Read 看。模板 `orc/templates/final-review-brief.md`。它最后输出 `{"verdict": "pass" | "fail", "issues": [{"node", "problem", "evidence"}]}`；每个问题必须落在一个 DAG 节点上。格式不对、节点不存在、模型出错，都**不放行、不降级**，停下 `ask-user`，回答后重做。

### 2. 打回节点（审查不通过）

- 对每个被点名的节点（重新打开，`node-reopen` 事件）：
  - 节点的 worktree 和分支快进到 mission 分支的 tip（它已经包含全部节点的改动），控制文件里的基线也改成这个 tip，之后的提交关口、整体评审和集成只看这次的修复；
  - 控制文件的 `state` 改回 `ready`，写 `unresolved-rework` 和纠偏单，节点状态 `integrated → rework`；
  - mission `reviewing → executing`；执行会话 `--resume` 回到同一个会话，收到纠偏单。
- 之后和阶段 4 一样：提交关口、整体评审、`integrate-task.sh` 再合并一次（对同一个分支再合并，复用脚本不用改），全部集成后回到 `reviewing`，新的 tip 再做一次最终审查。
- 最多打回 2 轮。第 3 次不通过就熔断，mission `blocked`（`mediate`），回答后重新做最终审查，计数清零。

### 3. PR 和 CI（后台任务 `ci`）

- 产品仓库没有 `origin` 时停下（`next: error`），说明要先建远程仓库。不跳过。
- 把 `orc/<mission>` 推到 `origin`，用 `gh` 开一个指向默认分支的 PR；已经有这个分支的 open PR 就用它。记 `pr` 事件。**合并由你来做。**
- 等 CI：每隔 20 秒查一次 `gh pr checks`，直到 `orc/config/orc.toml` 的 `[acceptance] required_checks`（默认 `verify,exam`）每一个都出现并结束，最多 `ci_timeout_seconds`。只有 `pass` 算通过；`skipping`（草稿 PR 上跳过的考题）不算。PR 的 head 不是审查过的 tip 时直接判失败。
- CI 没通过、超时：停下 `ask-user`。隐藏考题只报通过或失败，orc 不知道是哪一题，所以不自动打回节点。回答后只重等 CI，不重做最终审查。

### 4. 进入 `accepted` 前重新核对

不只信日志里的记录，重新核对：每个节点的协议文件是 `integrated` 且集成提交在 mission 分支上；mission 分支的 tip 就是最终审查看过的那个；最终审查的记录里全部冻结检查都跑了、都通过；`gh pr view` 查到的 PR head 就是这个 tip；CI 记录里 `required_checks` 全部是 `pass`。任何一项对不上就 `next: error`。

### 5. 状态页

- **说明**（后台任务 `notes`）：用 `plan` 角色的模型，没有任何工具，在仓库外的空目录里，只按提示词里的材料（请求、设计、提交列表、检查、diff）写 5 到 15 行 Markdown 列表。模板 `orc/templates/status-notes-brief.md`。orc 按 `northstar-status` 的规则核对：每行至少一个引用（`[commit:…]`、`[check:…]`、`[file:路径:行号]`）；引用的提交、检查、文件和行号都要存在；每个提交都要被引用；不能写「完成」「passed」这类进度判断。不合格就把问题发回去重写，2 次还不行就 `mediate`。
- **页面**由 orc 生成（`render_status`），不交给模型：流程条、按组件分组的架构图（颜色是合并后代码上的检查结果）、**每个 DAG 节点一行**（状态、冻结检查、提交、集成提交、纠偏次数）、最终审查每一轮、PR 和 CI、清理结果，最后是核对过的说明。每条事实后面标着它在 `events.jsonl` 里的行号。
- 发布成仅本人可见的 Artifact（`publish.json` 的 `status`），之后更新同一个链接。发布成功后 mission 进入 `accepted`。

### 6. 清理（`accepted → cleaned`）

- 清单只来自 orc 自己记录过的：每个节点控制目录的 `worktrees.txt`（worktree 和分支），以及 `exec-setup` 记录的父 worktree。**先把清单打印出来，再执行。**
- 删 worktree 前确认它在 `git worktree list` 里、没有未提交的改动；删分支前确认它已经合进 mission 分支。任何一项不满足就停下，不删。
- mission 分支 `orc/<mission>` 保留：PR 还没合并。记 `cleanup` 事件（删了什么、留了什么），进入 `cleaned`。
- `cleaned` 时重新生成状态页（加上清理结果）并更新同一个链接，然后输出 `next: report <状态页链接>`。没有状态页就不输出 `report`。

### 事件

| `kind` | 额外字段 |
| --- | --- |
| `job-start` / `job-exit` | 新的任务类型 `final`、`ci`、`notes`，`node` 是 `_mission`，另带 `tip`。`final` 的结果有 `checks`、`review`、`issues`；`ci` 有 `pr`、`checks`（检查名 → pass / fail / pending …） |
| `node-reopen` | `node`、`base`（新的基线，即当时的 tip）、`card`、`round` |
| `pr` | `url`、`number`、`tip`、`branch` |
| `cleanup` | `removed`、`kept` |

`check` 和 `review` 事件在最终审查时 `node` 为空、`stage` 是 `final`。

## 产品层（阶段 6）

开工前定下的事见 `proposals/2026-11-08-phase6-open-points.md`。前面的阶段只认识单个 mission；这一层让 orc 认识产品设计和 phase。NORTHSTAR 不加任何内容。

### 产品

- `orc product <产品> --design <产品设计文档> --phases <phase 文档目录> --missions <mission 文档目录> --repo <名字>=<本机路径> …` 在 orc 的数据目录下写 `products/<产品>/product.toml`。产品的事件记在同一目录的 `events.jsonl`（`configured`、`canvas-draft`、`mission-start`、`merged`、`manual-done`、`phase-conclusion`）。
- phase 启动的 mission 名是 `<产品>-<mission id 小写>`，mission 目录里多三个文件：`product`、`phase`、`mission-id`。

### 画布

- `orc canvas --product <产品> --repo <名字>`：`plan` 角色的模型（没有工具，在空目录里）读产品设计文档和仓库的文件列表，起草 `{"components": [{"id", "name", "paths", "depends_on"}]}`。orc 校验：id 合法不重复、paths 非空、依赖的组件存在、仓库现有文件（`.northstar/`、`.github/`、`drafts/`、`proposals/`、`status/` 以外）都落在某个组件里；不过就把问题发回去重写，最多 3 次。
- 通过后写进产品仓库的 `drafts/architecture.json`，发布一页画布给用户看，输出 `next: canvas <链接>`。用户运行 `northstar seal` 把它签进 `.northstar/architecture.json`，之后 agent 改不了（guard 拦 `.northstar/`）。格式就是 `northstar-scope` 和 `northstar-status` 读的那个，`depends_on` 也是 `northstar-status` 画图用的字段。

### 规划校验（加在阶段 3 的校验后面）

- 仓库有签名的画布时，DAG 节点的 `component` 只能是画布里的组件 id。
- mission 文件头有 `scope:` 时，节点的组件必须在 scope 里，`files` 必须落在这些组件的 paths 里；有 `forbid:` 时，`files` 不能碰到。
- `design.md` 有「推翻的已有决定」一节时，每一条都要带 `[answer:<编号>]`，引用用户对规划会话提问的回答。规划会话不能自己决定推翻（`planner-brief.md` 也这样写）。发给规划会话的回答带着编号。
- 不过的都按阶段 3 的规则发回规划会话修，2 次不行就 `mediate`。

### scope 和 forbid 接成硬规则

- `orc go` 把 mission 文件头的 `scope` 和 `forbid` 写进 `brief-exec.md`，和设计一起冻结、由用户 `approve-mission` 签名。不改复用的 `verify-approved-authority.py`（它只认 4 个冻结文件）。
- 执行会话的环境变量带 `ORC_MISSION_CONTROL=<control 目录>`。信任层的 `northstar-scope` 看到它时，先 `northstar verify-mission` 验签名、再验 `brief-exec.md` 的哈希，然后从里面读 scope 和 forbid；任何一项不对就返回 3（停下）。`guard.sh` 对这样的会话也跑范围围栏：碰到 forbid 停下，越出 scope 拦住。
- 不用 `.northstar/missions/ACTIVE`，同一个仓库里的多个 mission 可以并行，也不用每个 mission 多签两次（`northstar start` / `finish`）。要用户重新 sudo 安装信任层才生效。

### phase

- phase 文档要有标题含「依赖」的一节，每个 mission 一行：`- P1-1：无`、`- P1-4：依赖 P1-2`、`- P1-5a：依赖 P1-1、P1-2`。mission 文件在 mission 目录里，文件名是 `<id>.md` 或 `<id>-<说明>.md`；文件头 `仓库: <名字>`（产品配置里的仓库），orc 做不完的写 `执行: 人工`。依赖表缺失、mission 文件找不到或多于一个、依赖不存在、有环、仓库没写或不认识，都 `next: error` 说明。
- `orc phase --product <产品> --phase <P>` 走一步：
  1. 已清理、等合并的 mission：`gh pr view` 查 PR 合并了没有，合并了记 `merged`。
  2. 依赖都完成的 mission：从产品仓库默认分支的最新提交开始（工作区必须干净、在默认分支上，先 fast-forward），请求就是 mission 文件全文。没有依赖关系的同时启动；但同一个仓库里 `scope` 有重叠（或没写 scope）的，等前一个合并后再开始：它们的 PR 都从同一个 main 开始，先合并的会让后一个冲突（和节点层面「并行的节点文件不重叠」同一条规则）。
  3. 进行中的 mission 各走一步（`orc step`）；有要人处理的（go-gate、sign、ask-user、mediate、error），交出第一个，前面带 `[mission 名]`。
  4. 人工 mission 依赖都完成时列成待办：用户做完运行 `orc done --product <产品> --phase <P> <mission>`。orc 跑的 mission 不能手动标完成：它的 PR 合并了才算。
  5. 全部完成后，`review` 模型（没有工具）对照 phase 文档的「完成标准」逐条给结论：`met`、`not-met`、`needs-human`（要人亲手验收的，写清楚人要做什么，orc 不代做）。记 `phase-conclusion`，输出 `next: report <汇总页链接>`。
- 放弃：用户决定放弃一个 mission 时运行 `orc abandon --mission <m> "<原因>"`（后台会话还在跑时不行）：记 `abandoned`，转到 `failed`，分支、worktree 和记录都留着，不清理。phase 里这个编号算「没开始」，下一次 `orc phase` 用新名字（`<产品>-<编号>-2`、`-3`）重新开始；编号对应哪个 mission 看最近一次 `mission-start`。自己失败的 mission（没有 `abandoned`）不会自动重开。
- 等合并时 `orc wait --product <产品> --phase <P>` 每 120 秒（`ORC_MERGE_POLL_SECONDS`）返回一次，让 `orc phase` 再去查。

### 跨 mission 评审（mission 的 `reviewing` 里，最终审查之后、开 PR 之前）

- 只对属于某个产品的 mission。后台任务 `cross`：`review` 模型（只放行 Read，在仓库外的临时目录里看合并后的代码副本，不带 `.northstar/`、`.github/`）。材料：NORTHSTAR、产品设计文档、画布、此前已合并的同一产品 mission 签名的设计、这个 mission 签名的设计、它的「推翻的已有决定」、DAG 和完整 diff（超过 60000 字节只给文件列表）。模板 `orc/templates/cross-review-brief.md`。
- 输出 `{"verdict": "pass" | "conflict", "issues": [{"node", "problem", "evidence"}], "overrides_applied": [...]}`。冲突就和最终审查一样重新打开问题所属的节点（`node-reopen` 的 `stage` 是「跨 mission 评审」），不开 PR；最多打回 2 轮，第 3 次熔断 `mediate`。格式不对、节点不存在、模型出错：不放行、不降级，`ask-user`。
- 冲突规则写在评审的提示词里：默认以已经合并的为准；只放行「推翻的已有决定」里逐条写明的；推翻 NORTHSTAR 条款的，NORTHSTAR 原文必须已经改过。
- 事件：`job-exit`（`type` 是 `cross`）、`review`（`stage` 是 `cross`，`verdict` 是 PASS / CONFLICT）。

### 汇总页

全产品一个，`publish.json` 的 `summary`，链接不变；每次 `orc phase` 结束时重新生成，内容变了才重新发布。全部来自事件记录：

- **画布着色图**：每个仓库一张（底图是签名的画布）。组件的颜色看改过它的 mission：都已合并是绿色，有进行中的是黄色，没有是灰色。点开看是哪个 mission 的哪个节点、哪次提交，带日志行号。
- **NORTHSTAR 条款表**：每条 N# 一行（读各仓库的 NORTHSTAR），列出由哪些 mission 的哪些节点实现（DAG 的 `clauses`）、提交、被 DRIFT 打回的次数、状态。没有任何 mission 实现的条款标红。
- **phase 和 mission**：每个 phase 的完成数；每个 mission 一行：状态、仓库、状态页链接、跨 mission 评审结论、PR。phase 有结论时逐条列出，`needs-human` 的就是交给你的验收清单。

## `orc step` 的约定

- 每次运行：拿锁 → 对齐 `state` 与日志 → 执行当前状态的一段机械流程 → 写日志和状态 → 放锁 → 最后一行打印 `next: …`。
- **可以重复运行**：同一状态下重复运行，输出相同，不追加重复事件。
- **中断后再跑一次就能接上**：先写事件再更新 `state`；中断在两者之间时，下次运行按日志补齐。
- `next:` 只有这几种：`ask-user <问题>`、`go-gate <链接>`、`sign <control 目录>`、`mediate <文件>`、`report <链接>`、`wait`、`error <错在哪、该怎么做>`。
- `report <链接>` 只在 `cleaned` 时输出，链接是最新的状态页。
- `wait` 表示后台有进程在跑（规划会话、验证会话，或执行、验收阶段的后台任务）。coordinator 在后台运行 `orc wait --mission <m>`，它返回后再运行 `orc step`。
- 所有拒绝和报错都写明错在哪、该怎么做。
