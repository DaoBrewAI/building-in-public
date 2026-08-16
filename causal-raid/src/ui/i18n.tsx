import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import type { GamePhase } from "../game/contracts";

export type Locale = "en" | "zh";

const EN = {
  documentTitle: "DaoBrew: The 5:55 PM Raid",
  brand: { name: "DaoBrew AI", mode: "WORKDAY RAID" },
  language: { label: "Switch language", current: "EN", next: "中文" },
  sound: { on: "SOUND", off: "MUTED", turnOn: "Turn sound on", turnOff: "Turn sound off" },
  objectives: {
    intro: { kicker: "CLOCK-IN RAID", title: "The 5:55 PM quick thing has arrived." },
    hunt: { kicker: "THE WAY HOME IS BLOCKED", title: "Defeat One Quick Thing. If brute force fails, find what makes it vulnerable." },
    "root-reveal": { kicker: "CONTEXT COMPLETE", title: "The Causality Blade is forged. Walk through it to equip and heal." },
    boss: { kicker: "CAUSALITY BLADE EQUIPPED", title: "The Boss can take damage now. Its counterattack costs only 1 HRV." },
    loot: { kicker: "ONE BIG THING, THREE SMALL MOVES", title: "Collect all three actions. They assemble into an executable task." },
    permission: { kicker: "AUTO-ASSEMBLING", title: "The complete task will dispatch without another meeting." },
    dispatch: { kicker: "TASK ASSEMBLED", title: "The paper-bird Agent is taking it from here." },
    running: { kicker: "AGENT IN FLIGHT", title: "It carries the task toward the light. No status chasing required." },
    handled: { kicker: "TASK CAME BACK FINISHED", title: "Four sources became one cause, three actions, and a handled task." },
  } satisfies Record<GamePhase, { kicker: string; title: string }>,
  controls: {
    keyboard: "Keyboard controls",
    wasd: "MOVE",
    attackKey: "CUT IT",
    mobile: "Touch controls",
    forward: "Forward",
    backward: "Back",
    left: "Left",
    right: "Right",
    mobilePad: "D-PAD",
    mobileTap: "TAP",
    attack: "Slash",
    attackShort: "CUT IT",
    recommendSound: "Sound recommended",
  },
  intro: {
    kicker: "ONE LAST TASK BEFORE YOU CLOCK OUT",
    titleA: "WORK",
    titleB: "HORSE",
    body: "One last task stands between you and clocking out. Rush it head-on and it will flatten you. Find what is blocking the work, finish it fast, and escape before the ‘quick thing’ owns your night.",
    action: "FINISH THE JOB",
    actionMeta: "GET OUT BEFORE 6",
    omen: "5:55 PM",
    detected: "1 LAST TASK · CLOCK IS TICKING",
  },
  identity: {
    nameLabel: "TYPE YOUR NAME",
    nameHint: "So the Boss knows who to hit.",
    scenarioLabel: "TODAY'S INCIDENT",
    scenario: "5:55 PM: ONE QUICK THING",
    workhorseLabel: "CERTIFIED WORKHORSE",
    welcome: "WELCOME,",
    workhorseCorrection: "WORK HORSE.",
    welcomeResult: "Welcome, work horse.",
  },
  health: {
    label: "WORKHORSE HRV",
    aria: "Workhorse HRV buffer",
  },
  death: {
    kicker: "CLOCKED OUT BY FORCE",
    title: "THE QUICK THING WAS NOT QUICK",
    body: "Without context, one Boss hit costs 5 HRV. Clock in again; after the ceremonial bad decision, retreat and collect all four sources.",
    restart: "CLOCK IN AGAIN",
    restartMeta: "RESTART WITH 10 HRV",
    aria: "Workhorse defeated",
  },
  evidence: {
    heading: "SCATTERED CONTEXT",
    aria: "Four context sources",
    locked: "Still scattered",
    collected: "Loaded",
    sources: {
      biometrics: { label: "BIOMETRICS · THE WATCH SNITCHED", evidence: "Sleep, heart rate, recovery, and stress all say this ‘quick thing’ started hours ago." },
      calendar: { label: "CALENDAR · THE CRIME SCENE", evidence: "Back-to-back meetings left no focus block for the work everyone called urgent." },
      "meeting-notes": { label: "MEETING NOTES · THE CALL HAS RECEIPTS", evidence: "The decisions, promises, and loose ends survived the call." },
      "agent-memory": { label: "AGENT MEMORY · NO AMNESIA", evidence: "Prior attempts, useful code, failures, and unfinished work are still here." },
    },
  },
  boss: {
    aria: "One Quick Thing boss status",
    label: "CENTRAL WORK-PRESSURE BOSS",
    name: "ONE QUICK THING",
    locksRemaining: "layers of work left",
    shielded: "CONTEXT MISSING · BLADE REJECTED",
    shieldHint: "Knowing what is overdue explains the panic. It still does not produce a next action. Collect all four sources.",
    vulnerable: "CAUSALITY EXPOSED · DAMAGE ENABLED",
    blocked: "ATTACK DEFLECTED",
    blockedHint: "You only know it is overdue, not what to do next. One hit costs 5 HRV.",
  },
  root: {
    label: "WHY THE ‘QUICK THING’ FELT IMPOSSIBLE",
    candidate: "A deadline explained the panic, not what to do next. Linking four sources exposed three small actions.",
    note: "DaoBrew connects the causal context before deciding what should happen next.",
  },
  weapon: {
    kicker: "4/4 CONTEXT SOURCES LINKED",
    title: "CAUSALITY BLADE · 断因",
    body: "A deadline is not a next action. Four linked sources expose the cause. Walk through to equip, restore HRV, and make the Boss vulnerable.",
  },
  loot: {
    aria: "Three actions that make the work executable",
    heading: "THREE ACTIONS · ONE EXECUTABLE TASK",
    seal: "GO",
    items: {
      "name-output": { short: "NAME THE DELIVERABLE", product: "ACTION 01", value: "Turn ‘one quick thing’ into one concrete deliverable." },
      "next-actions": { short: "ORDER THE NEXT 3 MOVES", product: "ACTION 02", value: "Choose the three smallest useful moves and put them in order." },
      "done-check": { short: "LOCK THE FINISH LINE", product: "ACTION 03", value: "Give the Agent a finish line it can verify." },
    },
  },
  permission: {
    defeated: "THE BIG THING IS NOW THREE SMALL THINGS",
    title: "The task assembles itself as you collect the actions.",
    boundary: "NO EXTRA MEETING",
    allowed: "The paper-bird Agent takes it automatically",
    publish: "This authored demo performs no real external action.",
    action: "AUTO-DISPATCH",
    actionMeta: "NO EXTRA BUTTON NEEDED",
  },
  execution: {
    ready: "TASK ASSEMBLED",
    running: "PAPER-BIRD AGENT IN FLIGHT",
    readyTitle: "The work finally knows where to go.",
    runningTitle: "It took the task and flew toward the light.",
    readyBody: "Three actions became one executable task. No extra meeting and no manual rerouting.",
    runningBody: "The Agent carries the full context, the next moves, and a finish line. You can stop chasing status.",
    beginMeta: "AUTO-DISPATCHING",
    steps: {
      frame: { tool: "CONTEXT", label: "Read all four sources" },
      combat: { tool: "AGENT", label: "Execute the next action" },
      verify: { tool: "VERIFY", label: "Return completion evidence" },
    },
    done: "DONE",
    active: "DOING IT",
    queued: "UP NEXT",
    readout: "FLIGHT PROGRESS",
  },
  handled: {
    seal: "DONE",
    returned: "THE PAPER BIRD CAME BACK",
    title: "HANDLED · NO STATUS CHASING",
    artifact: "The executable task",
    body: "came back with completion evidence. DaoBrew linked the context, exposed the cause, turned it into three actions, and the Agent carried them through.",
    betaKicker: "RAID CLEARED · NOW TRY THE REAL THING",
    betaTitle: "THE BOSS WAS FAKE. CLOCKING OFF IS REAL.",
    betaBody: "The flow you just played finds the blocker, breaks the work into next moves, and lets the Agent carry them forward. It now lives in the DaoBrew macOS app. Free during beta.",
    joinBeta: "JOIN THE BETA",
    betaMeta: "macOS · FREE DURING BETA",
    betaSite: "DAOBREW.AI ↗",
    replay: "CLOCK IN AGAIN",
    replayMeta: "REPLAY THE 5:55 PM RAID",
  },
} as const;

