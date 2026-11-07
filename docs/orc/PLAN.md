# 新 workflow（orc）+ 信任层：执行计划

## 给执行这份计划的 agent（Claude Code）

- 这份计划放在仓库的 `docs/orc/`。按阶段顺序执行，**每个阶段一个分支、一个 PR**。
- 标【你】的步骤属于用户本人。走到这里时：**停下**，把用户需要做的事和具体命令打印出来，等用户回复 `done` 再继续。
- 你**绝不**执行：`sudo`、任何 `northstar seal / start / finish / approve-mission`、`ssh-keygen -Y sign`、修改 GitHub 设置、在 Codex 里信任 hook、切换凭证。
- 「已确定的决定」不得改动。发现某条行不通，写进 `docs/orc/proposals/<日期>-<主题>.md`，然后停下等用户。
- 每个阶段结束前跑全部测试，并按「完成标志」逐条自检，在 PR 描述里列出证据（命令和输出）。

## 已确定的决定

| 项目 | 决定 |
| --- | --- |
| 方向 | 新建 workflow `orc`；旧 orchestrator 里能用的脚本连同测试直接搬过来，其余重写（见 REUSE.md） |
| 原则 | 流程交给代码，判断留给模型。新增约束放进脚本，不往 skill 里加文字 |
| coordinator | 一个 Claude Code 会话，带约 450 词的薄 skill，循环执行 `orc step` |
| 模型 | **2026-11-07 改**（见 `proposals/2026-11-07-claude-implement.md`）：实现和规划用 Claude Opus（目前 `claude-opus-5-5`）；重要、复杂的评审用 Claude 当前最强（目前 `claude-fable-5-1`，不降级，不能和实现用同一个模型），简单评审用 Opus。分级规则写在代码里。按"最强"由用户手动更新，名字只写在 `config/models.toml` |
| 子任务 | **2026-11-07 改**：`claude -p`（Claude Code 无界面模式）后台运行，每个任务一个独立 worktree；开沙箱，主仓库 `.git` 设 denyWrite |
| 并发 | 第一版就支持并行：DAG 里声明文件互不重叠、前置都已集成的节点同时跑；集成按顺序加锁 |
| 提交 | 子任务一律通过 commit broker 提交（执行会话的沙箱对主仓库 `.git` denyWrite，git 只读，已实测）；broker 里由 Claude 做对齐评审，偏离就拒绝并发纠偏单 |
| 验证 | **2026-11-07 加**（见 `proposals/2026-11-07-tests-before-implement.md`）：验收测试和检查在设计之后、实现之前，由一个独立的会话写好（`review` 角色的模型，和执行用的不同；看不到规划过程和计划）。每个检查都要先在当前代码上实际跑一遍：测新行为的必须失败。测试随设计、计划一起冻结签名；执行阶段只能读、不能改，只有这些检查算数 |
| 给人看的页面 | **2026-11-07 改**（见 `proposals/2026-11-07-review-page-artifacts.md`）：计划审阅页和状态页都发布成仅本人可见的 Claude Artifact，手机和电脑都能看。原来是 OpenAI Sites。**2026-11-07 加**（见 `proposals/2026-11-07-cross-mission-review.md`）：另有一个全产品的汇总页，也是 Artifact，链接不变，每完成一个 mission 更新一次 |
| 产品设计和 phase | **2026-11-07 加**（见 `proposals/2026-11-07-cross-mission-review.md`）：四层，产品设计文档 → NORTHSTAR → phase → mission。orc 从产品设计文档起草画布（组件、连线、组件对应的目录），写成 `.northstar/architecture.json`，用户签名后 agent 改不了；DAG 节点的组件只能从画布里选。orc 按 phase 文档里的依赖启动 mission。每个 mission 合进主线前做一次跨 mission 评审（`review` 模型，不降级）：默认以已合并的为准，冲突就退回重做；只有签名设计里「推翻的已有决定」一节写明的才放行。mission 的 `scope` 和 `forbid` 由信任层硬拦截，不进 NORTHSTAR |
| 签名 | 单台 Mac，Secretive + Touch ID；你说 go 之后用 `northstar approve-mission` 签名 |
| 默认参数 | 每次提交最多 8 个文件；同一节点连续偏离 3 次熔断；并发上限写在配置里 |

## 文件夹里有什么

