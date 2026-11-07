# 提案：审阅页和状态页改为发布成 Claude Artifact

状态：**林翰 2026-11-07 已决定**，已改进 PLAN「已确定的决定」的「给人看的页面」一行。

## 决定

计划审阅页（阶段 3）和状态页（阶段 5）都发布成**仅本人可见**的 Claude Artifact，不再用 OpenAI Sites。

原因：Sites 只能通过 Codex 里的 Sites 连接器发布。执行已经换成 Claude Code（见 `2026-11-07-claude-implement.md`），如果只为发布保留 Codex，就要多维护一套登录、额度和插件。Claude Code 自带 Artifact 工具，手机和电脑上都能打开。

## 发布适配层怎么做

- orc 自己生成页面 HTML（不交给模型写），写到 `$ORC_WORKTREES/<m>/site/<页面>.html`。
- orc 用 `claude -p` 启动一次发布会话，**只放行 Read 和 Artifact 两个工具**：读这个文件，用 Artifact 工具发布，不写任何文件。提示词是 `orc/templates/publish-artifact.md`。
- 第一次发布不带链接，新建 Artifact；之后页面变了，带上原链接更新，链接不变（发布会话先 read 再 publish）。
- 回执记在 mission 的 `publish.json`：每种页面一条，记链接和页面的哈希。哈希没变就不重复发布。
- 只认 `https://claude.ai/` 开头的链接。发布失败时输出 `next: error`，不拿本地文件代替链接去要 go。

## 实测（2026-11-07，Claude Code 2.1.318）

1. 无界面的 `claude -p` 里有 Artifact 工具（让它列出工具名，结果是 Artifact、ArtifactComments、ArtifactData）。
2. 真实发布玩具 mission `toy1` 的审阅页：`orc step --mission toy1` 用时约 20 秒，输出 `next: go-gate https://claude.ai/artifact/QRBiVCctbfHbTPz8Qrwoy3`。
3. 把这个 Artifact 读回来核对：owner 是你，访问范围是 private；页面内容就是 orc 生成的那份（标题、三个文件的哈希、DAG 表、设计和计划都一致），发布会话没有改动页面。

## 页面按 Artifact 的约定生成

Artifact 发布时会自动套上 `<!doctype html>…<body>` 外壳，所以 orc 生成的页面不再自己写这些标签，`<title>` 放在最前面。颜色用 token 定义，同时支持浅色、深色和跟随系统三种主题；两侧边距避开手机的安全区。

## 影响

- 不再需要 Codex：models.toml 里没有角色用 codex 时，`orc doctor` 跳过 codex 检查（阶段 3 已经这样做）。
- `orc doctor` 的发布检查改为 `skip 审阅页发布`：实测会新建一个 Artifact，所以 doctor 不做实测，只靠 claude 命令检查。
- 删除 `orc/templates/publish-sites.md`。
