import { create } from "zustand";
import { ACTION_STEPS, AGENT_STEPS, CONTEXT_SOURCES } from "./demo-world";
import type { ControlKey, EnemySource, GamePhase, Vector3Tuple } from "./contracts";

export const MAX_PLAYER_HEALTH = 10;
export const UNARMED_BOSS_DAMAGE = 5;
export const ARMED_ENEMY_DAMAGE = 1;
const PLAYER_INVULNERABILITY_MS = 780;

type SourceEnemyState = Record<string, { health: number; defeated: boolean }>;
type BossHitResult = "blocked" | "hit" | "ignored";

interface RaidState {
  phase: GamePhase;
  runNonce: number;
  controls: Record<ControlKey, boolean>;
  playerName: string;
  playerPosition: Vector3Tuple;
  playerHealth: number;
  playerDead: boolean;
  playerDamageNonce: number;
  lastDamageAmount: number;
  lastDamageSource: EnemySource | null;
  attackNonce: number;
  impactNonce: number;
  sourceEnemies: SourceEnemyState;
  collectedSources: string[];
  weaponForged: boolean;
  weaponEquipped: boolean;
  bossBlockedNonce: number;
  bossLocks: number;
  collectedSteps: string[];
  agentProgress: number;
  activeAgentStep: number;
  artifactReady: boolean;
  audioEnabled: boolean;
  setPlayerName: (name: string) => void;
  setControl: (control: ControlKey, active: boolean) => void;
  setPlayerPosition: (position: Vector3Tuple) => void;
  requestAttack: () => void;
  startRaid: () => void;
  hitSource: (id: string) => void;
  collectSource: (id: string) => void;
  equipWeapon: () => void;
  hitBoss: () => BossHitResult;
  takePlayerHit: (source: EnemySource) => boolean;
  collectStep: (id: string) => void;
  beginExecution: () => void;
  setAgentProgress: (progress: number) => void;
  completeArtifact: () => void;
  setAudioEnabled: (enabled: boolean) => void;
  restartAfterDeath: () => void;
  resetRaid: () => void;
}

const initialSourceEnemies = (): SourceEnemyState =>
  Object.fromEntries(
    CONTEXT_SOURCES.map((source) => [source.id, { health: 2, defeated: false }]),
  );

const initialControls = (): Record<ControlKey, boolean> => ({
  forward: false,
  backward: false,
  left: false,
  right: false,
});

let bossGuardUntil = 0;
let playerInvulnerableUntil = 0;
let bossDefeatTimer: number | null = null;
let stepCompletionTimer: number | null = null;

function clearBossDefeatTimer() {
  if (bossDefeatTimer !== null) window.clearTimeout(bossDefeatTimer);
  bossDefeatTimer = null;
}

function clearStepCompletionTimer() {
  if (stepCompletionTimer !== null) window.clearTimeout(stepCompletionTimer);
  stepCompletionTimer = null;
}

function clearRunTimers() {
  clearBossDefeatTimer();
  clearStepCompletionTimer();
  bossGuardUntil = 0;
  playerInvulnerableUntil = 0;
}

