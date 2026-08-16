export type Vector3Tuple = [number, number, number];

export type GamePhase =
  | "intro"
  | "hunt"
  | "root-reveal"
  | "boss"
  | "loot"
  | "permission"
  | "dispatch"
  | "running"
  | "handled";

export type ControlKey = "forward" | "backward" | "left" | "right";

export type EnemySource =
  | { kind: "source"; id: string }
  | { kind: "boss" };

export interface ContextSourceSpec {
  id: string;
  label: string;
  productMeaning: string;
  evidence: string;
  position: Vector3Tuple;
  tint: string;
  shape: "watch" | "calendar" | "notes" | "memory";
}

export interface ActionStepSpec {
  id: string;
  shortLabel: string;
  productLabel: string;
  value: string;
  tint: string;
}

export interface AgentStep {
  id: string;
  label: string;
  tool: string;
  artifact: string;
}

export interface CombatTarget {
  id: string;
  kind: "symptom" | "boss";
  position: Vector3Tuple;
}
