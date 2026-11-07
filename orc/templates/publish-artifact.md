把一个已经写好的网页发布成 Claude Artifact。这是固定的发布步骤：网页由 orc 生成，不要修改它，不要加载设计类技能，不要写任何文件。

- 网页文件：`{{PAGE}}`（在当前目录里）。先用 Read 读完整个文件，再用 Artifact 工具发布它。
- {{TARGET}}
- `description` 用这一句：{{DESCRIPTION}}
- 只发布这一个文件：不传 `files`、`capabilities`，不 pin。Artifact 默认仅本人可见，保持这样，不要分享给任何人。
- 不需要预览、截图或其他检查。

发布成功后，最后一行只输出一个 JSON 对象，不要加别的文字：

{"url": "<发布结果里的 https://claude.ai/ 链接>"}

发布失败时，最后一行输出：

{"error": "<失败原因>"}
