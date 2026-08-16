import { useEffect, useRef, type FormEvent } from "react";
import { unlockAudio } from "../game/audio";
import { AGENT_STEPS } from "../game/demo-world";
import { MAX_PLAYER_HEALTH, useRaidStore } from "../game/store";
import { useLocale } from "./i18n";

function IntroPanel() {
  const startRaid = useRaidStore((state) => state.startRaid);
  const playerName = useRaidStore((state) => state.playerName);
  const setPlayerName = useRaidStore((state) => state.setPlayerName);
  const { copy } = useLocale();
  const nameInput = useRef<HTMLInputElement>(null);
  const displayName = playerName.trim();

  const enterRaid = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const normalizedName = playerName.trim();
    if (!normalizedName) {
      nameInput.current?.focus();
      return;
    }

    setPlayerName(normalizedName);
    unlockAudio();
    startRaid();
  };

  return (
    <section className="phase-panel intro-panel" aria-labelledby="raid-title">
      <div className="intro-copy">
        <span className="intro-kicker">{copy.intro.kicker}</span>
        <h1 id="raid-title"><i>{copy.intro.titleA}</i>{copy.intro.titleB}</h1>
        <p>{copy.intro.body}</p>
        <form className="identity-form" onSubmit={enterRaid} data-ui>
          <label className="identity-field" htmlFor="workhorse-name">
            <span>{copy.identity.nameLabel}</span>
            <input
              ref={nameInput}
              id="workhorse-name"
              name="workhorseAlias"
              type="text"
              value={playerName}
              maxLength={20}
              autoComplete="off"
              spellCheck={false}
              required
              aria-describedby="workhorse-name-hint"
              onChange={(event) => setPlayerName(event.target.value)}
            />
            <small id="workhorse-name-hint">{copy.identity.nameHint}</small>
          </label>

          {displayName && (
            <div
              className="identity-correction"
              role="status"
              aria-label={copy.identity.welcomeResult}
            >
              <span>{copy.identity.welcome}</span>
              <span className="identity-correction-mark">
                <s aria-hidden="true">{displayName}</s>
                <strong>{copy.identity.workhorseCorrection}</strong>
              </span>
            </div>
          )}

          <button className="ink-action primary-action" type="submit">
            <span>{copy.intro.action}</span>
            <small>{copy.intro.actionMeta}</small>
          </button>
        </form>
        <div className="intro-controls" aria-label={`${copy.controls.keyboard} / ${copy.controls.mobile}`}>
          <span className="desktop-hint"><kbd>WASD</kbd> {copy.controls.wasd}</span>
          <span className="desktop-hint"><kbd>SPACE</kbd> {copy.controls.attackKey}</span>
          <span className="mobile-hint"><kbd>{copy.controls.mobilePad}</kbd> {copy.controls.wasd}</span>
          <span className="mobile-hint"><kbd>{copy.controls.mobileTap}</kbd> {copy.controls.attackKey}</span>
          <span>{copy.controls.recommendSound}</span>
        </div>
      </div>
      <div className="intro-omen" aria-hidden="true">
        <span>{copy.identity.scenarioLabel}</span>
        <b>{copy.identity.scenario}</b>
        <small>{copy.intro.detected}</small>
      </div>
    </section>
  );
}

