import { useEffect, useRef, useState } from "react";
import { ACTION_STEPS, CONTEXT_SOURCES } from "../game/demo-world";
import { MAX_PLAYER_HEALTH, useRaidStore } from "../game/store";
import { useLocale } from "./i18n";
import { SoundToggle } from "./SoundToggle";

function ContextSourceSlots() {
  const collectedSources = useRaidStore((state) => state.collectedSources);
  const phase = useRaidStore((state) => state.phase);
  const { copy } = useLocale();

  if (!["hunt", "root-reveal", "boss"].includes(phase)) return null;

  return (
    <section className="evidence-locks" aria-label={copy.evidence.aria}>
      <div className="hud-label">{copy.evidence.heading}</div>
      <ol>
        {CONTEXT_SOURCES.map((source) => {
          const collected = collectedSources.includes(source.id);
          const sourceCopy = copy.evidence.sources[source.id as keyof typeof copy.evidence.sources];
          return (
            <li className={collected ? "is-unlocked" : ""} key={source.id}>
              <span className="lock-mark" data-source-shape={source.shape} aria-hidden="true" />
              <span>
                <b>{sourceCopy.label}</b>
                <small>
                  <span className="source-detail">
                    {collected ? (
                      <>
                        <em>{copy.evidence.collected}</em>
                        {sourceCopy.evidence}
                      </>
                    ) : copy.evidence.locked}
                  </span>
                  <span className="source-mobile-status">
                    {collected ? (
                      <em>{copy.evidence.collected}</em>
                    ) : copy.evidence.locked}
                  </span>
                </small>
              </span>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

function BossState() {
  const phase = useRaidStore((state) => state.phase);
  const bossLocks = useRaidStore((state) => state.bossLocks);
  const weaponEquipped = useRaidStore((state) => state.weaponEquipped);
  const { copy } = useLocale();

  if (phase !== "hunt" && phase !== "boss") return null;
  const isShielded = phase === "hunt" || !weaponEquipped;

  return (
    <section className={`boss-state ${isShielded ? "is-shielded" : "is-vulnerable"}`} aria-label={copy.boss.aria}>
      <div className="boss-name">
        <span>{copy.boss.label}</span>
        <strong>{copy.boss.name}</strong>
      </div>
      {isShielded ? (
        <div className="boss-shield-state">
          <b>{copy.boss.shielded}</b>
          <small>{copy.boss.shieldHint}</small>
        </div>
      ) : (
        <>
          <small className="boss-vulnerable">{copy.boss.vulnerable}</small>
          <div className="boss-seals" aria-label={`${bossLocks} ${copy.boss.locksRemaining}`}>
            {[0, 1, 2, 3].map((index) => (
              <i className={index < bossLocks ? "is-live" : "is-broken"} key={index} />
            ))}
          </div>
        </>
      )}
    </section>
  );
}

function BossBlockedFeedback() {
  const bossBlockedNonce = useRaidStore((state) => state.bossBlockedNonce);
  const playerDead = useRaidStore((state) => state.playerDead);
  const { copy } = useLocale();

  if (bossBlockedNonce === 0 || playerDead) return null;

  return (
    <div className="boss-blocked-feedback" key={bossBlockedNonce} role="status">
      <strong>{copy.boss.blocked}</strong>
      <small>{copy.boss.blockedHint}</small>
    </div>
  );
}

function LootTrack() {
  const phase = useRaidStore((state) => state.phase);
  const collectedSteps = useRaidStore((state) => state.collectedSteps);
  const { copy } = useLocale();

  if (phase !== "loot") return null;

  return (
    <section className="loot-track" aria-label={copy.loot.aria}>
      <div className="hud-label">
        {copy.loot.heading} <span>{collectedSteps.length}/{ACTION_STEPS.length}</span>
      </div>
      <ol>
        {ACTION_STEPS.map((step) => {
          const collected = collectedSteps.includes(step.id);
          const lootCopy = copy.loot.items[step.id as keyof typeof copy.loot.items];
          return (
            <li className={collected ? "is-collected" : ""} key={step.id}>
              <span className="loot-rune" aria-hidden="true">{collected ? copy.loot.seal : ""}</span>
              <span>{lootCopy.short}</span>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

function LootPickupToast() {
  const phase = useRaidStore((state) => state.phase);
  const collectedSteps = useRaidStore((state) => state.collectedSteps);
  const { copy } = useLocale();
  const previousCount = useRef(collectedSteps.length);
  const [lootId, setLootId] = useState<string | null>(null);

  useEffect(() => {
    if (collectedSteps.length <= previousCount.current) {
      previousCount.current = collectedSteps.length;
      if (phase !== "loot") setLootId(null);
      return;
    }

    const latest = collectedSteps[collectedSteps.length - 1];
    previousCount.current = collectedSteps.length;
    setLootId(latest);
    const timer = window.setTimeout(() => setLootId(null), 1500);
    return () => window.clearTimeout(timer);
  }, [collectedSteps, phase]);

  if (!lootId || phase !== "loot") return null;
  const item = copy.loot.items[lootId as keyof typeof copy.loot.items];
  return (
    <div className="loot-pickup-toast" role="status">
      <span>{item.product}</span>
      <strong>{item.short}</strong>
      <small>{item.value}</small>
    </div>
  );
}

function PlayerVitality() {
  const phase = useRaidStore((state) => state.phase);
  const playerHealth = useRaidStore((state) => state.playerHealth);
  const playerDead = useRaidStore((state) => state.playerDead);
  const { copy } = useLocale();

  if (playerDead || !["hunt", "root-reveal", "boss"].includes(phase)) return null;

  return (
    <section
      className={`player-vitality ${playerHealth <= 3 ? "is-critical" : ""}`}
      role="progressbar"
      aria-label={copy.health.aria}
      aria-valuemin={0}
      aria-valuemax={MAX_PLAYER_HEALTH}
      aria-valuenow={playerHealth}
    >
      <div className="vitality-readout">
        <span>{copy.health.label}</span>
        <strong>{playerHealth}/{MAX_PLAYER_HEALTH}</strong>
      </div>
      <div className="vitality-segments" aria-hidden="true">
        {Array.from({ length: MAX_PLAYER_HEALTH }, (_, index) => (
          <i className={index < playerHealth ? "is-live" : "is-lost"} key={index} />
        ))}
      </div>
    </section>
  );
}

function DamageFeedback() {
  const playerDamageNonce = useRaidStore((state) => state.playerDamageNonce);
  const lastDamageAmount = useRaidStore((state) => state.lastDamageAmount);
  if (playerDamageNonce === 0) return null;

  return (
    <div className="player-damage-feedback" key={playerDamageNonce} role="status" aria-live="polite">
      <strong>HRV -{lastDamageAmount}</strong>
    </div>
  );
}

export function RaidHud() {
  const phase = useRaidStore((state) => state.phase);
  const playerDead = useRaidStore((state) => state.playerDead);
  const { copy, toggleLocale } = useLocale();
  const objective = copy.objectives[phase];

  return (
    <div className={`raid-hud phase-${phase} ${playerDead ? "is-player-dead" : ""}`}>
      <header className="hud-masthead">
        <div className="raid-mark" aria-label={`${copy.brand.name} ${copy.brand.mode}`}>
          <span className="raid-sigil" aria-hidden="true">因</span>
          <span>
            <b>{copy.brand.name}</b>
            <small>{copy.brand.mode}</small>
          </span>
        </div>

        {phase !== "intro" && !playerDead && (
          <div className="current-objective" key={phase} aria-live="polite">
            <span>{objective.kicker}</span>
            <strong>{objective.title}</strong>
          </div>
        )}

        <div className="hud-settings">
          <button
            className="language-toggle"
            type="button"
            aria-label={copy.language.label}
            onClick={toggleLocale}
          >
            <span>{copy.language.current}</span>
            <b>{copy.language.next}</b>
          </button>
          <SoundToggle />
        </div>
      </header>

      {!playerDead && (
        <>
          <ContextSourceSlots />
          <BossState />
          <BossBlockedFeedback />
          <LootTrack />
          <LootPickupToast />
          <PlayerVitality />

          {phase === "root-reveal" && (
            <div className="weapon-callout" role="status">
              <span>{copy.weapon.kicker}</span>
              <strong>{copy.weapon.title}</strong>
              <small>{copy.weapon.body}</small>
            </div>
          )}

          {["hunt", "root-reveal", "boss", "loot"].includes(phase) && (
            <div className="desktop-controls" aria-label={copy.controls.keyboard}>
              <span><kbd>WASD</kbd> {copy.controls.wasd}</span>
              {(phase === "hunt" || phase === "boss") && (
                <span><kbd>SPACE</kbd> {copy.controls.attackKey}</span>
              )}
            </div>
          )}
        </>
      )}

      <DamageFeedback />
    </div>
  );
}