| 路径 | 内容 |
| --- | --- |
| `PLAN.md` | 本文件 |
| `REUSE.md` | 旧 orchestrator 每个脚本的去向：直接复用、参考重写、不要 |
| `northstar-staging/` | 信任层的全部文件，已写好并通过冒烟测试 |
| `slim/SKILL.md` | coordinator 的薄 skill 草稿 |
| `orc/config/models.toml`（仓库根目录） | 模型角色配置，唯一写模型名的地方（原 `slim/config/models.toml`，阶段 2 移过去） |

## 阶段总览

| 阶段 | 目标 | 你要做的 | 完成标志 |
| --- | --- | --- | --- |
| 0 准备 | 材料就位，确认前提 | 建签名密钥，确认 Astra 和 codex exec 可用 | 见阶段 0 |
| 1 信任层 | 签名、hook、CI 终审装好 | 审阅、sudo 安装、GitHub 设置 | 验收全部通过 |
| 2 骨架 | 新仓库结构、复用脚本搬入、状态模型、`orc` 骨架 | 审 PR | 搬入的旧测试全部通过 |
| 3 规划与 go | 规划 → 验收测试 → 审阅页发布成 Artifact → 你说 go → 签名 | 确认发布方式；签一次名 | 未签名进不了执行 |
| 4 并行执行 | 调度、子任务、broker 对齐评审、纠偏、集成 | 审 PR | 并行与纠偏的契约测试全部通过 |
| 5 验收与状态页 | 最终审查、派生状态页发布成 Artifact、清理 | 审 PR，抽查状态页 | 状态页每条可追溯 |
| 6 产品层 | 画布、phase、跨 mission 评审、汇总页、scope 拦截 | 签画布，审 PR | 冲突被退回，汇总页每条可追溯 |
| 7 试运行 | 薄 skill，玩具仓库端到端，再跑一个真实小 mission | 跑真实 mission | 全流程无人工修补 |

---

## 阶段 0：准备（全部由你完成）

- [ ] **【你】** 决定新 workflow 放在哪：building-in-public 里新开一个 `orc/` 目录，或者新建仓库。把整个文件夹复制到其中的 `docs/orc/`。
- [ ] **【你】** 安装 Secretive，新建 key，名字填 `northstar`。⚠️ **必须勾选 Require Authentication**，创建后改不了。把公钥保存为 `docs/orc/northstar-staging/northstar_signing.pub`。
- [ ] **【你】** 确认 Touch ID 只登记了你自己的指纹。
- [ ] **【你】** 确认 `codex exec -m gpt-6-astra "say ok"` 和 `claude -p --model claude-fable-5-1 "say ok"` 都能返回结果。
- [ ] **【你】** `brew install jq`。

## 阶段 1：信任层

- [ ] **【Claude Code】** 在临时测试仓库里对 `northstar-staging/` 做功能测试：用临时测试密钥跑通 `seal / verify / start / finish / approve-mission / verify-mission`；用伪造的 hook 输入测试 `guard.sh` 的拦截与放行；测 `northstar-scope` 的三种返回值；测 `align.sh`（评审命令替换成返回固定 ALIGNED / DRIFT 的假脚本）。测试放进 `docs/orc/northstar-staging/tests/`，发现问题就改，并在 PR 里说明。
- [ ] **【你】** 逐个读 `northstar-staging/`，重点是 `install.sh` 和 `hooks/guard.sh`。
- [ ] **【你】** `sudo bash docs/orc/northstar-staging/install.sh`。⚠️ 会覆盖 `managed-settings.json` 和 `~/.codex/hooks.json`（自动备份为 `.bak`）；原来有自定义 hook 的话，先让 Claude Code 合并进 staging 的两个 JSON。
- [ ] **【你】** 在 Codex 里运行 `/hooks`，审核并信任四个 hook。
- [ ] **【你，网页】** GitHub：建模板仓库（放入 `repo-template/`）；产品仓库建变量 `NORTHSTAR_ALLOWED_SIGNERS`、main 开分支保护（required check：`northstar / verify`）；建 agent 专用 fine-grained token（Contents、Pull requests 读写，Metadata 只读；**不给** Workflows、Administration、Variables、Secrets）；产品仓库是私有的话，确认 Actions 花费上限是 $0（默认值），用完免费分钟数时 CI 停下而不是扣费。
- [ ] **【你】** ⚠️ 先推完所有 workflow，**再** `gh auth login --with-token` 换成 agent 专用 token。
- [ ] **【Claude Code + 你旁观】** 在测试产品仓库里验收：`northstar init`，你 `northstar seal`；让 Claude Code 和 Codex 各尝试写 `.northstar/test` 和运行 `northstar seal`，确认都被拦下；开新会话问"N1 原文是什么"，确认注入生效。

