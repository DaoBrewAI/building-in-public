import type { PointerEvent as ReactPointerEvent } from "react";
import type { ControlKey } from "../game/contracts";
import { unlockAudio } from "../game/audio";
import { useRaidStore } from "../game/store";
import { useLocale } from "./i18n";

export function TouchControls() {
  const phase = useRaidStore((state) => state.phase);
  const playerDead = useRaidStore((state) => state.playerDead);
  const setControl = useRaidStore((state) => state.setControl);
  const requestAttack = useRaidStore((state) => state.requestAttack);
  const { copy } = useLocale();
  const canAttack = phase === "hunt" || phase === "boss";

  if (playerDead || !["hunt", "root-reveal", "boss", "loot"].includes(phase)) return null;

  const beginMove = (control: ControlKey) => (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (useRaidStore.getState().playerDead) return;
    unlockAudio();
    event.currentTarget.setPointerCapture(event.pointerId);
    setControl(control, true);
  };

  const endMove = (control: ControlKey) => () => setControl(control, false);

  return (
    <div className={`touch-controls ${canAttack ? "" : "movement-only"}`} aria-label={copy.controls.mobile}>
      <div className="touch-dpad">
        <button
          className="dpad-up"
          type="button"
          aria-label={copy.controls.forward}
          onPointerDown={beginMove("forward")}
          onPointerUp={endMove("forward")}
          onPointerCancel={endMove("forward")}
          onLostPointerCapture={endMove("forward")}
        >↑</button>
        <button
          className="dpad-left"
          type="button"
          aria-label={copy.controls.left}
          onPointerDown={beginMove("left")}
          onPointerUp={endMove("left")}
          onPointerCancel={endMove("left")}
          onLostPointerCapture={endMove("left")}
        >←</button>
        <button
          className="dpad-right"
          type="button"
          aria-label={copy.controls.right}
          onPointerDown={beginMove("right")}
          onPointerUp={endMove("right")}
          onPointerCancel={endMove("right")}
          onLostPointerCapture={endMove("right")}
        >→</button>
        <button
          className="dpad-down"
          type="button"
          aria-label={copy.controls.backward}
          onPointerDown={beginMove("backward")}
          onPointerUp={endMove("backward")}
          onPointerCancel={endMove("backward")}
          onLostPointerCapture={endMove("backward")}
        >↓</button>
      </div>
      {canAttack && (
        <button
          className="touch-attack"
          type="button"
          aria-label={copy.controls.attack}
          onPointerDown={() => {
            unlockAudio();
            requestAttack();
          }}
        >
          <span>{copy.controls.attackShort}</span>
          <small>{copy.controls.attackKey}</small>
        </button>
      )}
    </div>
  );
}
