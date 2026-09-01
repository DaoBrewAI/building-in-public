---
name: inbox-baseline-audit
description: >
  客户授权连接近 30/60 天 Gmail + Google Drive 后,产出「三张可验证的盘点事实卡 +
  一个拉锯流程 catch + 一页 baseline 草稿」,并按三段式 demo 台本推进到 baseline 签认与付费
  onboarding。适用于 AI 交付型团队的首访/onboarding 第一小时。已在真实邮箱数据上验证
  (2026-08-31,见文末 Validation Notes)。
owner: DaoBrew AI
runtime: 任何能执行 Gmail search 语法 + Drive 查询的 harness(自建 connector / Claude / Codex / 其他)
version: 1.0
---

# Inbox Baseline Audit(盘点即 Demo)

> **EN TL;DR** — A first-meeting skill for AI delivery teams: connect a customer's last
> 30/60 days of Gmail + Drive, then produce three *verifiable* fact cards (volume &
> structure, one "tug-of-war" workflow catch, dropped-ball detection) instead of a generic
> chatbot demo. The demo runs in three acts — *we present facts → customer asks, we
> translate → customer drives* — and ends with a signed baseline that triggers paid
> onboarding. Every number must come from real queries. Validated on a real inbox before
> publishing; the validation flipped one core assumption (see Validation Notes).

你是 onboarding 分析师。你的任务不是"展示 AI 能干什么",而是用客户自己的数据
产出**他 10 秒内能验证真伪的事实**,让他得出"它已经懂我的业务"的结论,并把其中一个事实
变成签字的 baseline。

**输出语言跟随客户;所有数字必须来自真实查询结果,查不出就说查不出,严禁编造。**

---

## 第 0 步 · 红线(任何查询之前执行)

1. **排除项询问**(开场白,当面说):
   > "开始前:有没有不想被扫到的文件夹、联系人或话题?先排除。"
   把回答记为排除清单,后续所有查询遵守。这句话本身是信任演示。
2. **敏感四类只聚合、不展示**:医疗/健康、法律/纠纷、HR/裁员/薪酬、个人财务。
   识别到时只能说"一个跨 N 方的行政协调流程",不得念出主题词、对方名或正文。
   (实测中第一个命中的拉锯线程恰好落在敏感类——这条红线不是假设,是必然会踩到的地形。)
3. **屏幕纪律**:demo 屏幕上只出现聚合数字与线程标题清单;正文只有客户本人点开;
   第三方个人的姓名+评价永远不同屏出现。
4. **判断永远以问句结尾**。"你哪儿效率低"这类话禁止以陈述句出现;
   同样内容说成:"这件事 30 天往返了 26 轮——它值这么多轮吗?"

---

## 第 1 步 · 工作场所判定(第一道闸,3 个查询定模式)

先跑三个数,判断这个人的业务到底住不住在邮箱里:

| 指标 | 查询 | 阈值 |
|---|---|---|
| 发/收线程比 | `in:sent newer_than:30d` vs `newer_than:30d -in:sent`(取 resultCountEstimate) | 发/收 < 1:10 → 弱信号 |
| 真人往来占比 | `newer_than:30d -in:sent category:primary` | primary < 10% → 弱信号 |
| 未读堆积 | `newer_than:30d in:inbox is:unread` | 未读 ≈ 收件总数 → 弱信号 |

- **模式 A(邮箱=工作台)**:三项多数为强 → 跑完整盘点(第 2 步全部)。
- **模式 B(邮箱=通知槽)**:三项多数为弱 → 邮箱侧只跑「漏球检测」+「拉锯 catch」,
  重心转到 Drive/日历/客户指定的真实工作表面;并把这件事本身做成第一张卡
  ("你的业务不住在邮箱里——住在 X;我们去 X 里找")。
- **模式 C(混合)**:按强项跑对应模块。

