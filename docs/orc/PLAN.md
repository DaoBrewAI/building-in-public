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
| 模型 | 实现：OpenAI 当前最强（目前 `gpt-6-astra`，effort high）；规划和评审：Claude 当前最强（目前 `claude-fable-5-1`，降级 `claude-opus-5-5`）。按"最强"由用户手动更新，名字只写在 `config/models.toml` |
| 子任务 | `codex exec` 后台运行，每个任务一个独立 worktree |
| 并发 | 第一版就支持并行：DAG 里声明文件互不重叠、前置都已集成的节点同时跑；集成按顺序加锁 |
| 提交 | 子任务一律通过 commit broker 提交（Codex 沙箱里 git 是只读的）；broker 里由 Claude 做对齐评审，偏离就拒绝并发纠偏单 |
| 给人看的页面 | 计划审阅页和状态页都发布到 OpenAI Sites，手机和电脑都能看 |
| 签名 | 单台 Mac，Secretive + Touch ID；你说 go 之后用 `northstar approve-mission` 签名 |
| 默认参数 | 每次提交最多 8 个文件；同一节点连续偏离 3 次熔断；并发上限写在配置里 |

## 文件夹里有什么

| 路径 | 内容 |
| --- | --- |
| `PLAN.md` | 本文件 |
| `REUSE.md` | 旧 orchestrator 每个脚本的去向：直接复用、参考重写、不要 |
| `northstar-staging/` | 信任层的全部文件，已写好并通过冒烟测试 |
| `slim/SKILL.md` | coordinator 的薄 skill 草稿 |
| `slim/config/models.toml` | 模型角色配置 |

## 阶段总览

| 阶段 | 目标 | 你要做的 | 完成标志 |
| --- | --- | --- | --- |
| 0 准备 | 材料就位，确认前提 | 建签名密钥，确认 Astra 和 codex exec 可用 | 见阶段 0 |
| 1 信任层 | 签名、hook、CI 终审装好 | 审阅、sudo 安装、GitHub 设置 | 验收全部通过 |
| 2 骨架 | 新仓库结构、复用脚本搬入、状态模型、`orc` 骨架 | 审 PR | 搬入的旧测试全部通过 |
| 3 规划与 go | 规划 → 审阅页上 Sites → 你说 go → 签名 | 确认 Sites 发布方式；签一次名 | 未签名进不了执行 |
| 4 并行执行 | 调度、子任务、broker 对齐评审、纠偏、集成 | 审 PR | 并行与纠偏的契约测试全部通过 |
| 5 验收与状态页 | 最终审查、派生状态页上 Sites、清理 | 审 PR，抽查状态页 | 状态页每条可追溯 |
| 6 试运行 | 薄 skill，玩具仓库端到端，再跑一个真实小 mission | 跑真实 mission | 全流程无人工修补 |

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
- [ ] **【你，网页】** GitHub：建模板仓库（放入 `repo-template/`）；产品仓库建变量 `NORTHSTAR_ALLOWED_SIGNERS`、main 开分支保护（required check：`northstar / verify`）；建 agent 专用 fine-grained token（Contents、Pull requests 读写，Metadata 只读；**不给** Workflows、Administration、Variables、Secrets）。
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
- [ ] **【Claude Code】** `orc doctor` 检查：信任层已安装、models.toml 里的模型可用、codex 和 claude 命令存在、Sites 发布可用。
- [ ] **【你】** 审 PR。

**完成标志**：搬入的旧测试全部通过；`orc step` 在空 mission 上能走到 `planning` 并打印正确的 `next:`。

## 阶段 3：规划与 go

- [ ] **【Claude Code】** 规划阶段：`orc` 用 `plan_review` 模型（`claude -p`）启动规划会话，产出 `design.md`、`plan.md`、`task-dag.json` 和审阅页 HTML。DAG 每个节点必须带：声明的文件、验收标准、对应的 NORTHSTAR 条款、所属组件、依赖。用复用的 `validate-task-dag.sh` 校验（含节点间文件不重叠的检查）。
  - 外部 PRD 在规划时并入 `design.md`，随冻结文件一起签名；评审只认签名的设计。
  - NORTHSTAR 尽量少加，只写方向；规划会话从设计里挑出少数"违反了就等于换了设计"的关键决定（例如"模型之前不准有按原话匹配的分支"），起草成 N# 约束放进 `drafts/NORTHSTAR.md`，由你 `northstar seal`。
- [ ] **【Claude Code】** 规划中需要问你的问题，`orc` 输出 `ask-user`；你的回答经 `orc answer` 写回，再恢复同一个规划会话。
- [ ] **【Claude Code】** 调研 OpenAI Sites 怎样从脚本发布（命令行、API，或者只能通过 Codex 发布）。写成一个独立的 `publish` 适配层，`orc` 只调用它。把调研结论写进 PR。
- [ ] **【你】** 确认 Sites 发布方式可行；如果只能通过 Codex 发布，确认可以接受用 `codex exec` 执行固定的发布步骤。
- [ ] **【Claude Code】** go 关口：审阅页发布到 Sites 的 `/plan`；`orc` 输出 `go-gate <链接>`；你说 go 后冻结四个文件、生成 `approved.sha256`，然后等你签名；`verify-approved-authority.py` 先调用 `northstar verify-mission` 校验签名，再校验哈希。签名无效时进不了 `approved`。
- [ ] **【你】** 在测试 mission 里走一遍：看审阅页，说 go，运行 `northstar approve-mission <control 目录>`，按 Touch ID。
- [ ] **【你】** 审 PR。