function DeathPanel() {
  const playerName = useRaidStore((state) => state.playerName);
  const restartAfterDeath = useRaidStore((state) => state.restartAfterDeath);
  const { copy } = useLocale();
  const restartButton = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    restartButton.current?.focus();
  }, []);

  const restart = () => {
    unlockAudio();
    restartAfterDeath();
  };

  return (
    <section
      className="phase-panel death-panel"
      role="alertdialog"
      aria-modal="true"
      aria-label={copy.death.aria}
      aria-labelledby="death-title"
      aria-describedby="death-body"
    >
      <div className="death-card">
        <span className="death-kicker">{copy.death.kicker}</span>
        <div className="death-identity">
          <b>{playerName}</b>
          <i aria-hidden="true">/</i>
          <span>{copy.identity.workhorseLabel}</span>
        </div>
        <h2 id="death-title">{copy.death.title}</h2>
        <p id="death-body">{copy.death.body}</p>

        <div className="death-tally" aria-label={`0 / ${MAX_PLAYER_HEALTH} ${copy.health.label}`}>
          <span>{copy.health.label}</span>
          <strong>0/{MAX_PLAYER_HEALTH}</strong>
          <div aria-hidden="true">
            {Array.from({ length: MAX_PLAYER_HEALTH }, (_, index) => <i key={index} />)}
          </div>
        </div>

        <button ref={restartButton} className="ink-action death-restart" type="button" onClick={restart}>
          <span>{copy.death.restart}</span>
          <small>{copy.death.restartMeta}</small>
        </button>
      </div>
    </section>
  );
}

function ExecutionStrip() {
  const phase = useRaidStore((state) => state.phase);
  const progress = useRaidStore((state) => state.agentProgress);
  const activeStep = useRaidStore((state) => state.activeAgentStep);
  const isDispatch = phase === "dispatch";
  const { copy } = useLocale();
  const currentStep = AGENT_STEPS[activeStep] ?? AGENT_STEPS[0];
  const stepCopy = copy.execution.steps[currentStep.id as keyof typeof copy.execution.steps];
  const percent = Math.round(progress * 100);

  return (
    <aside className="execution-strip" role="status" aria-live="polite">
      <div className="execution-strip-title">
        <span>{isDispatch ? copy.execution.ready : copy.execution.running}</span>
        <strong>{isDispatch ? copy.execution.readyTitle : copy.execution.runningTitle}</strong>
      </div>
      <div className="execution-strip-step">
        <small>{stepCopy.tool}</small>
        <b>{stepCopy.label}</b>
        <em>{percent.toString().padStart(2, "0")}%</em>
      </div>
      <div className="execution-strip-progress" aria-hidden="true">
        <i style={{ transform: `scaleX(${progress})` }} />
      </div>
    </aside>
  );
}

function HandledPanel() {
  const resetRaid = useRaidStore((state) => state.resetRaid);
  const { copy } = useLocale();

  return (
    <section className="phase-panel handled-panel" aria-labelledby="handled-title">
      <div className="handled-seal" aria-hidden="true">{copy.handled.seal}</div>
      <div className="handled-copy">
        <span>{copy.handled.returned}</span>
        <h2 id="handled-title">{copy.handled.title}</h2>
        <p><strong>{copy.handled.artifact}</strong> {copy.handled.body}</p>

        <aside className="beta-invite" aria-labelledby="beta-invite-title">
          <span>{copy.handled.betaKicker}</span>
          <h3 id="beta-invite-title">{copy.handled.betaTitle}</h3>
          <p>{copy.handled.betaBody}</p>
          <div className="beta-invite-actions">
            <a
              className="ink-action beta-action"
              href="https://daobrew.ai/"
              target="_blank"
              rel="noreferrer"
            >
              <span>{copy.handled.joinBeta}</span>
              <small>{copy.handled.betaMeta}</small>
            </a>
            <a
              className="beta-site-link"
              href="https://daobrew.ai/"
              target="_blank"
              rel="noreferrer"
            >
              {copy.handled.betaSite}
            </a>
          </div>
        </aside>

        <button className="ink-action quiet-action" type="button" onClick={resetRaid}>
          <span>{copy.handled.replay}</span>
          <small>{copy.handled.replayMeta}</small>
        </button>
      </div>
    </section>
  );
}

export function PhasePanels() {
  const phase = useRaidStore((state) => state.phase);
  const playerDead = useRaidStore((state) => state.playerDead);

  if (playerDead) return <DeathPanel />;
  if (phase === "intro") return <IntroPanel />;
  if (phase === "dispatch" || phase === "running") return <ExecutionStrip />;
  if (phase === "handled") return <HandledPanel />;
  return null;
}
