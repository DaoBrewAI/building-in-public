# 提案：FinTelli P1 交给 orc 之前，mission 文件要定三件事

状态：**林翰 2026-11-08 定**：第 1 条以 daoharness-core 为主，DaoBrewStrategy 那份清掉（林翰另开会话处理）；第 3 条选 A，一个一个跑，第一个真实 mission 只跑 P1-1 看全流程。依赖表、「仓库」行和 P1-5b 的 `执行: 人工` 跟着 mission 文件放进 daoharness-core（phase 文档也要在 orc 的 `--phases` 指向的目录里）。

原提案：阶段 7 准备 FinTelli 第一个真实 mission 时，对照 orc 的产品层格式（`docs/orc/STATE.md`「产品层」）发现。

## 1. mission 文件有两份，内容已经不一样

- `DaoBrewStrategy/strategies/2026-11-07-fintelli-mvp/missions/`：7 个文件（含 P1-5b），最后一次改在 5d920315。
- `daoharness-core/drafts/missions/`：6 个文件（没有 P1-5b），之后又改过三次（32c4b4a、c4b7819、7597071：接口字段、脚本模型、测试合同）。P1-2 差 20 行，P1-1、P1-3、P1-4、P1-5a 各差 4 到 6 行，只有支线那份一样。

`orc product` 只认一个 mission 目录，两份不一致时 orc 用哪份，agent 就按哪份做。

- **A（推荐）**：以 daoharness-core 那份为准，把它同步回 DaoBrewStrategy（P1-5b 留在 DaoBrewStrategy），以后只改 DaoBrewStrategy；daoharness-core 的 `drafts/missions/` 删掉。产品计划（设计、phase、mission）都在一个地方，产品仓库的 `drafts/` 只放要签名的 NORTHSTAR、画布和检查。
- B：以 daoharness-core 那份为准，orc 的 mission 目录指向它，phase 文档仍在 DaoBrewStrategy。缺点：P1-5b 要补过去；产品仓库里的 mission 文件 agent 的 PR 也能改（`forbid` 里没有 `drafts/`）。

## 2. 依赖表和「仓库」行（照 P1.md 第 23 行和支线一段的原文换成 orc 的格式，不改内容）

P1.md 加一节：

```
## 依赖
- P1-1：无
- P1-2：无
- P1-3：无
- P1-4：依赖 P1-2
- P1-branch：依赖 P1-2、P1-3
- P1-5a：依赖 P1-1、P1-2、P1-3、P1-4
- P1-5b：依赖 P1-5a
```

除 P1-5b 外每个 mission 文件头加 `仓库: core`（产品配置里 `core=~/Documents/Daobrew/daoharness-core`）。P1-5b 原文写着「不走核心仓库的 ORC」，加 `执行: 人工`：orc 等你做完后运行 `orc done`；「还要等 Neo 的税务包过包合同测试」也由你在那时确认。

## 3. P1-1、P1-2、P1-3 实际不会并行

P1.md 说这三个互不依赖、可以并行。但三个的 scope 都有 `core-base`、`build`、`tests`。orc 的规则是：同一个仓库里 scope 有重叠的 mission 一次只跑一个（它们的 PR 都从同一个 main 开始，先合并的会让后合并的冲突）。所以 orc 会按 P1-1 → P1-2 → P1-3 一个一个跑。

- **A（推荐）**：先接受一个一个跑。第一个真实 mission 本来就该单独跑（阶段 7 的完成标志看的是一个 mission 全程无人工修补）；跑完 P1-1 再看 `core-base` 和 `tests` 实际被改了哪些文件，再决定要不要拆 scope。
- B：现在就把 `core-base`、`build` 只留给 P1-1，P1-2、P1-3 去掉这两个；`tests` 按 mission 拆成子目录对应的组件。要改画布（重签）和 mission 文件，而且是在还没看到真实改动的情况下猜。