**完成标志**：验收全部通过，记录在 PR 描述里。

## 阶段 2：骨架

- [ ] **【Claude Code】** 按 REUSE.md 把"直接复用"的脚本连同它们的测试搬进新仓库，只改路径和目录约定，不改逻辑；搬入的测试全部通过。
- [ ] **【Claude Code】** 写一页 `docs/orc/STATE.md`，定义状态模型：
  - mission 目录结构；状态只有 `new → planning → plan-review → approved → executing → reviewing → accepted → cleaned`，外加 `blocked`、`failed`
  - 每个 DAG 节点的状态：`pending → running → submitted → integrated`，外加 `rework`、`blocked`
  - 一份只追加的事件日志 `events.jsonl`：每次状态变化、提交、评审结论、纠偏都记一行，状态页和排查都从它读
  - mission 开始时把 `config/models.toml` 解析出的模型写进 mission 目录，之后不再改变
- [ ] **【Claude Code】** 写 `orc` 骨架（Python）：`orc step --new "<请求>"` / `orc step --mission <m>`、`orc answer`、`orc status`、`orc doctor`。`step` 每次读状态、执行一段机械流程、打印一行 `next:`，可以重复执行（同一状态下重复运行结果相同），中断后再跑一次就能接上。所有拒绝和报错都写明"错在哪、该怎么做"。
- [ ] **【Claude Code】** `orc doctor` 检查：信任层已安装、models.toml 里的模型可用、角色用到的命令（claude，有角色用 codex 时也查 codex）存在、审阅页发布可用。
- [ ] **【你】** 审 PR。

**完成标志**：搬入的旧测试全部通过；`orc step` 在空 mission 上能走到 `planning` 并打印正确的 `next:`。

## 阶段 3：规划与 go

- [ ] **【Claude Code】** 规划阶段：`orc` 用 `plan` 模型（`claude -p`）启动规划会话，产出 `design.md`、`plan.md`、`task-dag.json` 和审阅页 HTML。DAG 每个节点必须带：声明的文件、验收标准、对应的 NORTHSTAR 条款、所属组件、依赖。用复用的 `validate-task-dag.sh` 校验（含节点间文件不重叠的检查）。
  - 实现说明（阶段 3）：审阅页 HTML 由 `orc` 根据规划产出生成，不交给规划会话写，这样页面上显示的就是将来冻结、签名的那几份文件，哈希也一并列出。会话怎么启动、怎么等待、怎么提问、怎么修，见 STATE.md「规划与 go」。
  - 外部 PRD 在规划时并入 `design.md`，随冻结文件一起签名；评审只认签名的设计。
  - NORTHSTAR 尽量少加，只写方向；规划会话从设计里挑出少数"违反了就等于换了设计"的关键决定（例如"模型之前不准有按原话匹配的分支"），起草成 N# 约束放进 `drafts/NORTHSTAR.md`，由你 `northstar seal`。
