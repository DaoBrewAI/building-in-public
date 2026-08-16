import { useEffect } from "react";
import type { ControlKey, GamePhase } from "./contracts";
import { useRaidStore } from "./store";

const KEY_TO_CONTROL: Readonly<Record<string, ControlKey>> = {
  KeyW: "forward",
  ArrowUp: "forward",
  KeyS: "backward",
  ArrowDown: "backward",
  KeyA: "left",
  ArrowLeft: "left",
  KeyD: "right",
  ArrowRight: "right",
};

const CONTROL_KEYS: ControlKey[] = ["forward", "backward", "left", "right"];

const PLAYABLE_PHASES = new Set<GamePhase>(["hunt", "root-reveal", "boss", "loot"]);

function isUiTarget(target: EventTarget | null) {
  if (!(target instanceof Element)) return false;

  return Boolean(
    target.closest(
      [
        "button",
        "a[href]",
        "input",
        "select",
        "textarea",
        "label",
        "[contenteditable='true']",
        "[role='button']",
        "[role='link']",
        "[role='dialog']",
        "[data-ui]",
        "[data-no-combat-input]",
      ].join(","),
    ),
  );
}

function clearControls() {
  const { setControl } = useRaidStore.getState();
  for (const control of CONTROL_KEYS) setControl(control, false);
}

export function useRaidInput() {
  const phase = useRaidStore((state) => state.phase);
  const playerDead = useRaidStore((state) => state.playerDead);

  useEffect(() => {
    if (playerDead || !PLAYABLE_PHASES.has(phase)) clearControls();
  }, [phase, playerDead]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      const control = KEY_TO_CONTROL[event.code];
      const state = useRaidStore.getState();

      if (control) {
        if (state.playerDead || isUiTarget(event.target) || !PLAYABLE_PHASES.has(state.phase)) return;
        event.preventDefault();
        state.setControl(control, true);
        return;
      }

      if (event.code !== "Space" || event.repeat || isUiTarget(event.target)) return;
      if (state.playerDead || (state.phase !== "hunt" && state.phase !== "boss")) return;

      event.preventDefault();
      state.requestAttack();
    };

    const handleKeyUp = (event: KeyboardEvent) => {
      const control = KEY_TO_CONTROL[event.code];
      if (!control) return;

      event.preventDefault();
      useRaidStore.getState().setControl(control, false);
    };

    const handlePointerDown = (event: PointerEvent) => {
      if (event.button !== 0 || isUiTarget(event.target)) return;

      const state = useRaidStore.getState();
      if (!state.playerDead && (state.phase === "hunt" || state.phase === "boss")) state.requestAttack();
    };

    const handleVisibilityChange = () => {
      if (document.visibilityState !== "visible") clearControls();
    };

    window.addEventListener("keydown", handleKeyDown, { passive: false });
    window.addEventListener("keyup", handleKeyUp, { passive: false });
    window.addEventListener("blur", clearControls);
    document.addEventListener("pointerdown", handlePointerDown);
    document.addEventListener("visibilitychange", handleVisibilityChange);

    return () => {
      window.removeEventListener("keydown", handleKeyDown);
      window.removeEventListener("keyup", handleKeyUp);
      window.removeEventListener("blur", clearControls);
      document.removeEventListener("pointerdown", handlePointerDown);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      clearControls();
    };
  }, []);
}
