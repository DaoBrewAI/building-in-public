import { useEffect, useRef, useState } from "react";
import { playTone, unlockAudio } from "./audio";
import type { GamePhase } from "./contracts";
import { useRaidInput } from "./input";
import { useRaidStore } from "./store";

const DISPATCH_DELAY_MS = 1_350;
const REDUCED_DISPATCH_DELAY_MS = 420;
const EXECUTION_DURATION_MS = 8_200;
const REDUCED_EXECUTION_DURATION_MS = 3_100;

function usePrefersReducedMotion() {
  const [reducedMotion, setReducedMotion] = useState(() =>
    window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  );

  useEffect(() => {
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    const handleChange = () => setReducedMotion(media.matches);
    media.addEventListener("change", handleChange);
    return () => media.removeEventListener("change", handleChange);
  }, []);

  return reducedMotion;
}

interface SoundSnapshot {
  phase: GamePhase;
  impactNonce: number;
  playerDamageNonce: number;
  playerDead: boolean;
  contextCount: number;
  weaponEquipped: boolean;
  bossBlockedNonce: number;
  artifactReady: boolean;
}

export function RaidDirector() {
  useRaidInput();

  const phase = useRaidStore((state) => state.phase);
  const impactNonce = useRaidStore((state) => state.impactNonce);
  const playerDamageNonce = useRaidStore((state) => state.playerDamageNonce);
  const playerDead = useRaidStore((state) => state.playerDead);
  const contextCount = useRaidStore((state) => state.collectedSources.length);
  const weaponEquipped = useRaidStore((state) => state.weaponEquipped);
  const bossBlockedNonce = useRaidStore((state) => state.bossBlockedNonce);
  const artifactReady = useRaidStore((state) => state.artifactReady);
  const audioEnabled = useRaidStore((state) => state.audioEnabled);
  const reducedMotion = usePrefersReducedMotion();
  const previousSoundState = useRef<SoundSnapshot>({
    phase,
    impactNonce,
    playerDamageNonce,
    playerDead,
    contextCount,
    weaponEquipped,
    bossBlockedNonce,
    artifactReady,
  });

  useEffect(() => {
    const unlockAfterStart = () => {
      const state = useRaidStore.getState();
      if (state.phase !== "intro" && state.audioEnabled) unlockAudio();
    };

    // React handles the start button before the event bubbles to document, so
    // the store has already entered `hunt` while browser user activation is
    // still available to resume Web Audio.
    document.addEventListener("click", unlockAfterStart);
    return () => document.removeEventListener("click", unlockAfterStart);
  }, []);

  useEffect(() => {
    const previous = previousSoundState.current;

    if (phase === "hunt" && previous.phase === "intro") {
      if (audioEnabled) unlockAudio();
      playTone("start", audioEnabled);
    }
    if (impactNonce > previous.impactNonce) playTone("hit", audioEnabled);
    if (bossBlockedNonce > previous.bossBlockedNonce) playTone("blocked", audioEnabled);
    if (playerDamageNonce > previous.playerDamageNonce) playTone("hurt", audioEnabled);
    if (playerDead && !previous.playerDead) playTone("death", audioEnabled);
    if (contextCount > previous.contextCount) playTone("evidence", audioEnabled);
    if (weaponEquipped && !previous.weaponEquipped) playTone("weapon", audioEnabled);
    if (
      phase === "boss" &&
      previous.phase !== "boss" &&
      !(weaponEquipped && !previous.weaponEquipped)
    ) {
      playTone("boss", audioEnabled);
    }
    if (phase === "loot" && previous.phase !== "loot") playTone("loot", audioEnabled);
    if (phase === "dispatch" && previous.phase !== "dispatch") {
      playTone("dispatch", audioEnabled);
    }
    if (artifactReady && !previous.artifactReady) playTone("artifact", audioEnabled);

    previousSoundState.current = {
      phase,
      impactNonce,
      playerDamageNonce,
      playerDead,
      contextCount,
      weaponEquipped,
      bossBlockedNonce,
      artifactReady,
    };
  }, [
    artifactReady,
    audioEnabled,
    bossBlockedNonce,
    contextCount,
    impactNonce,
    phase,
    playerDamageNonce,
    playerDead,
    weaponEquipped,
  ]);

  useEffect(() => {
    if (phase !== "dispatch") return;

    const timer = window.setTimeout(
      () => useRaidStore.getState().beginExecution(),
      reducedMotion ? REDUCED_DISPATCH_DELAY_MS : DISPATCH_DELAY_MS,
    );
    return () => window.clearTimeout(timer);
  }, [phase, reducedMotion]);

  useEffect(() => {
    if (phase !== "running") return;

    const initialProgress = useRaidStore.getState().agentProgress;
    const fullDuration = reducedMotion ? REDUCED_EXECUTION_DURATION_MS : EXECUTION_DURATION_MS;
    const duration = Math.max(1, fullDuration * (1 - initialProgress));
    const startedAt = performance.now();
    let lastPublishedAt = startedAt - 100;
    let frame = 0;
    let cancelled = false;

    const advance = (now: number) => {
      if (cancelled) return;

      const elapsed = Math.min(1, (now - startedAt) / duration);
      const progress = initialProgress + (1 - initialProgress) * elapsed;
      if (now - lastPublishedAt >= 100 || elapsed >= 1) {
        lastPublishedAt = now;
        useRaidStore.getState().setAgentProgress(progress);
      }

      if (elapsed >= 1) {
        useRaidStore.getState().completeArtifact();
        return;
      }

      frame = window.requestAnimationFrame(advance);
    };

    frame = window.requestAnimationFrame(advance);
    return () => {
      cancelled = true;
      window.cancelAnimationFrame(frame);
    };
  }, [phase, reducedMotion]);

  return null;
}
