# inbox-baseline-audit

**盘点即 Demo** — a first-meeting skill for AI delivery teams. Connect a customer's last
30/60 days of Gmail + Google Drive and produce three verifiable fact cards, one
"tug-of-war" workflow catch, and a baseline draft — then run a three-act demo
(*we present facts → customer asks, we translate → customer drives*) that ends with a
signed baseline and paid onboarding.

用客户自己的数据产出他 10 秒内能验证真伪的事实,而不是又一场 chatbot 演示。
终点不是掌声,是 baseline 签认。

- Skill body: [`SKILL.md`](./SKILL.md) (中文,查询语法为 Gmail/Drive 原生英文)
- Runtime: any harness that can execute Gmail search syntax + Drive queries
  (custom connector / Claude Code / Codex)
- Validated on a real inbox before publishing — the validation flipped a core assumption
  (email-as-workplace vs email-as-notification-sink); see *Validation Notes* in SKILL.md.

**Privacy first**: exclusion-list question before any query; sensitive categories
(medical / legal / HR / personal finance) are aggregated, never displayed; message bodies
are only ever opened by the customer.