export const useRaidStore = create<RaidState>((set, get) => ({
  phase: "intro",
  runNonce: 0,
  controls: initialControls(),
  playerName: "",
  playerPosition: [0, 0.55, 9],
  playerHealth: MAX_PLAYER_HEALTH,
  playerDead: false,
  playerDamageNonce: 0,
  lastDamageAmount: 0,
  lastDamageSource: null,
  attackNonce: 0,
  impactNonce: 0,
  sourceEnemies: initialSourceEnemies(),
  collectedSources: [],
  weaponForged: false,
  weaponEquipped: false,
  bossBlockedNonce: 0,
  bossLocks: 4,
  collectedSteps: [],
  agentProgress: 0,
  activeAgentStep: 0,
  artifactReady: false,
  audioEnabled: true,

  setPlayerName: (playerName) => set({ playerName: playerName.slice(0, 20) }),

  setControl: (control, active) => {
    if (get().playerDead) return;
    set((state) => ({ controls: { ...state.controls, [control]: active } }));
  },

  setPlayerPosition: (playerPosition) => set({ playerPosition }),

  requestAttack: () => {
    const current = get();
    if (current.playerDead || (current.phase !== "hunt" && current.phase !== "boss")) return;
    set({ attackNonce: current.attackNonce + 1 });
  },

  startRaid: () => {
    clearRunTimers();
    set((state) => ({
      phase: "hunt",
      runNonce: state.runNonce + 1,
      controls: initialControls(),
      playerPosition: [0, 0.55, 9],
      playerHealth: MAX_PLAYER_HEALTH,
      playerDead: false,
      playerDamageNonce: 0,
      lastDamageAmount: 0,
      lastDamageSource: null,
      attackNonce: 0,
      impactNonce: 0,
      sourceEnemies: initialSourceEnemies(),
      collectedSources: [],
      weaponForged: false,
      weaponEquipped: false,
      bossBlockedNonce: 0,
      bossLocks: 4,
      collectedSteps: [],
      agentProgress: 0,
      activeAgentStep: 0,
      artifactReady: false,
    }));
  },

  hitSource: (id) => {
    const current = get();
    if (current.phase !== "hunt" || current.playerDead) return;
    const target = current.sourceEnemies[id];
    if (!target || target.defeated) return;

    const health = Math.max(0, target.health - 1);
    const sourceEnemies = {
      ...current.sourceEnemies,
      [id]: { health, defeated: health === 0 },
    };
    set({ sourceEnemies, impactNonce: current.impactNonce + 1 });
  },

  collectSource: (id) => {
    const current = get();
    if (
      current.phase !== "hunt" ||
      !current.sourceEnemies[id]?.defeated ||
      current.collectedSources.includes(id)
    ) {
      return;
    }

    const collectedSources = [...current.collectedSources, id];
    const weaponForged = collectedSources.length === CONTEXT_SOURCES.length;
    set({
      collectedSources,
      weaponForged,
      phase: weaponForged ? "root-reveal" : current.phase,
    });
  },

  equipWeapon: () => {
    const current = get();
    if (
      current.phase !== "root-reveal" ||
      !current.weaponForged ||
      current.weaponEquipped ||
      current.collectedSources.length !== CONTEXT_SOURCES.length
    ) {
      return;
    }
    playerInvulnerableUntil = performance.now() + 650;
    set({
      phase: "boss",
      weaponEquipped: true,
      playerHealth: MAX_PLAYER_HEALTH,
    });
  },

  hitBoss: () => {
    const current = get();
    if (
      current.playerDead ||
      (current.phase !== "hunt" && current.phase !== "boss") ||
      current.bossLocks === 0
    ) {
      return "ignored";
    }

    if (!current.weaponEquipped || current.phase !== "boss") {
      set({ bossBlockedNonce: current.bossBlockedNonce + 1 });
      return "blocked";
    }

    const now = performance.now();
    if (now < bossGuardUntil) return "ignored";
    const bossLocks = Math.max(0, current.bossLocks - 1);
    set({ bossLocks, impactNonce: current.impactNonce + 1 });

    if (bossLocks === 2) bossGuardUntil = now + 850;
    if (bossLocks === 0) {
      bossGuardUntil = now + 500;
      clearBossDefeatTimer();
      bossDefeatTimer = window.setTimeout(() => {
        const latest = get();
        if (latest.phase === "boss" && latest.bossLocks === 0) set({ phase: "loot" });
        bossDefeatTimer = null;
      }, 360);
    }
    return "hit";
  },

  takePlayerHit: (source) => {
    const current = get();
    if (
      current.playerDead ||
      (current.phase !== "hunt" && current.phase !== "boss")
    ) {
      return false;
    }
    if (source.kind === "source" && current.sourceEnemies[source.id]?.defeated !== false) {
      return false;
    }
    if (source.kind === "source" && current.phase !== "hunt") return false;
    if (source.kind === "boss" && current.bossLocks === 0) return false;

    const now = performance.now();
    if (now < playerInvulnerableUntil) return false;
    playerInvulnerableUntil = now + PLAYER_INVULNERABILITY_MS;

    const damage =
      source.kind === "boss" && !current.weaponEquipped
        ? UNARMED_BOSS_DAMAGE
        : ARMED_ENEMY_DAMAGE;
    const playerHealth = Math.max(0, current.playerHealth - damage);
    const playerDead = playerHealth === 0;
    if (playerDead) clearRunTimers();
    set({
      playerHealth,
      playerDead,
      playerDamageNonce: current.playerDamageNonce + 1,
      lastDamageAmount: damage,
      lastDamageSource: source,
      controls: playerDead ? initialControls() : current.controls,
    });
    return true;
  },

  collectStep: (id) => {
    const current = get();
    if (current.phase !== "loot" || current.collectedSteps.includes(id)) return;
    const collectedSteps = [...current.collectedSteps, id];
    set({ collectedSteps });

    if (collectedSteps.length === ACTION_STEPS.length) {
      clearStepCompletionTimer();
      stepCompletionTimer = window.setTimeout(() => {
        const latest = get();
        if (
          latest.phase === "loot" &&
          latest.collectedSteps.length === ACTION_STEPS.length
        ) {
          set({ phase: "dispatch", agentProgress: 0, activeAgentStep: 0 });
        }
        stepCompletionTimer = null;
      }, 950);
    }
  },

  beginExecution: () => {
    if (get().phase === "dispatch") set({ phase: "running" });
  },

  setAgentProgress: (progress) => {
    const clamped = Math.min(1, Math.max(0, progress));
    const activeAgentStep = Math.min(
      AGENT_STEPS.length - 1,
      Math.floor(clamped * AGENT_STEPS.length),
    );
    set({ agentProgress: clamped, activeAgentStep });
  },

  completeArtifact: () => set({ phase: "handled", agentProgress: 1, artifactReady: true }),

  setAudioEnabled: (audioEnabled) => set({ audioEnabled }),

  restartAfterDeath: () => {
    const current = get();
    if (!current.playerDead) return;
    clearRunTimers();
    set({
      phase: "hunt",
      runNonce: current.runNonce + 1,
      controls: initialControls(),
      playerPosition: [0, 0.55, 9],
      playerHealth: MAX_PLAYER_HEALTH,
      playerDead: false,
      playerDamageNonce: 0,
      lastDamageAmount: 0,
      lastDamageSource: null,
      attackNonce: 0,
      impactNonce: 0,
      sourceEnemies: initialSourceEnemies(),
      collectedSources: [],
      weaponForged: false,
      weaponEquipped: false,
      bossBlockedNonce: 0,
      bossLocks: 4,
      collectedSteps: [],
      agentProgress: 0,
      activeAgentStep: 0,
      artifactReady: false,
    });
  },

  resetRaid: () => {
    clearRunTimers();
    set((state) => ({
      phase: "intro",
      runNonce: state.runNonce + 1,
      controls: initialControls(),
      playerPosition: [0, 0.55, 9],
      playerHealth: MAX_PLAYER_HEALTH,
      playerDead: false,
      playerDamageNonce: 0,
      lastDamageAmount: 0,
      lastDamageSource: null,
      attackNonce: 0,
      impactNonce: 0,
      sourceEnemies: initialSourceEnemies(),
      collectedSources: [],
      weaponForged: false,
      weaponEquipped: false,
      bossBlockedNonce: 0,
      bossLocks: 4,
      collectedSteps: [],
      agentProgress: 0,
      activeAgentStep: 0,
      artifactReady: false,
    }));
  },
}));
