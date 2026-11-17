# 提案：连续偏离交给 Fable 5.2 仲裁，人只在最后拍板

状态：**草案**，等独立评审（Fable 5.2，云端评审会话）和林翰定。定了以后在偏离评审的第 3 个实现 PR（#25）里一起实现，#25 等它。

## 起因

- 11-10 定的：偏离评审第一次判 `drift` 打回，**第二次还是 `drift` 就停下问你**。#25 按它实现：节点连续第 2 次 `drift` 是 `ask-user`；mission 结束时连续第 2 次，林翰 11-17 也定为 `ask-user`（提交 `c13a53a`）。
- 林翰 11-17 接着说：「如果是 second drift in a row 的话……还是 Fable 5.2 去 review，尽量减少人的参与吧，人只在最后拍板。」
- 所以这一条要改：连续偏离先交给一个独立的 Fable 5.2 会话仲裁，仲裁也解决不了才问你。你在最后（PR 合并前）看到全部仲裁记录，再拍板。

## 建议

### 什么时候仲裁

- **节点评审**：同一个节点，从上一次 `aligned`（或节点被重新打开）以来，第 2 次判 `drift` 起，每一次 `drift` 都先交给仲裁。
- **mission 结束时的偏离评审**：第 1 次 `drift` 照旧打回节点；从第 2 次起，每一次 `drift` 都先交给仲裁。
- **上限**：同一个节点（或同一个 mission 结束阶段），从上一次 `aligned`、重新打开或你的回答以来，仲裁最多 2 次（`ARBITER_ROUNDS = 2`）。第 2 次仲裁之后还是 `drift`，才停下问你（`ask-user`）。
  - 节点上最多是：drift 1 → 打回；drift 2 → 仲裁 1；drift 3 → 仲裁 2；drift 4 → 问你。执行会话最多返工 3 次才轮到人。
- **不在范围内**：跨 mission 评审的熔断（仍是 `mediate`）、定不出节点的 drift（`drift-unroutable`，仍问你，见「要你定的」第 3 条）、执行会话格式不对、集成失败等其他 `mediate`。

### 谁来仲裁

- 和偏离评审一样：orc 在本机新开一个 `claude -p`，`review` 角色（`claude-fable-5-2`），全新会话，不续用偏离评审的会话。
  - 11-10 定的「本机用 `claude -p` 新开，不用云端会话」不变。林翰说的「cloud session」指的是这种独立、只拿材料的 Fable 5.2 会话；orc 在 Mac 上跑，没办法自己开云端会话。
- 总是只放行 Read，看 tip 的代码副本（不带 `.northstar/` 和 `.github/`）。
- `modelUsage` 核对、超时、不降级，都和偏离评审一样。

### 给仲裁的材料

- 偏离评审的全部材料：NORTHSTAR、签名的「简要设计」（带行号）、画布里相关组件、节点的 DAG 条目（节点评审时）、累计 diff。
- 这一串连续 `drift` 的每一次评审输出（编号、`rule`、证据、`why`）。
- 执行会话为了这些 drift 做了什么：两次评审之间的 diff，和这些提交的说明。
- 之前的仲裁结果（第 2 次仲裁时）。
- **不给**：完整设计、计划、执行会话的对话、你以前的回答以外的东西。

### 仲裁只给三种结论

输出一个 JSON 对象：

```json
{"verdict": "fix" | "overrule" | "escalate",
 "items": [{"drift": 1, "decision": "fix" | "overrule", "why": "…",
            "instruction": "…", "ref": "N1 | design:3 | acceptance:2",
            "evidence": {"side": "tip", "file": "…", "line": 1}}],
 "question": "…"}
```

- **`fix`（偏离是真的，执行会话改得了）**：对每一条真的偏离给一条具体的修改说明，引用证据位置。orc 把这些说明写进纠偏单发回执行会话（mission 结束时按证据文件定节点，和现在一样走 `reopen_for`）。改完照常过提交关口，再做一次偏离评审。
- **`overrule`（偏离评审判错了）**：每一条 drift 都要写为什么不算偏离，并引用 NORTHSTAR 条款、简要设计的行或代码位置。orc 把这个 head 当作通过：节点进入集成调度；mission 结束时进入开 PR。
  - 只对仲裁看过的这个 head 有效：HEAD 变了照旧回到整体评审（`integrate-deferred`）。