type DeepStrings<T> = {
  [K in keyof T]: T[K] extends string ? string : DeepStrings<T[K]>;
};

export type Dictionary = DeepStrings<typeof EN>;

const ZH: Dictionary = {
  documentTitle: "DaoBrew：17:55 打工副本",
  brand: { name: "DaoBrew AI", mode: "打工副本" },
  language: { label: "切换语言", current: "中文", next: "EN" },
  sound: { on: "声音", off: "静音", turnOn: "打开声音", turnOff: "关闭声音" },
  objectives: {
    intro: { kicker: "打卡副本", title: "17:55，有个小事来了" },
    hunt: { kicker: "下班路被堵了", title: "干掉「有个小事」。硬砍不动，就找让它破防的办法" },
    "root-reveal": { kicker: "上下文收齐，武器已合成", title: "走过去自动装备「断因」，牛马 HRV 回满" },
    boss: { kicker: "因果律武装已装备", title: "现在 Boss 能砍了，它反击也只能 HRV -1" },
    loot: { kicker: "一坨大活，砍成三个动作", title: "捡完三个动作，自动拼成 Agent 能执行的任务" },
    permission: { kicker: "自动拼装中", title: "这次不用再开会，也不用再点一遍派发" },
    dispatch: { kicker: "任务拼好了", title: "纸鸟 Agent 会从这里自动接手" },
    running: { kicker: "Agent 起飞了", title: "它叼着任务飞向光，你不用追着问进度" },
    handled: { kicker: "活干完回来了", title: "四份上下文变成一个根因、三个动作和一份结果" },
  },
  controls: {
    keyboard: "键盘操作",
    wasd: "移动",
    attackKey: "砍活",
    mobile: "触屏游戏操作",
    forward: "向前",
    backward: "向后",
    left: "向左",
    right: "向右",
    mobilePad: "方向键",
    mobileTap: "点击",
    attack: "砍它",
    attackShort: "砍",
    recommendSound: "建议开启声音",
  },
  intro: {
    kicker: "下班前，只剩最后一个大活",
    titleA: "牛",
    titleB: "马",
    body: "最后一个大活堵在下班路上。硬着头皮冲上去，只会先把自己的 HRV 打没。想办法找出它卡在哪，赶紧干完，别让「有个小事」承包你的今晚。",
    action: "赶紧干完",
    actionMeta: "别让 17:55 变成 21:55",
    omen: "17:55",
    detected: "1 个大活 · 下班倒计时",
  },
  identity: {
    nameLabel: "输入你的名字",
    nameHint: "方便 Boss 知道该揍谁。",
    scenarioLabel: "今日副本",
    scenario: "17:55：有个小事",
    workhorseLabel: "认证牛马",
    welcome: "你好，",
    workhorseCorrection: "牛马",
    welcomeResult: "你好，牛马",
  },
  health: {
    label: "牛马 HRV",
    aria: "牛马剩余 HRV",
  },
  death: {
    kicker: "被迫下班",
    title: "「有个小事」把牛马办了",
    body: "没上下文时，Boss 一巴掌就是 HRV -5。重新上工，这次演示完头铁就撤，先去收齐四份上下文。",
    restart: "重新上班",
    restartMeta: "HRV 回满再上班",
    aria: "牛马阵亡",
  },
  evidence: {
    heading: "散落的上下文",
    aria: "四份上下文来源",
    locked: "还散落在工位",
    collected: "已接入",
    sources: {
      biometrics: { label: "BioMetrics · 手表先招了", evidence: "睡眠、心率、恢复和压力都在说：这个「小事」从中午就开始了。" },
      calendar: { label: "Calendar · 日历作案现场", evidence: "会议一场接一场，嘴上说最急的活，日历里一分钟都没留。" },
      "meeting-notes": { label: "会议记录 · 原话还在", evidence: "会上答应了什么、谁说要跟、哪里还没定，这次不用靠嗓门回忆。" },
      "agent-memory": { label: "Agent Memory · 这次没失忆", evidence: "上次试过什么、哪里翻车、代码做到哪，都还在。" },
    },
  },
  boss: {
    aria: "「有个小事」Boss 状态",
    label: "中央工作压力 Boss",
    name: "17:55 的「有个小事」",
    locksRemaining: "层大活还没拆",
    shielded: "上下文不全 · 砍了也白砍",
    shieldHint: "知道哪件事逾期，只能解释你为什么焦虑，还是没有下一步。先收齐四份上下文。",
    vulnerable: "因果链露出来了 · 现在能砍",
    blocked: "这一刀被弹回来了",
    blockedHint: "你只知道它逾期了，还不知道下一步。一巴掌就是 HRV -5。",
  },
  root: {
    label: "这个「小事」为什么像一坨",
    candidate: "Deadline 和没做完的项目，只能解释焦虑从哪来，不能直接变成下一步。四份上下文接起来，大活才露出三个能下手的动作。",
    note: "DaoBrew 把因果上下文接全，再决定下一刀砍哪。",
  },
  weapon: {
    kicker: "四份上下文已接通",
    title: "因果律武装「断因」",
    body: "知道 Deadline 还不等于有下一步。四份上下文接起来才锻成「断因」。走过去自动装备，牛马 HRV 回满。",
  },
  loot: {
    aria: "让这活能执行的三个动作",
    heading: "三个动作 · 一份能执行的任务",
    seal: "收",
    items: {
      "name-output": { short: "把要交的说清", product: "动作一", value: "把「有个小事」改成一个能交付的具体产物。" },
      "next-actions": { short: "把下一步排好", product: "动作二", value: "挑出最小的三个动作，排好先后。" },
      "done-check": { short: "把下班线写死", product: "动作三", value: "写清完成标准，让 Agent 自己知道什么时候该停。" },
    },
  },
  permission: {
    defeated: "大活已经拆成三个小活",
    title: "三个动作捡齐，任务自动拼好",
    boundary: "不用再开会分工",
    allowed: "纸鸟 Agent 会自动接手",
    publish: "这是演示，不会真的往外部系统发东西。",
    action: "自动出发",
    actionMeta: "不用再点一遍",
  },
  execution: {
    ready: "任务自动拼好了",
    running: "纸鸟 Agent 正在飞",
    readyTitle: "这活终于知道该往哪走",
    runningTitle: "它叼着任务飞向了光",
    readyBody: "三个动作拼成一份可执行任务，不用再开会，也不用再手动分发。",
    runningBody: "上下文、下一步和完成标准都带着。你不用追着问进度。",
    beginMeta: "自动出发中",
    steps: {
      frame: { tool: "上下文", label: "把四份来源读全" },
      combat: { tool: "AGENT", label: "执行下一个动作" },
      verify: { tool: "验收", label: "带着完成证据回来" },
    },
    done: "搞定",
    active: "正在干",
    queued: "排队中",
    readout: "纸鸟飞行进度",
  },
  handled: {
    seal: "交",
    returned: "纸鸟带着结果回来了",
    title: "已处理 · 不用追着问进度",
    artifact: "这份可执行任务",
    body: "已经带着完成证据回来了。DaoBrew 把四份上下文接起来，找到这坨大活卡住的因果，拆成三个动作，再让 Agent 自己跑完。",
    betaKicker: "讨伐完成 · 现在打真活",
    betaTitle: "BOSS 是假的，下班是真的。",
    betaBody: "你刚才玩过的这套流程：找出卡点、拆成下一步、交给 Agent 继续跑。现在，它已经做进 DaoBrew macOS app，Beta 期间免费。",
    joinBeta: "加入免费测试",
    betaMeta: "macOS · BETA 期间免费",
    betaSite: "DAOBREW.AI ↗",
    replay: "再来一个小事",
    replayMeta: "重打 17:55 副本",
  },
};

const DICTIONARIES: Record<Locale, Dictionary> = { en: EN, zh: ZH };

interface LocaleContextValue {
  locale: Locale;
  copy: Dictionary;
  toggleLocale: () => void;
}

const LocaleContext = createContext<LocaleContextValue | null>(null);

export function LocaleProvider({ children }: { children: ReactNode }) {
  const [locale, setLocale] = useState<Locale>("en");
  const value = useMemo<LocaleContextValue>(
    () => ({
      locale,
      copy: DICTIONARIES[locale],
      toggleLocale: () => setLocale((current) => (current === "en" ? "zh" : "en")),
    }),
    [locale],
  );

  useEffect(() => {
    document.documentElement.lang = locale === "en" ? "en" : "zh-Hans";
    document.title = DICTIONARIES[locale].documentTitle;
  }, [locale]);

  return <LocaleContext.Provider value={value}>{children}</LocaleContext.Provider>;
}

export function useLocale() {
  const context = useContext(LocaleContext);
  if (!context) throw new Error("useLocale must be used inside LocaleProvider");
  return context;
}
