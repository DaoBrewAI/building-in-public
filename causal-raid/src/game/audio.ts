type ToneKind =
  | "start"
  | "hit"
  | "blocked"
  | "hurt"
  | "death"
  | "evidence"
  | "weapon"
  | "boss"
  | "loot"
  | "dispatch"
  | "artifact";

let context: AudioContext | null = null;

function getContext() {
  if (!context) context = new AudioContext();
  return context;
}

export function unlockAudio() {
  const audio = getContext();
  if (audio.state === "suspended") void audio.resume();
}

export function playTone(kind: ToneKind, enabled = true) {
  if (!enabled) return;
  const audio = getContext();
  const now = audio.currentTime;
  const oscillator = audio.createOscillator();
  const gain = audio.createGain();
  const filter = audio.createBiquadFilter();
  const settings: Record<ToneKind, [number, number, OscillatorType, number]> = {
    start: [88, 176, "sine", 0.7],
    hit: [128, 54, "sawtooth", 0.16],
    blocked: [920, 210, "square", 0.18],
    hurt: [92, 38, "square", 0.22],
    death: [72, 25, "sawtooth", 0.85],
    evidence: [330, 660, "sine", 0.35],
    weapon: [146, 1174, "sawtooth", 0.88],
    boss: [62, 124, "square", 0.7],
    loot: [420, 840, "triangle", 0.3],
    dispatch: [150, 520, "sawtooth", 0.75],
    artifact: [220, 880, "sine", 1.2],
  };
  const [from, to, wave, duration] = settings[kind];

  oscillator.type = wave;
  oscillator.frequency.setValueAtTime(from, now);
  oscillator.frequency.exponentialRampToValueAtTime(to, now + duration);
  filter.type = "lowpass";
  filter.frequency.setValueAtTime(
    kind === "hit"
      ? 540
      : kind === "blocked"
        ? 2200
        : kind === "hurt" || kind === "death"
          ? 390
          : 1600,
    now,
  );
  gain.gain.setValueAtTime(0.0001, now);
  gain.gain.exponentialRampToValueAtTime(
    kind === "boss" || kind === "death" ? 0.16 : kind === "hurt" ? 0.12 : 0.09,
    now + 0.025,
  );
  gain.gain.exponentialRampToValueAtTime(0.0001, now + duration);

  oscillator.connect(filter);
  filter.connect(gain);
  gain.connect(audio.destination);
  oscillator.start(now);
  oscillator.stop(now + duration + 0.04);

  if (
    kind === "hit" ||
    kind === "blocked" ||
    kind === "hurt" ||
    kind === "death" ||
    kind === "boss"
  ) {
    const sub = audio.createOscillator();
    const subGain = audio.createGain();
    const transient = audio.createOscillator();
    const transientGain = audio.createGain();

    sub.type = "sine";
    const heavy = kind === "boss" || kind === "death";
    sub.frequency.setValueAtTime(heavy ? 54 : 78, now);
    sub.frequency.exponentialRampToValueAtTime(heavy ? 29 : 42, now + 0.14);
    subGain.gain.setValueAtTime(heavy ? 0.18 : 0.13, now);
    subGain.gain.exponentialRampToValueAtTime(0.0001, now + 0.15);

    transient.type = "triangle";
    transient.frequency.setValueAtTime(heavy ? 520 : 860, now);
    transient.frequency.exponentialRampToValueAtTime(170, now + 0.045);
    transientGain.gain.setValueAtTime(heavy ? 0.08 : 0.065, now);
    transientGain.gain.exponentialRampToValueAtTime(0.0001, now + 0.05);

    sub.connect(subGain);
    transient.connect(transientGain);
    subGain.connect(audio.destination);
    transientGain.connect(audio.destination);
    sub.start(now);
    transient.start(now);
    sub.stop(now + 0.17);
    transient.stop(now + 0.06);
  }
}