- **`escalate`（需要你）**：NORTHSTAR 或签名设计本身有矛盾、要改目标或范围、两边都说得通只能由你选。写一个具体的问题，orc 停下 `ask-user`（SKILL 第 7 条：目标只能由你改）。
- 一次仲裁里可以有的条目 `fix`、有的 `overrule`：只要有一条 `fix`，整体就是 `fix`（被 overrule 的条目写进纠偏单，告诉执行会话不用改）。

### orc 的确定性核对

- 每一条 drift 都被处理且只处理一次（按编号）；`fix` 的条目有 `instruction`，`overrule` 的有 `why` 和 `ref`。
- 引用的条款、设计行、验收标准存在；证据的文件和行在那一边存在（和偏离评审同一套核对）。
- `escalate` 必须有 `question`。
- 不过就把问题和上一次的输出发回重写一次；第二次还不合格，或者模型核对不过、超时、出错：**不放行、不降级**，停下问你。

### 底线不变

- 仲裁不能改测试、NORTHSTAR、签名设计、DAG，不能放宽文件范围。冻结检查仍然必须全过。
- 集成的仍是评审（或仲裁）看过的那个提交：`verification.sha` 写这个 head，`integrate-task.sh` 在集成锁里核对。
- 仲裁用的模型和执行用的模型不同（`review` ≠ `implement`，`resolve_models` 已经检查）。

### 你在最后拍板

- 每次仲裁都记一条事件 `arbiter`（节点、第几次、结论、每条的决定和理由），另记一条 `review` 事件（`verdict` 是 `FIX` / `OVERRULED` / `ESCALATE`，`stage` 是 node 或 final）。
- PR 正文加一节「仲裁记录」：每次仲裁的结论；被 `overrule` 的偏离逐条列出，带仲裁的理由。你合并之前看到这些，不同意就不合并，或者告诉我重开。
- 状态页同样列出。

## 改到的已定决定

| 已定的 | 在哪 | 改成 |
| --- | --- | --- |
| 「第二次还是 `drift`，停下问你」（11-10） | 偏离评审提案「结果怎么用」「轮数」；PLAN「默认参数」；STATE「节点」「验收」 | 第二次起先交给 Fable 5.2 仲裁，最多 2 次；之后还是 `drift`，或者仲裁要你决定，才问你 |
| mission 结束时连续第 2 次 drift 用 `ask-user`（林翰 11-17） | `c13a53a` | 同上：先仲裁 |

流程版本：#25 还没合并，仲裁一起放进流程版本 2，不再加版本。

## 实现要点

- 仲裁在整体评审（`run_submit`）和最终审查（`run_final`）的后台任务里，紧接着偏离评审同步跑，结果并进同一个 `job-exit`：`outcome` 是 `aligned`（overrule）、`rework`（fix，`category` 是 `arbiter`）或新的 `escalate`。
- 新模板 `orc/templates/arbiter-brief.md`；新常量 `ARBITER_ROUNDS = 2`；`NODE_DRIFT_STOP` 和 `FINAL_DRIFT_ROUNDS` 的含义改成「从第几次 drift 起仲裁」。
- 测试：仲裁 `fix` 后节点返工再评审；`overrule` 后集成的就是那个 head；`escalate` 问你；2 次仲裁后还是 drift 问你；仲裁输出不合格两次、模型不对都停下；mission 结束时的三种结论；PR 正文有「仲裁记录」。

## 要你定的

1. **仲裁能不能 `overrule`（判偏离评审错了、直接放行）？** 推荐：能，但每一条都写进 PR 正文的「仲裁记录」，你合并前看。不给 `overrule` 的话，仲裁只能给修改说明，评审一直判错时就还是要问你。
2. **仲裁上限 2 次？** 推荐 2 次：执行会话最多返工 3 次才轮到你。
3. **定不出节点的 drift（证据文件不属于任何节点）也交给仲裁吗？** 推荐：不，仍问你。归属是底线，仲裁不该指定节点。
4. **用本机 `claude -p`（Fable 5.2，全新会话）而不是云端会话？** 推荐：本机（11-10 已定；orc 开不了云端会话，模型和独立性一样）。
5. **其他 `mediate`（执行会话格式不对、集成失败、状态页说明不合格、跨 mission 评审熔断）也换成仲裁吗？** 推荐：这次不，范围只限连续偏离；以后看实跑数据再说。
