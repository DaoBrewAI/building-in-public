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
  plan/               规划会话的产出（阶段 3）：design.md、plan.md、task-dag.json、审阅页 HTML
  control/            coordinator 的权威目录 = 复用脚本的 control root；锁文件也在这里
    approved-design.md  approved-plan.md  brief-exec.md  approved-task-dag.json
    approved.sha256     approved.sha256.sig（northstar approve-mission 的签名）
    tasks/<node>/     每个节点的控制目录（broker、integrate-task 的 --control-dir）
  nodes/<node>/       每个节点的工作侧目录（broker 的 --mission-dir、integrate-task 的 --task-dir）
```

节点的 git worktree **不在 mission 目录里**，放在 `~/.orc-worktrees/<mission>/<node>/`（环境变量 `ORC_WORKTREES` 可改根目录）。原因：guard 拦截 agent 对 `$ORC_HOME` 的一切写入，worktree 放在里面，节点就写不了代码；guard 也不给任何路径开例外，例外路径容易被利用。`ORC_WORKTREES` 落在 `$ORC_HOME` 之内时 orc 直接报错，`orc doctor` 也会检查。worktree 在阶段 4 创建，路径登记在 `control/tasks/<node>/worktrees.txt`；清理只删登记过的。

`control/` 和 `nodes/` 里的文件格式沿用复用脚本的约定（`worktrees.txt` 一行四列：worktree、分支、base、仓库，用制表符分隔；`generation`、`state` 等单行文件），orc 不另起一套。

## mission 状态

```
new → planning → plan-review → approved → executing → reviewing → accepted → cleaned
```
外加 `blocked`（等用户）和 `failed`（不可恢复，终态）。

| 状态 | 含义 | 离开的条件（由 `orc step` 判断） | 下一个状态 |
| --- | --- | --- | --- |
| `new` | 刚建好目录，记录了请求和模型 | 无条件 | `planning` |
| `planning` | 规划会话在产出设计、计划、DAG（阶段 3） | 产出齐全且 `validate-task-dag.sh` 通过 | `plan-review` |
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
- **通过**：把产出复制进 mission 的 `plan/`，写 `plan-ready` 事件，状态进入 `plan-review`。

**`plan-review`**：

1. orc 用 `plan/` 生成审阅页 HTML，交给发布适配层，发布到 Sites 的 `/plan`。
2. 发布成功后写 `published` 事件，发布回执记在 `publish.json`。回执里的哈希和当前页面一致时，不重复发布。
3. 输出 `next: go-gate <链接>`。
4. 发布失败时输出 `next: error`。**不能拿本地文件代替链接去要 go。**

**go 之前的两条路**：

- `orc revise "<意见>"`：只能在 go 之前用。写 `feedback` 事件，状态回到 `planning`，orc 把意见发回同一个规划会话。
- `orc go`：用户说 go 之后由 coordinator 运行。orc 依次做这些事：
  1. 写 `control/approved-design.md`、`approved-plan.md`、`brief-exec.md` 和 `approved.sha256`。
  2. 调用 `validate-task-dag.sh --freeze`，把 DAG 冻结成第 4 个文件。
  3. 写 `frozen` 事件。
  4. 如果规划产出了 N# 约束，而且产品仓库有 `.northstar/`，就把约束追加到产品仓库的 `drafts/NORTHSTAR.md`，等用户 `northstar seal`。
  5. 输出 `next: sign <control 目录>`。

**签名**：用户在自己的终端运行 `northstar approve-mission <control 目录>`，按 Touch ID。之后 `orc step` 先跑 `northstar verify-mission`，再跑 `verify-approved-authority.py`，两项都通过才进入 `approved`。没签名时一直是 `next: sign …`；签名无效时输出 `next: error`，状态停在 `plan-review`。

## `orc step` 的约定

- 每次运行：拿锁 → 对齐 `state` 与日志 → 执行当前状态的一段机械流程 → 写日志和状态 → 放锁 → 最后一行打印 `next: …`。
- **可以重复运行**：同一状态下重复运行，输出相同，不追加重复事件。
- **中断后再跑一次就能接上**：先写事件再更新 `state`；中断在两者之间时，下次运行按日志补齐。
- `next:` 只有这几种：`ask-user <问题>`、`go-gate <链接>`、`sign <control 目录>`、`mediate <文件>`、`report <链接>`、`wait`、`error <错在哪、该怎么做>`。
- `wait` 表示后台有进程在跑（比如规划会话）。coordinator 在后台运行 `orc wait --mission <m>`，它返回后再运行 `orc step`。
- 所有拒绝和报错都写明错在哪、该怎么做。