- [ ] **【Claude Code】** 写验证（2026-11-07 加）：规划产出通过校验后进入 `verifying`，orc 用 `review` 模型新开一个独立会话，只给它设计、DAG 和当前代码的副本，在实现之前写验收测试和 `checks.json`。orc 校验覆盖面（每条验收标准都有检查、每个节点至少一个 `fail` 检查、测试只能是新文件且不和节点的 `files` 重叠），再在干净的代码副本上、沙箱里实际运行每个检查：`fail` 的必须失败、`pass` 的必须通过；用 pytest 的 `fail` 检查必须失败在测试上（退出码 1 且输出里有「N failed」，收集阶段报错、pytest 没运行都不算，见 `proposals/2026-11-07-check-failure-reasons.md`）。不通过就把输出发回去修，2 次后 `mediate`。审阅页加「验收测试」一节，每个检查附上实现前的输出；go 时测试随 `brief-exec.md` 一起签名。
- [ ] **【Claude Code】** 规划中需要问你的问题，`orc` 输出 `ask-user`；你的回答经 `orc answer` 写回，再恢复同一个规划会话。
- [ ] **【Claude Code】** 调研 OpenAI Sites 怎样从脚本发布（命令行、API，或者只能通过 Codex 发布）。写成一个独立的 `publish` 适配层，`orc` 只调用它。把调研结论写进 PR。
  - 调研结论（2026-11-07）：Sites 通过 ChatGPT 的 Sites 连接器发布（`create_site`、`save_version_and_deploy_private` 等连接器工具），这些工具只有 Codex 里才有。没有独立的 CLI 或公开 API。所以适配层只能用 `codex exec` 执行固定的发布步骤（`orc/templates/publish-sites.md`）：每个 mission 一个 Site，路由 `/plan`、`/status`，只用仅本人可见的访问范围；页面没变就不重复发布；发布失败时不拿本地文件代替。
  - **2026-11-07 改**：用户决定不用 Sites，改用 Claude Artifacts（执行已经换成 Claude Code，不再为发布保留 Codex）。适配层改为 `claude -p` 只放行 Read 和 Artifact 两个工具，读 orc 生成的页面、发布成仅本人可见的 Artifact（`orc/templates/publish-artifact.md`）；每个 mission 每种页面一个 Artifact，页面变了带原链接更新，链接不变。已真实发布一次（见 proposal）。
- [ ] **【你】** 确认发布方式：2026-11-07 用户决定改用 Claude Artifacts。
- [ ] **【Claude Code】** go 关口：审阅页发布成 Artifact；`orc` 输出 `go-gate <链接>`；你说 go 后冻结四个文件、生成 `approved.sha256`，然后等你签名；`verify-approved-authority.py` 先调用 `northstar verify-mission` 校验签名，再校验哈希。签名无效时进不了 `approved`。
- [ ] **【你】** 在测试 mission 里走一遍：看审阅页，说 go，运行 `northstar approve-mission <control 目录>`，按 Touch ID。
- [ ] **【你】** 审 PR。

**完成标志**：未签名或签名无效时 mission 停在 `plan-review`；签名后进入 `approved`。

## 阶段 4：并行执行

- [ ] **【Claude Code】** 调度：就绪条件是前置节点都已 `integrated`、声明文件不和任何运行中的节点重叠、未超过并发上限。每次有节点集成后重新计算。
- [ ] **【Claude Code】** 启动子任务：每个节点一个 worktree；用 `claude -p` 在其中运行，模型和 effort 取自 mission 里记录的 `implement` 角色。会话设置：`sandbox.enabled`、`failIfUnavailable`、`allowUnsandboxedCommands:false`、`filesystem.denyWrite` 主仓库 `.git`（git 只读，提交必须走 broker）、网络按需放行；Edit / Write 用权限规则限制在自己的 worktree 里（先实测，见提案）；环境变量 `ORC_ROLE=implement`、`ORC_NODE=<node>`。brief 只给：任务、验收标准原文、声明文件、"每完成一条验收标准就发一次提交请求"。worktree 里放入冻结的验收测试（`control/approved-tests/`，执行会话可读不可改）。
- [ ] **【Claude Code】** 进程监管：记录 PID、开始时间、退出码；超时按 Astra 的实际耗时设定，写进配置；崩溃按配置重试一次，再失败则节点进入 `blocked`。
- [ ] **【Claude Code】** 子任务结果：要求子任务最后输出结构化结果（改了哪些文件、对应哪条验收标准、遗留问题），由 `orc` 按固定格式校验；校验不过视为未完成。
- [ ] **【Claude Code】** commit broker（复用）在文件范围校验之后加对齐评审：调用 `northstar-review`（和提交前 hook `align.sh` 是同一个评审入口、同样的输入），按评审分级选模型（上一次 DRIFT 后的复审、改动超过 `deep_review_over_lines` 行用 `review`，其余用 `review_light`；`review` 不可用时不降级，节点进入 `blocked` 问用户），对照 NORTHSTAR、签名的 `design.md`、本节点的 DAG 条目（声明文件、验收标准、条款）和这次的 diff，回答两个问题：方向有没有偏、做法是不是照设计。任一项不符判 DRIFT。
  - 冻结的验收测试不能改：提交里只要动了 `approved-checks.json` 列出的测试文件，broker 直接拒绝；跑检查前先按签名的哈希核对 worktree 里的测试文件，对不上就拒绝。
  - 评审前先跑检查：broker 跑这次提交声明完成的验收标准对应的检查（按冻结的 `approved-checks.json` 的检查 id，在沙箱里运行），加上本节点此前已经通过的检查（防回退），结果写进 `events.jsonl`。不通过直接拒绝，不调用模型；通过后把检查结果连同 diff 交给评审（`--checks`）
  - 冻结的检查失败、执行会话认为是测试本身有错时（2026-11-07 加，见 `proposals/2026-11-07-check-failure-reasons.md`）：执行会话不能改测试，写 `BLOCKED`，写明哪个检查、输出、为什么认为测试有错；orc 把它连同设计、DAG、测试全文和检查输出交给 `review` 模型判断。判定测试没错：带着理由发回执行会话继续修实现；判定测试有错：停下来问用户，改测试要回到写验证这一步，重新审阅、go、签名
  - DRIFT：拒绝，纠偏单（违反的是哪条 N# 或设计的哪一节、证据、验收标准原文）作为拒绝原因返回
  - diff 超过评审上限时不截断：拒绝并要求拆成更小的提交
  - 同一节点连续第 2 次：`orc` 把该 worktree 未提交的改动 stash 掉，回到上一次通过评审的状态，重发完整 brief 和纠偏单
  - 第 3 次：节点进入 `blocked`，`orc` 输出 `mediate`；涉及目标或范围的，升级给你
  - 评审通过一次，计数清零；评审服务出错时不放行
