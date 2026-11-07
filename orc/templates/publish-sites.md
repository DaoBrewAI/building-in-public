用 Sites 技能发布一个已经写好的静态网站。这是固定的发布步骤，不要改网页内容，不要加任何东西。

- 网站源文件：当前目录下的 `dist/`（buildless HTML，`dist/index.html` 和 `dist/plan/index.html`、`dist/status/index.html` 等路由），直接发布，不需要构建。
- 如果当前目录有 `.openai/hosting.json` 且里面有 `project_id`，就更新这个已有的 Site（保留它原来的访问范围）；否则新建一个 Site。
- 只用**仅本人可见（owner-private）**的访问范围。不要改成共享或公开。
- 不需要预览、浏览器检查或截图。

发布成功后，最后一行只输出一个 JSON 对象，不要加别的文字：

{"url": "<部署后的 https 地址>", "project_id": "<Site 的 project_id>"}

发布失败时，最后一行输出：

{"error": "<失败原因>"}