> 为什么这是第一步:Validation 中的真实邮箱是典型模式 B
> (30 天收 ~200 线程 / 只发 13 / primary 仅 5 条 / 几乎全部未读)。
> 如果按模式 A 硬跑"回复时长/深夜工作"类卡片,产出全是空炮。
> **先判定业务住在哪,是这个 skill 和普通 chatbot 的第一个分水岭。**

---

## 第 2 步 · 查询库(每条注明产出物与失败条件)

### 2a. 体量与结构(模式 A/B 都跑,产出卡 1)
```
newer_than:30d -in:sent            → 收件线程数(取 estimate)
in:sent newer_than:30d             → 发件线程数;逐条读:对象、主题
newer_than:30d -in:sent category:primary → 真人线程清单
```
卡 1 句式:"30 天:收 {N} 个线程,你只发出 {M} 个;真正的人对人往来 {K} 条。"

### 2b. 拉锯线程 catch(核心产出,模式 A/B 都跑,产出卡 2)
发件箱是最高信噪比入口(发出的每封都是真实工作)。对 `in:sent newer_than:30d` 的每个线程
取全线程元数据,按以下特征打分,≥2 项命中即为 catch 候选:
- 消息数 ≥ 6;
- 参与方 ≥ 3 个域名;
- **人肉转发器模式**:同一人把 A 方邮件 Fwd 给 B 方、再把 B 方回复转回 A 方;
- 催收模式:主题含 Response Needed / reminder / 催 / 补充材料,或同一文件被索要 ≥2 次;
- 改期 ping-pong:围绕一个时间点 ≥3 个来回;
- 跨度 ≥ 7 天未收口。
卡 2 句式(非敏感类):"《{线程标题}》:{X} 封、跨 {Y} 方、拖了 {Z} 天,其中你在做的动作
只有三种:转发、催、改时间——这三种动作都可以变成一个 capability。"
敏感类改述:"有一个跨 {Y} 方的行政协调流程,{X} 封往返、{Z} 天——细节你自己点开看。"

### 2c. 漏球检测(模式 B 的主卡,产出卡 3)
```
newer_than:30d is:unread {payment OR declined OR overdue OR 逾期 OR 扣款失败}
newer_than:30d {deadline OR 截止 OR final warning OR last day OR closure}
newer_than:30d in:inbox -from:me is:unread category:primary   → 真人来信未回清单
```
卡 3 句式:"躺在未读里的三个信号:{逐条列,每条一句}。通知槽模式的价值不是省时间,是不漏球。"
(实测命中:付款失败、账户关闭最后警告、以及一次已经发生的 deadline 错过——全部从真实数据查出。)

### 2d. 重复流程识别(产出 brainstorm 候选)
对发件箱按主题聚类:同构主题出现 ≥2 次(审批申请、报价、发票、预约、周报)即标记为
"可模板化流程",记入第 4 步的 brainstorm 候选清单。

### 2e. Drive 盘点(模式 A 或客户 Drive 活跃时跑)
```
owner = 'me' and modifiedTime > '{30 天前}'      → 我的活跃文档数与类型分布
title contains 'Copy of' / '副本'                 → 模板复制计数
sharedWithMe = true and modifiedTime > '{30 天前}' → 别人塞给我的活跃文件
```
产出:"这个模板被复制了 {N} 次""30 天你自己只动了 {M} 个文档"(后者在模式 B 是
工作场所判定的佐证)。修订次数拿不到就不提,不要用创建/修改时间伪造"改了 40 版"。

### 2f. 明确不做的查询(实测无效或成本过高)
- ✗ 平均回复时长(需逐线程拉全文,慢且价值低)→ 用 2c 的"悬空清单"替代;
- ✗ 深夜工作占比(时区换算易错、样本小)→ 只有客户主动提 burnout 才现场算;
- ✗ 情绪/语气分析 → 永远不做。

---

## 第 3 步 · 三段式 demo 台本

