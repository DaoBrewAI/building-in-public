# 提案：阶段 6 开工前要定的几件事

状态：**待林翰决定**（2026-11-08）

拿真实的 FinTelli 文档对照阶段 6 的步骤（`DaoBrewStrategy/strategies/2026-11-07-fintelli-mvp/`：`phases/P1.md`、`missions/P1-*.md`），下面几处 PLAN 没写到做法，其中两处按现在的样子做不通。每条给推荐做法和备选。

## 1. phase 文档里的依赖，orc 读不出来

`P1.md` 的依赖写在一段话里：「P1-1、P1-2、P1-3 互不依赖，可以并行；P1-4 依赖 P1-2；P1-5a 依赖 P1-1 到 P1-4；P1-5b 最后，还要等 Neo 的税务包……」。orc 要按依赖启动 mission，必须读得准。

- **推荐 A**：phase 文档加一节固定格式的依赖表，每行一个 mission，例如 `- P1-4：依赖 P1-2`、`- P1-1：无`。写 phase 文档的人照格式写，orc 校验：mission 文件不存在、有环、引用了不存在的 mission，都停下说明。
- B：orc 用模型从这段话里读出依赖，做成一页给你确认，你说 go 才按它跑。多一次模型调用和一次确认，而且每次改了文档都要重新确认。

## 2. 有的 mission orc 一个人做不完

P1 里的 `P1-5b 接 8821` 要等 Neo 的税务包、要部署到 A 站、要你亲手测；`P1-branch-handover-neo` 是交给 Neo 的支线。orc 能写代码、开 PR，但等不了外部的人，也部署不了。

- **推荐 A**：mission 文件头加一行 `执行: 人工`。orc 不跑它，只把它列成你的待办（附上 mission 文件），你做完运行 `orc done <mission>`，它才算完成，依赖它的 mission 才能开始。
- B：phase 里只放 orc 能做完的 mission，人工的放在 phase 之外，你自己掌握顺序。

## 3. 后一个 mission 要等前一个合并进 main，可合并是你做的

阶段 5 定了「orc 开 PR、你合并」。phase 里 P1-4 依赖 P1-2：P1-4 要从已经包含 P1-2 的 main 开始，所以必须等你合并 P1-2 的 PR。

- **推荐 A**：保持你来合并。orc 每隔一段时间查一次 PR 有没有合并，合并了就自动开始依赖它的 mission，不用你回来告诉它；在等合并的 mission 列在汇总页上。
- B：同一个 phase 里，orc 在 mission 验收（CI 通过、跨 mission 评审通过、状态页发布）之后自己合并 PR（agent 的 token 有这个权限，main 的保护规则照样生效）。phase 跑得快，但改了阶段 5「你合并」的决定。

## 4. scope 和 forbid 接成硬规则：`northstar start` 用不了

信任层现在只认 `.northstar/missions/ACTIVE`，而它只能由你在终端运行 `northstar start <名字>` 写入（交互、Touch ID 签名），结束时 `northstar finish` 再签一次。拿到 orc 里有两个问题：

- 一个仓库里只能有一个 ACTIVE：P1-1、P1-2、P1-3 要在同一个仓库里并行，做不到。
- 每个 mission 多两次 Touch ID（start、finish），再加上 `approve-mission`，就是三次。

- **推荐 A**：改信任层的 `northstar-scope`：会话带着 orc 设的 `ORC_MISSION_CONTROL`（mission 的 control 目录）时，先用 `northstar verify-mission` 验这个目录的签名，再从里面冻结的 mission 文件读 `scope` 和 `forbid`。mission 文件随设计一起冻结，你 `approve-mission` 时已经签过。每个 mission 各读各的，可以并行；不多签名。agent 改不了自己进程的环境变量（`ORC_ROLE` 已经这样用了）。需要你重新 sudo 安装信任层。
- B：每个 mission 由你在它的 mission 分支上运行一次 `northstar start`，结束前运行一次 `northstar finish`。信任层不改，但每个 mission 多两次 Touch ID，而且 orc 要停下来等你两次。
- C：不接信任层，只在 orc 里拦：规划校验时要求每个节点的声明文件都在 `scope` 的组件目录里、不碰 `forbid`；提交关口碰到 `forbid` 的文件就停下问你。实现最简单，但只在提交时才拦，不是写文件的那一刻。

不论选哪个，规划校验都会加上 C 的那部分：DAG 越出 `scope` 或碰到 `forbid`，计划阶段就退回。

## 我直接按默认做、不用你定的

- **mission 跑在哪个仓库**：P1 的 mission 有的在 `daoharness-core`，有的在 `fintelli`，mission 文件里没写。mission 文件头加一行 `仓库: <名字>`，名字在产品配置里对应本机路径。
- **产品配置**：orc 新增「产品」这一层：`$ORC_HOME/products/<产品>/product.toml` 写产品设计文档、phase 和 mission 文档的位置、仓库名到本机路径的对应。汇总页每个产品一个。
- **画布按仓库**：`northstar-scope` 读的是仓库自己的 `.northstar/architecture.json`，所以每个仓库一张画布，都从同一份产品设计文档起草。
- **跨 mission 评审的时点**：放在阶段 5 的最终审查之后、开 PR 之前。冲突就照 PLAN 退回本 mission 重做（打回到相关节点），次数沿用熔断。

## 影响

四条定下来后再动手。mission 模板（`northstar-staging/templates/mission.md`）要加 `仓库:` 和（选 2A 时）`执行:` 两行，FinTelli 现有的 mission 文件要照着补；phase 文档要加依赖表（选 1A 时）。这些是你那边文档的改动，我可以起草。
