# 提案：orc 的提交说明只有一行，过不了 daoharness-core 的 N12「commit 正文写根因」

状态：**林翰 2026-11-08 两部分都选 A**，已实现：执行说明改了（orc 本来就原样保留正文，问题只在说明）；`orc abandon`；daoharness-core 的 `drafts/checks/core_checks.py` 已起草跳过 orc 的冻结测试提交，等你 `northstar seal`。`fintelli-p1-1` 的最终审查发现（在修好「检查副本没有 .git」之后才会露出来）。

## 发生了什么

daoharness-core 的 N12：「每处修改先写根本原因：commit 正文里有一行「根因: …」」。签名的 `core_checks.py commit-root-cause` 查 mission 的每个提交（不含合并提交、`[NS]` 开头的、只改 `.northstar/` 等目录的），正文里要有一行以「根因:」开头。

P1-1 的 10 个提交全部没过：

- **9 个节点提交里有 8 个其实写了根因**，但写在第一行中间（`[N2] intake-tests：……。根因: N2 要求……`）。原因在 orc：执行说明（`orc/templates/executor-brief.md`）要求 `"message": "一句话提交说明"`，执行会话照做了，读了仓库的 AGENTS.md 后把根因塞进了这一句。orc 和 broker 本身会原样保留换行，问题只在说明。
- `core-init` 那个提交没写根因。
- orc 自己的「冻结 mission 的验收测试」提交没有正文。它只加 `tests/` 下的文件，检查不会跳过它。

CI 的 `verify` 也跑同一个 `run_all.sh`，所以就算 orc 放行，PR 也过不了。

## 需要你定

**1. 以后的 mission（改 orc）**

- **A（推荐）**：执行说明改成「`message` 第一行一句话；仓库的约定（AGENTS.md、CLAUDE.md）要求提交正文写什么的，空一行写在正文里」。orc 拼说明时保留正文（第一行照旧加 `[N#] 节点名：`）。不写死「根因」：这是 daoharness-core 的规定，不是 orc 的。
- orc 自己的冻结测试提交：orc 不知道每个产品的约定，**推荐**由产品的检查跳过它（daoharness-core 的 `commit_root_cause` 加一条：第一行含 `orc：冻结 mission` 的跳过，要你重新签名 `core_checks.py`）；另一个做法是 orc 给这个提交加一行英文正文 `Root-cause: acceptance tests frozen before implementation`（正好被这个检查接受），但这是把一个产品的约定写进 orc，不推荐。

**2. 已经跑完的 P1-1（10 个提交已经在 mission 分支上）**

提交说明改不了：orc 的记录（每个节点的提交号、集成、mission 分支的 tip）都绑定了这些提交，改写历史后 orc 进 `accepted` 前的核对一定对不上。

- **A（推荐）**：放弃这一次 P1-1，等上面两处修好后重跑。orc 现在没有「放弃 mission」的命令（只有提示「让用户决定放弃、重新开一个」），要加一个 `orc abandon`：记一条事件、mission 不再推进，phase 里这个编号可以重新开始；mission 分支和 worktree 留着给你看。重跑要再审阅、签名一次，执行大约一小时。好处是这才是一次真正「全流程无人工修补」的实跑。
- B：这一次手工补救：你在 mission 分支上改写这 10 个提交的说明、自己开 PR 合并，orc 这边由你确认后标记完成。快，但正是我们要避免的人工修补，而且 orc 的记录和实际分支对不上。
- C：放宽 N12，让检查也接受第一行里的「根因:」。要改 NORTHSTAR 的检查（重新签名）；`core-init` 和 orc 的提交仍然过不了。不推荐。
