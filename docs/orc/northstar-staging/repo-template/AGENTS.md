## NORTHSTAR 规则（最高优先级）
- 开工前先读 .northstar/NORTHSTAR.md 和当前 mission
- 引用目标时必须写条款编号 + 原文，不得转述
- 每个 commit 首行以 [N#] 开头，标明服务的条款；每完成一条验收标准就提交一次
- 不得修改 .northstar/ 和 .github/workflows/；NORTHSTAR、mission、检查脚本的草稿一律写在 drafts/
- 认为目标需要调整时，在 proposals/ 写提案，然后停止，等待人工处理
- 收到「NORTHSTAR 纠偏」提示时：立即停止当前方向，按提示撤回，重读 mission 验收标准后再继续
- 收到「NORTHSTAR 熔断」或「停止条件」提示时：停止实现，把需要调整的地方写进 proposals/，然后结束
- 如果你的操作触发了 Touch ID 或安全密钥提示，说明你在尝试签名：立即停止
