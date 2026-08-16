import type { ActionStepSpec, AgentStep, ContextSourceSpec, Vector3Tuple } from "./contracts";

export const DEMO_STORY = {
  title: "5:55 PM: One Quick Thing",
  symptom: "A last-minute request feels impossible because the useful context is scattered",
  rootCandidate: "The work looks like one giant problem until the full context exposes the next actions",
  evidenceGrade: "FOUR CONTEXT SOURCES",
  artifact: "An executable task carried by the Agent",
  finalState: "HANDLED · CHECK NEXT TIME",
} as const;

export const CAUSAL_WEAPON_POSITION: Vector3Tuple = [0, 0.72, 7.15];

export const CONTEXT_SOURCES: ContextSourceSpec[] = [
  {
    id: "biometrics",
    label: "BioMetrics",
    productMeaning: "Watch signals reveal the body's pressure response",
    evidence: "Sleep, heart rate, recovery, and stress signals",
    position: [-7.8, 0.7, -5.7],
    tint: "#d58a50",
    shape: "watch",
  },
  {
    id: "calendar",
    label: "Calendar",
    productMeaning: "The schedule shows load, collisions, and recovery windows",
    evidence: "Back-to-back meetings and the missing focus block",
    position: [7.7, 0.7, -5.6],
    tint: "#c5bda8",
    shape: "calendar",
  },
  {
    id: "meeting-notes",
    label: "Meeting Notes",
    productMeaning: "Meeting notes preserve what was actually decided",
    evidence: "Decisions, commitments, and loose ends from the conversation",
    position: [-6.9, 0.7, 5.5],
    tint: "#c07b4d",
    shape: "notes",
  },
  {
    id: "agent-memory",
    label: "Agent Memory",
    productMeaning: "Agent history restores the work already attempted",
    evidence: "Prior code, decisions, failures, and unfinished execution",
    position: [6.8, 0.7, 5.7],
    tint: "#d9a95b",
    shape: "memory",
  },
];

export const ACTION_STEPS: ActionStepSpec[] = [
  {
    id: "name-output",
    shortLabel: "Name the real deliverable",
    productLabel: "ACTIONABLE STEP",
    value: "Turn 'one quick thing' into one concrete output",
    tint: "#f2bf63",
  },
  {
    id: "next-actions",
    shortLabel: "Choose the next three moves",
    productLabel: "ACTIONABLE STEP",
    value: "Put the smallest useful actions in order",
    tint: "#d58a50",
  },
  {
    id: "done-check",
    shortLabel: "Write down what done means",
    productLabel: "ACTIONABLE STEP",
    value: "Give the Agent a finish line it can verify",
    tint: "#ede1ba",
  },
];

export const AGENT_STEPS: AgentStep[] = [
  { id: "frame", label: "Read the full context", tool: "CONTEXT", artifact: "causal frame" },
  { id: "combat", label: "Execute the next action", tool: "AGENT", artifact: "work result" },
  { id: "verify", label: "Return evidence of completion", tool: "VERIFY", artifact: "handled task" },
];