- [ ] **【Claude Code】** 整体评审：节点进入 `submitted` 时，先跑本节点全部验收检查和测试（结果写进 `events.jsonl`），不通过直接回到 `rework`，不调用模型；通过后用 `northstar-review` 拿整个节点的累计 diff 和检查结果对照签名的设计再评审一次；DRIFT 时节点回到 `rework`，纠偏单同上。
- [ ] **【Claude Code】** 纠偏和 rework 尽量回到同一个会话（`claude --resume`，阶段 4 实测）；不可用时新开会话，附上完整 brief 和纠偏单。
- [ ] **【Claude Code】** 集成：复用 `integrate-task.sh`，在复用的生命周期锁内按顺序合并，不改写历史。
- [ ] **【Claude Code】** 进入 `reviewing` 前重新判定，不只信 `events.jsonl`：日志回放只拦不合法的转换，伪造一条合法转换（`from` 写对）仍能通过；guard 也只认字面路径（`cd ~ && echo x >> .orc/...` 这类相对路径能绕过）。所以 `orc` 要从协议文件重新算：每个节点 `control/tasks/<node>/state` 是 integrated，且它的 merge commit 确实在父分支上。算出来的结果和日志不一致时停下，`next: error`。
- [ ] **【Claude Code】** 为以上每个分支写契约测试，包括：两个不重叠节点同时运行、重叠节点被排队、DRIFT 三次熔断、子任务超时、两个节点同时集成被锁串行化、检查不通过时不调用评审模型、只跑声明完成的检查加此前通过的检查、整体评审 DRIFT 时节点回到 `rework`、超长 diff 被拒而不是截断、执行会话里 `git commit` 被沙箱拒绝、执行会话写自己 worktree 之外的文件被拒、`review` 模型不可用时节点进入 `blocked` 而不是降级、改动冻结验收测试的提交被拒、worktree 里的测试和签名哈希不一致时拒绝、只有冻结的检查决定节点是否完成、执行会话报冻结测试有错时交给 `review` 模型判断且不能自己改测试。
- [ ] **【你】** 审 PR。

**完成标志**：上面列出的契约测试全部通过。

## 阶段 5：验收、状态页、清理

