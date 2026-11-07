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
  worktrees/<node>/   节点的 git worktree（阶段 4 创建；清理只删这里登记过的）
```

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

状态页和排查都只读这个文件。

## models.json

`orc step --new` 时解析 `orc/config/models.toml`，写成：

```json
{"source": "<models.toml 的路径>", "sha256": "<文件哈希>", "resolved_at": "<时间>",
 "roles": {"implement": {"cli": "codex", "model": "…", "effort": "high"},
           "plan_review": {"cli": "claude", "model": "…", "effort": "high", "fallback": "…"}}}
```

之后 orc 只读 `models.json`，不再读 `models.toml`；改 `models.toml` 只影响新 mission。

## `orc step` 的约定

- 每次运行：拿锁 → 对齐 `state` 与日志 → 执行当前状态的一段机械流程 → 写日志和状态 → 放锁 → 最后一行打印 `next: …`。
- **可以重复运行**：同一状态下重复运行，输出相同，不追加重复事件。
- **中断后再跑一次就能接上**：先写事件再更新 `state`；中断在两者之间时，下次运行按日志补齐。
- `next:` 只有这几种：`ask-user <问题>`、`go-gate <链接>`、`mediate <文件>`、`report <链接>`、`wait`、`error <错在哪、该怎么做>`。
- 所有拒绝和报错都写明错在哪、该怎么做。
