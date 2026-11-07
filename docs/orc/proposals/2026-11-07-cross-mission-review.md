# 提案：产品设计和 phase 层、跨 mission 评审、汇总页、scope 拦截

状态：**林翰 2026-11-07 已决定，全部要做**。已写进 PLAN：「已确定的决定」加了「产品设计和 phase」一行，「给人看的页面」一行加了汇总页；步骤新开为**阶段 6：产品层**，原来的阶段 6（薄 skill 与试运行）顺延为阶段 7。

## 背景：前提是阶段 0–6 都做完，跑真实产品还缺什么

拿真实的 FinTelli MVP 文档对照（DaoBrewStrategy `strategies/2026-11-07-fintelli-mvp/`，main f18a5b7b）。它已经按四层写好：

- `design.md`：全产品设计，agent 不读；
- `NORTHSTAR.md`：N1–N10 和非目标 X1–X5，每个 agent 都读；
- `phases/P1.md` … `P6.md`：每个 phase 的目标、关口、对外接口、mission 列表和依赖；
- `missions/P1-1…P1-5`：按 orc 的 `templates/mission.md` 写的 mission 请求，带 `服务的条款`、`scope`、`forbid`、验收标准。

orc 现在只认识单个 mission，上面两层（产品设计、phase）不认识。所以有下面四件事要加。NORTHSTAR 不加任何内容，仍然越少越好。

## 1. 产品设计层和画布

- 开工前，orc 读林翰的产品设计文档，**起草画布**：有哪些组件、组件之间怎么连、每个组件对应哪些目录（例如「收话」对应 `harness_core/intake/`）。
- 画布写成产品仓库的 `.northstar/architecture.json`（格式沿用 `northstar-scope` 已经在读的 `{"components":[{"id","name","paths"}]}`，另外加上组件之间的连线）。林翰看过后签名，之后 agent 改不了。
- 以后要加组件：像加 N# 条款一样，先起草进 `drafts/`，林翰签名才生效。
- 规划会话写 DAG 时，每个节点的 `component` 只能从画布里选。

## 2. phase 层

- orc 认识 phase：读 phase 文档里的 mission 列表和依赖，按依赖顺序启动 mission，没有依赖关系的可以并行（例如 P1-1 和 P1-2 并行，P1-3 等两者都合并后再开始）。
- 每个 mission 的请求就是对应的 mission 文件全文。
- phase 里所有 mission 都合并后，对照 phase 文档的「完成标准」出一份结论，写进汇总页。需要人亲手做的验收（例如测试站上的真浏览器验收）列成清单交给林翰，orc 不代做。
- 使用方式：林翰说「跑 P1」，skill 让 orc 把 P1 跑完。

## 3. 跨 mission 评审

- 时点：每个 mission 自己的评审都通过之后、合进主线之前。
- 评审者：`review` 角色的模型（目前 Fable 5.1），不降级。
- 对照材料：NORTHSTAR、产品设计文档、画布、主线上的现有代码（也就是此前所有 mission 的成果）、此前各个 mission 签名的设计、这个 mission 签名的设计和它的完整 diff。
- 回答三个问题：和已有的东西合在一起还符合 NORTHSTAR 和产品设计吗？有没有推翻或绕开此前 mission 的设计决定？有没有重复实现已有的东西？
- 结论和证据（N#、文件和行、此前 mission 的设计章节）写进 `events.jsonl`，并显示在汇总页上。

**冲突规则（林翰定）**：

- **默认以已经合并的为准。** 比如 mission A 定了「都走 API」，mission B 没走 API，就是 B 错了：直接退回 B 重做，不问林翰。重做次数沿用熔断规则，超过上限才停下来问。
- **例外只有一种：林翰明确说要改。** 做法：这个 mission 的 `design.md` 里写一节「推翻的已有决定」，逐条写清推翻哪个 mission 的哪个决定、改成什么、为什么。这一节出现在审阅页上，林翰 go 并签名，就等于明确同意。跨 mission 评审只放行签名设计里写明的推翻，没写的一律当冲突退回。
- 规划会话不能自己决定推翻：发现需求和已有决定冲突时，只能写 `QUESTION.md` 问林翰，林翰同意了才写进「推翻的已有决定」。
- 被推翻的决定如果是 NORTHSTAR 的条款，还要林翰另外 `northstar seal` 改 NORTHSTAR，否则仍按冲突处理。

## 4. 汇总页

- 发布成仅本人可见的 Claude Artifact，**全产品只有一个**，链接不变，每完成一个 mission 更新一次。
- 由脚本生成，agent 写不了状态。
- 内容：
  - **画布着色图**：底图就是第 1 条签名的画布；颜色只来自事件记录。脚本按每个 mission 实际改了哪些文件，标出哪个 mission 完成了哪个组件的哪部分，点开能看到节点和证据。越直观越好。
  - **NORTHSTAR 条款表**：每条 N# 一行，列出由哪些 mission 和节点实现、证据在哪、有没有被 DRIFT 打回过、现在的状态。没有任何 mission 实现的条款单独标出来。
  - **phase 和 mission 列表**：每个 phase 的完成情况；每个已完成的 mission 一行，附它自己状态页的链接和跨 mission 评审的结论。

## 5. 把 mission 的 scope 和 forbid 接成硬规则

- 信任层已经有 `northstar-scope`（阶段 1 测过）：它读 `.northstar/missions/ACTIVE` 指向的 mission 文件里的 `scope` 和 `forbid`，再用 `.northstar/architecture.json` 把组件 id 换成目录；碰到 `forbid` 返回 3（停下），超出 `scope` 返回 1（拦住）。
- 缺的是连线：orc 开始执行一个 mission 时，要把这个 mission 文件放进 `.northstar/missions/` 并设成 ACTIVE（这是受保护路径，具体怎么写入要和信任层的规则对齐，可能要走 `northstar start`），结束时清掉。
- `scope` 和 `forbid` 只对这个 mission 生效，不进 NORTHSTAR。

## 影响

- 「已确定的决定」：加一行「产品设计和 phase」（产品设计文档 → NORTHSTAR → phase → mission；画布从设计文档起草、林翰签名）；「给人看的页面」一行加「另有一个全产品的汇总页」。
- PLAN：加上面 1–5 的步骤和契约测试，包括：
  - 画布签名后 agent 改不了；DAG 节点的组件不在画布里时被拒；
  - phase 按依赖顺序启动 mission，没有依赖的并行；
  - 跨 mission 评审判定冲突时退回重做，不合并；签名设计里写明的推翻被放行，没写的被退回；
  - 汇总页上每个已完成的 mission 都在、每条 N# 都有一行、没人实现的条款被标出来；
  - 执行会话写 `forbid` 里的文件被停下、写 `scope` 外的文件被拦。
- 成本：每个 mission 合并前多一次 `review` 模型调用，随代码规模增长。规模太大时只给评审这个 mission 碰到的组件和相邻组件，阈值实测后再定。
- 产品那边要做的只有：林翰签 FinTelli 的 NORTHSTAR；隐藏原话 06、14 移出 DaoBrewStrategy（`design.md` 第 8 节第 3、4 条）。
