import { unlockAudio } from "../game/audio";
import { useRaidStore } from "../game/store";
import { useLocale } from "./i18n";

export function SoundToggle() {
  const enabled = useRaidStore((state) => state.audioEnabled);
  const setEnabled = useRaidStore((state) => state.setAudioEnabled);
  const { copy } = useLocale();

  const toggleSound = () => {
    if (!enabled) unlockAudio();
    setEnabled(!enabled);
  };

  return (
    <button
      className="sound-toggle"
      type="button"
      aria-label={enabled ? copy.sound.turnOff : copy.sound.turnOn}
      aria-pressed={enabled}
      onClick={toggleSound}
    >
      <span className="sound-glyph" aria-hidden="true">
        <i />
        <i />
        <i />
      </span>
      <span>{enabled ? copy.sound.on : copy.sound.off}</span>
    </button>
  );
}