- [ ] **【Claude Code】** 最终审查：全部节点集成后，`review` 模型对合并后的代码做一次整体审查，对照材料是签名的设计文件、NORTHSTAR 和全部检查结果；发现的问题按节点路由回 rework。
- [ ] **【Claude Code】** 进入 `accepted` 前重新判定，不只信 `events.jsonl` 里的检查记录：`orc` 在合并后的代码上重新跑全部验收检查和测试，并确认 PR 的 CI（`northstar / verify` 和隐藏考题）通过；任何一项和日志对不上就停下，`next: error`。
- [ ] **【你】** 写隐藏考题，放在 agent 读不到的地方（私有仓库，或 GitHub secret）。不能放进 `.northstar/`：它对 agent 可读，`inject.sh` 还会把它注入会话。
- [ ] **【Claude Code】** CI 增加隐藏考题 job：用 agent 没有的凭证（GitHub secret）取考题并运行，只回报通过或失败，不回报内容；加进 main 的 required check。
  - 省分钟数：只在 PR 不是草稿时运行（触发事件含 `ready_for_review`），之后每次推送照常跑；设 `timeout-minutes`
  - 不用标签触发（agent 的 token 有 PR 写权限，能自己加减标签）；不加 `paths` 过滤（required check 被过滤掉时 PR 会一直合不进去）
- [ ] **【Claude Code】** 状态页由脚本生成：每个 DAG 节点一行，不能省略；状态和测试结果来自 `events.jsonl` 和 `orc` 自己运行的验证记录；架构图按组件着色；agent 只写说明，每条带可核对的引用（沿用 `northstar-status` 的校验规则）。发布成 Artifact（每个 mission 一个状态页，链接不变）。
- [ ] **【Claude Code】** "完成"之前必须有最新的状态页；`orc` 在没有状态页时不会输出 `report`。
- [ ] **【Claude Code】** 清理：对已集成的节点执行 `git worktree remove` 并删除分支，只动 `orc` 自己记录过的 worktree 和分支；先输出清单，再执行。
- [ ] **【你】** 审 PR，打开状态页抽查两三条能否追溯到证据。

**完成标志**：状态页上每个状态都来自脚本；清理只动记录过的资源。

## 阶段 6：产品层（画布、phase、跨 mission 评审、汇总页、scope 拦截）

2026-11-07 加，见 `proposals/2026-11-07-cross-mission-review.md`。前面的阶段只认识单个 mission；这一阶段让 orc 认识上面两层：产品设计和 phase。NORTHSTAR 不加任何内容。

**画布**

- [ ] **【Claude Code】** orc 读用户的产品设计文档，起草画布：组件、组件之间的连线、每个组件对应的目录。格式沿用 `northstar-scope` 已经在读的 `.northstar/architecture.json`（`{"components":[{"id","name","paths"}]}`），另加连线。起草写进 `drafts/`，不直接写 `.northstar/`。
- [ ] **【你】** 看过画布后用 `northstar seal` 签进 `.northstar/architecture.json`。之后加组件也一样：先起草进 `drafts/`，签名才生效。
- [ ] **【Claude Code】** 规划会话写 DAG 时，节点的 `component` 只能从签名的画布里选，否则校验不过。

**phase**

- [ ] **【Claude Code】** orc 读 phase 文档里的 mission 列表和依赖，按依赖顺序启动 mission，没有依赖关系的并行。每个 mission 的请求就是对应 mission 文件的全文。
- [ ] **【Claude Code】** phase 里所有 mission 都合并后，对照 phase 文档的「完成标准」出一份结论，写进汇总页；需要人亲手做的验收列成清单交给用户，orc 不代做。

**跨 mission 评审**

- [ ] **【Claude Code】** 时点：每个 mission 自己的评审（阶段 4、5）都通过之后、合进主线之前。评审者是 `review` 模型，不降级。对照材料：NORTHSTAR、产品设计文档、画布、主线上的现有代码、此前各 mission 签名的设计、本 mission 签名的设计和完整 diff。回答三个问题：合在一起还符合 NORTHSTAR 和产品设计吗？有没有推翻或绕开此前 mission 的设计决定？有没有重复实现已有的东西？结论和证据（N#、文件和行、此前 mission 的设计章节）写进 `events.jsonl`。
- [ ] **【Claude Code】** 冲突规则：
  - 默认以已经合并的为准：判定冲突就退回本 mission 重做，不问用户；重做次数沿用熔断规则，超过上限才停下来问。
  - 唯一例外：本 mission 的 `design.md` 里有「推翻的已有决定」一节（逐条写推翻哪个 mission 的哪个决定、改成什么、为什么），它出现在审阅页上，用户 go 并签名就是明确同意。跨 mission 评审只放行这一节写明的推翻，没写的一律当冲突退回。
  - 规划会话不能自己决定推翻：发现需求和已有决定冲突时只能写 `QUESTION.md` 问用户，用户同意了才写进这一节。规划说明（`planner-brief.md`）加上这条。
  - 被推翻的是 NORTHSTAR 条款时，还要用户另外 `northstar seal` 改 NORTHSTAR，否则仍按冲突处理。