**完成标志**：未签名或签名无效时 mission 停在 `plan-review`；签名后进入 `approved`。

## 阶段 4：并行执行

- [ ] **【Claude Code】** 调度：就绪条件是前置节点都已 `integrated`、声明文件不和任何运行中的节点重叠、未超过并发上限。每次有节点集成后重新计算。
- [ ] **【Claude Code】** 启动子任务：每个节点一个 worktree；用 `codex exec` 在其中运行，模型和 effort 取自 mission 里记录的 `implement` 角色，沙箱为 workspace-write。brief 只给：任务、验收标准原文、声明文件、"每完成一条验收标准就发一次提交请求"。
- [ ] **【Claude Code】** 进程监管：记录 PID、开始时间、退出码；超时按 Astra 的实际耗时设定，写进配置；崩溃按配置重试一次，再失败则节点进入 `blocked`。
- [ ] **【Claude Code】** 子任务结果：要求子任务最后输出结构化结果（改了哪些文件、对应哪条验收标准、遗留问题），由 `orc` 按固定格式校验；校验不过视为未完成。
- [ ] **【Claude Code】** commit broker（复用）在文件范围校验之后加对齐评审：调用 `northstar-review`（和提交前 hook `align.sh` 是同一个评审入口、同样的输入），由 `plan_review` 模型（Claude）对照 NORTHSTAR、签名的 `design.md`、本节点的 DAG 条目（声明文件、验收标准、条款）和这次的 diff，回答两个问题：方向有没有偏、做法是不是照设计。任一项不符判 DRIFT。
  - 评审前先跑检查：broker 跑这次提交声明完成的验收标准对应的检查（按 `checks.json` 的检查 id），加上本节点此前已经通过的检查（防回退），结果写进 `events.jsonl`。不通过直接拒绝，不调用模型；通过后把检查结果连同 diff 交给评审（`--checks`）
  - DRIFT：拒绝，纠偏单（违反的是哪条 N# 或设计的哪一节、证据、验收标准原文）作为拒绝原因返回
  - diff 超过评审上限时不截断：拒绝并要求拆成更小的提交
  - 同一节点连续第 2 次：`orc` 把该 worktree 未提交的改动 stash 掉，回到上一次通过评审的状态，重发完整 brief 和纠偏单
  - 第 3 次：节点进入 `blocked`，`orc` 输出 `mediate`；涉及目标或范围的，升级给你
  - 评审通过一次，计数清零；评审服务出错时不放行
- [ ] **【Claude Code】** 整体评审：节点进入 `submitted` 时，先跑本节点全部验收检查和测试（结果写进 `events.jsonl`），不通过直接回到 `rework`，不调用模型；通过后用 `northstar-review` 拿整个节点的累计 diff 和检查结果对照签名的设计再评审一次；DRIFT 时节点回到 `rework`，纠偏单同上。
- [ ] **【Claude Code】** 纠偏和 rework 尽量回到同一个 codex 会话（用 codex exec 的会话恢复功能）；不可用时新开会话，附上完整 brief 和纠偏单。
- [ ] **【Claude Code】** 集成：复用 `integrate-task.sh`，在复用的生命周期锁内按顺序合并，不改写历史。
- [ ] **【Claude Code】** 为以上每个分支写契约测试，包括：两个不重叠节点同时运行、重叠节点被排队、DRIFT 三次熔断、子任务超时、两个节点同时集成被锁串行化、检查不通过时不调用评审模型、只跑声明完成的检查加此前通过的检查、整体评审 DRIFT 时节点回到 `rework`、超长 diff 被拒而不是截断。
- [ ] **【你】** 审 PR。

**完成标志**：上面列出的契约测试全部通过。

## 阶段 5：验收、状态页、清理

- [ ] **【Claude Code】** 最终审查：全部节点集成后，`plan_review` 模型对合并后的代码做一次整体审查，对照材料是签名的设计文件、NORTHSTAR 和全部检查结果（`events.jsonl` 里的检查记录）；发现的问题按节点路由回 rework。
- [ ] **【你】** 写隐藏考题，放在 agent 读不到的地方（私有仓库，或 GitHub secret）。不能放进 `.northstar/`：它对 agent 可读，`inject.sh` 还会把它注入会话。
- [ ] **【Claude Code】** CI 增加隐藏考题 job：用 agent 没有的凭证（GitHub secret）取考题并运行，只回报通过或失败，不回报内容；加进 main 的 required check。
- [ ] **【Claude Code】** 状态页由脚本生成：每个 DAG 节点一行，不能省略；状态和测试结果来自 `events.jsonl` 和 `orc` 自己运行的验证记录；架构图按组件着色；agent 只写说明，每条带可核对的引用（沿用 `northstar-status` 的校验规则）。发布到 Sites 的 `/status`。
- [ ] **【Claude Code】** "完成"之前必须有最新的状态页；`orc` 在没有状态页时不会输出 `report`。
- [ ] **【Claude Code】** 清理：对已集成的节点执行 `git worktree remove` 并删除分支，只动 `orc` 自己记录过的 worktree 和分支；先输出清单，再执行。
- [ ] **【你】** 审 PR，打开状态页抽查两三条能否追溯到证据。

**完成标志**：状态页上每个状态都来自脚本；清理只动记录过的资源。

## 阶段 6：薄 skill 与试运行

- [ ] **【Claude Code】** 按 `slim/SKILL.md` 写 coordinator 的 skill，把其中关于子任务的描述改成 codex exec 的方式；常驻规则不超过 7 条。
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