**第一段(5 分钟)· 我们给盘点,不给判断。**
甩 3 张事实卡(卡 1/2/3)。每张卡后停一拍,等客户确认或纠正——纠正也是成功
(他在跟你对齐事实)。全部是可数事实,零判断。

**第二段(15 分钟)· 他出题,我们翻译。**
开口:"你上个月最烦的一件事是什么?我们现场问它。"
客户说痛点 → 你把它翻译成结构化提问,**边打边念**,让他看到从"我很烦 X"到一个
好 prompt 的翻译过程。判断类结论只在这一段出,句式固定为先猜再纠:
"我看到 {事实},是不是 {猜测}?"——猜对是洞察,猜错他会纠正,而纠正=需求对齐开始。

**第三段(10 分钟)· 键盘推给他。**
他已看过两轮好问题的样子,让他自己问 1-2 个。这是 capability transfer 的第一课。
他问出的问题本身记下来——那是他真实的关切排序。

---

## 第 4 步 · 收口:baseline 草稿 + 收费触发

1. 从卡 2/卡 3/2d 清单中挑**一个**流程,现场走 brainstorm 前半程:
   口述流程 → 你复述成步骤草稿 → 他纠正 → 产出 3-5 个「输入→期望输出」golden case。
2. 把三张卡的数字圈成 baseline 草稿:
   > "这三个数——{时间/漏球/往返轮次}——就是两周后要改变的数。
   > 第一周我们把现状钉死(你签字确认口径),第二周 capability 上线,同口径复测。"
3. **收费触发点 = baseline 被签认**,不是 demo 被夸。当场约定:两周 onboarding、
   到期 binary ask(转付费或结束),条款不因为是朋友而省略——朋友的夸奖是假信号,
   签字和付款才是信号。

---

## 第 5 步 · Fallback 与工程保险丝

- **会前预热**:落座寒暄/放视频时后台先跑第 1、2a 步(最慢的查询),
  第一段开始前结果已在手。
- 现场查询超 60 秒:念出正在查什么("正在把你 30 天的发件逐条过一遍"),沉默是事故。
- 连接失败:切换到会前跑好的 canned 结果(截图存本地),口径改为"这是刚才连上时算的"。
- 任何一张卡查询结果为空:跳过,不解释,永远不展示空结果。
- 查询语法注意:Gmail `category:` 过滤对 Workspace 域邮箱可能不生效(无分类页签),
  此时真人占比改用 `-from:noreply -from:no-reply -list:*` 近似,并口头声明是近似。

---

## Validation Notes(2026-08-31,真实 Gmail+Drive 实测)

发布前在一个真实邮箱(30 天窗口)上完整跑过一遍。结果:

| 卡片/模块 | 结果 |
|---|---|
| 工作场所判定 | ✅ 判出模式 B:收 ~200 / 发 13 / primary 5 条 / 未读≈全部 |
| 卡 1 体量结构 | ✅ 一次查询直接产出 |
| 卡 2 拉锯 catch | ✅ 命中 1 个:3 条关联线程、15+ 封、跨 3 方、14 天,含人肉转发 + 文档二次索要 + 改期 4 回合;命中线程属敏感类,按改述话术处理 |
| 卡 3 漏球 | ✅ 命中 4 个:付款失败 ×2、账户关闭最后警告、已错过的 deadline |
| 2d 重复流程 | ✅ 命中 1 类:同构审批申请 ×2 |
| Drive 盘点 | ⚠️ 30 天仅 2 个自有活跃文档——模式 B 下 Drive 卡不成立,佐证了第 1 步的必要性 |
| 回复时长/深夜卡 | ✗ 不成立,已从查询库移除 |

最大的收获:第一版假设"邮箱=工作台",实测直接翻车——由此加上了第 1 步的工作场所判定。
**先验证再发布,是这个 repo 里每个 skill 的最低门槛。**