- 成本：每个 mission 合并前多一次 `review` 模型调用，随代码规模增长。规模太大时只给评审这个 mission 碰到的组件和相邻组件，阈值实测后再定。

**汇总页**

- [ ] **【Claude Code】** 全产品一个汇总页，发布成仅本人可见的 Artifact，链接不变，每完成一个 mission 更新一次。由脚本生成，agent 写不了状态。内容：
  - 画布着色图：底图是签名的画布，颜色只来自事件记录。按每个 mission 实际改了哪些文件，标出哪个 mission 完成了哪个组件的哪部分，点开能看到节点和证据。
  - NORTHSTAR 条款表：每条 N# 一行，列出由哪些 mission 和节点实现、证据在哪、有没有被 DRIFT 打回过、现在的状态；没有任何 mission 实现的条款单独标出来。
  - phase 和 mission 列表：每个 phase 的完成情况和结论；每个已完成的 mission 一行，附它自己状态页的链接和跨 mission 评审的结论。

**scope 和 forbid 接成硬规则**

- [ ] **【Claude Code】** 信任层的 `northstar-scope` 已经能读 `.northstar/missions/ACTIVE` 指向的 mission 文件，碰到 `forbid` 返回 3（停下），超出 `scope` 返回 1（拦住）。缺的是：orc 开始执行一个 mission 时把 mission 文件放进 `.northstar/missions/` 并设成 ACTIVE，结束时清掉。这是受保护路径，先实测信任层允许怎么写入；如果只能走 `northstar start`（agent 不能执行），就由 orc 输出 `next:` 让用户运行，写进提案后再定。`scope` 和 `forbid` 只对当前 mission 生效，不进 NORTHSTAR。

**契约测试**

- [ ] **【Claude Code】** 为以上每个分支写契约测试，包括：画布签名后 agent 改不了、DAG 节点的组件不在画布里时被拒、phase 按依赖顺序启动 mission 且没有依赖的并行、跨 mission 评审判定冲突时退回重做而不合并、签名设计里写明的推翻被放行而没写的被退回、规划会话不能不经用户就写「推翻的已有决定」、汇总页上每个已完成的 mission 都在且每条 N# 都有一行、没人实现的条款被标出来、执行会话写 `forbid` 里的文件被停下、写 `scope` 外的文件被拦。
- [ ] **【你】** 签画布，审 PR，打开汇总页抽查两三条能否追溯到证据。

**完成标志**：跨 mission 冲突被退回而不是合并；汇总页上每个状态都来自脚本，每条都能追溯到证据。

## 阶段 7：薄 skill 与试运行

- [ ] **【Claude Code】** 按 `slim/SKILL.md` 写 coordinator 的 skill，把其中关于子任务的描述改成 `claude -p` 执行会话的方式；常驻规则不超过 7 条。用户说「跑 P<n>」时，skill 让 orc 把这个 phase 跑完。
- [ ] **【Claude Code】** 在一个玩具仓库上端到端跑一遍：至少 3 个节点、其中 2 个可以并行；人为制造一次越界写入和一次语义偏离，确认都被拽回。
- [ ] **【你】** 用 orc 跑一个真实的小 mission，记录需要你介入的次数和原因。
- [ ] **【Claude Code】** 按试运行暴露的问题修正。

**完成标志**：真实 mission 从头到尾没有需要手工修补的步骤。

---

## ⚠️ 截止与不可逆步骤汇总

| 步骤 | 风险 | 应对 |
| --- | --- | --- |
| Secretive 建 key 时漏勾 Require Authentication | 创建后改不了 | 删掉重建，重新生成 allowed_signers |
| `sudo bash install.sh` | 覆盖已有的 managed-settings 和 Codex hooks | 自动备份为 `.bak`；有自定义 hook 先合并 |
| `core.hooksPath` 全局设置 | 所有仓库原有的 `.git/hooks` 失效 | commit-msg 已转发；其他类型的 hook 需要补转发 |
| 换成 agent 专用 token | 本机推不了 workflow 修改 | 先推完 workflow，再换 token |
| 清理 worktree 和分支 | 删除不可逆 | 只删 orc 记录过的；先输出清单再执行 |
