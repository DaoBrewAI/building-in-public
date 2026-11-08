# 提案：阶段 5 开工前要定的四件事

状态：**林翰 2026-11-08 全部定了**：1 orc 开 PR、你合并；2 选 A；3 考题放在 `DaoBrewAI/LY_orchestrator-hub`（agent 的 token 访问不到，已核实 404），复用这个不再用的仓库；4 选 A。

阶段 5 的几步，PLAN 和 STATE 里没写到具体做法；有两处按现在的样子做不通。下面每条给出推荐做法和备选。

## 1. mission 的 PR 由谁开、谁合并

PLAN 阶段 5 要求进入 `accepted` 前「确认 PR 的 CI 通过」，但没写 PR 从哪来。

- **推荐**：最终审查通过后，orc 把 mission 分支 `orc/<m>` 推到产品仓库的 `origin`，开一个指向 main 的 PR，然后等 CI（`next: wait`）。CI 通过、状态页发布后进入 `accepted`，输出 `next: report <状态页链接>`，状态页上写 PR 链接。**合并由你来做**；阶段 6 的跨 mission 评审以后放在合并之前。
- 产品仓库没有 `origin`（例如本机的玩具仓库）时，orc 停下（`next: error`），说明要先建远程仓库。不跳过这一步。
- 实跑改用 `DaoBrewAI/northstar-trial`（公开，main 有保护，required check 是 `verify`）。

## 2. 集成 commit 过不了 CI 的「commit 必须带 [N#]」

实测（mission `subtract2`）：集成用的复用脚本 `integrate-task.sh` 生成的合并 commit 说明是 `Integrate add-subtract`，不带 `[N#]`。CI 的 `commit 必须带 [N#]` 检查会把每个 orc 开的 PR 都判失败。

- **推荐 A**：给 `integrate-task.sh` 加一个可选参数 `--message`，orc 传入 `[N#] Integrate <节点>`（条款取自节点的 DAG 条目）。不传时行为不变，搬来的旧测试照样通过。CI 不放松。
- B：CI 检查跳过合并 commit（`git log --no-merges`）。复用脚本不改，但 CI 放松了：合并 commit 里也能夹带改动。要改信任层的 workflow，需要你用自己的账号推送。

## 3. 隐藏考题放在哪

实测：agent 专用的 token 能读 DaoBrewAI 下的私有仓库 `DaobrewAI` 和 `fintelli`。（最初写成「能读全部仓库」是错的：列仓库的 API 只返回 token 能访问的，见本节末尾的核实。）

- **推荐 A**：考题放在你**个人账号**下的私有仓库（例如 `Jupiter1995/<产品>-exam`），agent 的 token 碰不到。你再建一个只读这个仓库的 fine-grained token，存成产品仓库的 secret（例如 `NORTHSTAR_EXAM_TOKEN`）。CI 用它取考题、运行，只报通过或失败。
- B：考题打包后存进一个 GitHub secret。不用多建仓库，但单个 secret 上限 48 KB（GitHub 文档），改考题要重新打包。
- C：把 agent 的 token 改成只能访问指定的仓库，考题仍放在 DaoBrewAI 下。

不管选哪个，CI 都这样做：

- 考题的输出一律丢掉，只看退出码。公开仓库的 Actions 日志，任何登录 GitHub 的人都能看（GitHub 文档）。
- 运行考题时断网（`sudo unshare --net`），防止被测代码把考题发出去。这一点要在真实 CI 上实测。
- 免费组织的私有仓库设不了 required check（2026-11-06 已确认）。不过 orc 自己在进入 `accepted` 前会查 PR 的 CI，考题不过就停下。所以在 orc 的流程里它照样拦得住，只是你手动合并时 GitHub 不会拦。

核实（2026-11-08）：本机 `gh` 用的是 agent 专用的 fine-grained token（`github_pat_…`，2027-02-04 到期），能读 DaoBrewAI 下两个私有仓库 `DaobrewAI` 和 `fintelli` 的内容，读不到你个人账号下的私有仓库。DaoBrewAI 的私有仓库只有这两个，所以从 API 看不出它是设成了「All repositories」，还是两个都被选中了。林翰指出另有私有仓库 `daobrewstrategyrepo`：这个 token 访问 `DaoBrewAI/daobrewstrategyrepo` 和 `Jupiter1995/daobrewstrategyrepo` 都是 404，也就是看不到。它若在 DaoBrewAI 下，说明 token 设的是「只选中的仓库」，`DaobrewAI` 和 `fintelli` 是被选中的；没选中的私有仓库 agent 读不到。

## 4. 最终审查发现问题时，怎么打回已集成的节点

PLAN 要求最终审查「发现的问题按节点路由回 rework」。可是到这一步，节点都已经集成了。现在的节点状态里没有「集成后再打回」这条路，`integrate-task.sh` 对已集成的节点也只回答「已经集成过」。

- **推荐 A**：重新打开节点。
  - 节点状态 `integrated → rework`（新增这条转换）。
  - orc 把节点分支和 worktree 移到 mission 分支的最新提交（这个提交已包含全部节点的改动），基线也更新成它，控制文件的 `state` 改回进行中。
  - 回到同一个执行会话，发纠偏单，之后照常走提交关口、整体评审、再集成，再做一次最终审查。
  - 最终审查最多打回 2 轮，第 3 次不过就 `mediate`。
  - `integrate-task.sh` 不用改：对同一分支再合并一次，git 本来就支持。
- B：最终审查不过就停下问你，不自动打回。做起来简单，但和 PLAN 写的「路由回 rework」不一样，属于改决定。

## 影响

四条都定下来后再动手。之后在 STATE.md 写阶段 5 的做法，按 PLAN 实现，契约测试用假的 `gh` 和假评审。最后在 `northstar-trial` 上实跑：需要你先写考题、建 secret、用自己的账号推送 workflow。
