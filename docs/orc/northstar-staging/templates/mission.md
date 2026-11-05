# MISSION: <名字>
服务的条款: N2, N5
scope: <允许改动的组件 id，逗号分隔>   # 对应 architecture.json；越界写入会被直接拦下
forbid: <停止条件，文件 glob，逗号分隔>  # 例如 db/migrations/*, package.json；碰到就必须停下找用户

## 验收标准（必须可验证）
- [ ] <标准>（对应 checks.json 里的检查 id）

## 本次范围外
- <明确不在这次做的事>
