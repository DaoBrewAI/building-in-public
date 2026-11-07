# northstar-staging

信任层的全部文件。审阅后由你执行 `sudo bash install.sh` 安装到 `/opt/northstar`（root 所有）。

| 文件 | 作用 |
| --- | --- |
| `bin/northstar` | CLI：init、seal、start、finish、verify、approve-mission、verify-mission |
| `bin/northstar-scope` | 判断文件是否在当前 mission 范围内、是否触发停止条件 |
| `bin/northstar-review` | 对齐评审的唯一入口：align.sh 和 orc 的 commit broker 都调用它。对照 NORTHSTAR、签名的设计、节点条目和 diff，回答方向和做法两个问题；diff 超长时拒绝，不截断 |
| `bin/northstar-status` | 生成进度报告（事实由脚本算，agent 只写带引用的说明） |
| `hooks/guard.sh` | 拦截对受保护文件的写入、签名和绕过类命令、越界写入 |
| `hooks/align.sh` | 每次提交前调用 `northstar-review --role auto` 做对齐评审（模型按 models.toml 的评审分级选，2026-11-07 起不再按「另一家」选），偏离就拒绝并发纠偏单 |
| `hooks/inject.sh` | 每次会话开始和压缩后重新注入 NORTHSTAR 原文 |
| `hooks/stop-gate.sh` | 结束前校验签名、工作区干净、无越界、检查和进度报告通过 |
| `git/commit-msg` | 强制 commit 首行带 [N#] |
| `templates/` | NORTHSTAR 和 mission 模板 |
| `managed-settings.json` / `codex-hooks.json` | Claude Code 和 Codex 的 hook 注册 |
| `install.sh` | 安装脚本（只能由你用 sudo 执行） |
| `repo-template/` | 产品仓库要带的 CI workflow、状态脚本、AGENTS.md、CLAUDE.md |
| `tests/` | 功能测试：`bash tests/run_all.sh`。在临时目录里用临时密钥和临时 ssh-agent 运行，不需要 sudo，不碰 `/opt/northstar`、Secretive 和你的 git 全局配置 |
| `tests/sandbox.sh` | 安装前自己动手试：搭一个已签名、mission 进行中的临时仓库，进入子 shell，用 `agent-write` / `agent-bash` / `agent-stop` 看 hook 拦不拦。隔离方式同上，`exit` 后全部删除 |

安装前需要把 Secretive 的公钥保存为本目录下的 `northstar_signing.pub`；`allowed_signers` 会由 install.sh 自动生成。
