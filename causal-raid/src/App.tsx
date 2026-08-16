import { GameCanvas } from "./GameCanvas";
import { RaidDirector } from "./game/RaidDirector";
import { LocaleProvider } from "./ui/i18n";
import { PhasePanels } from "./ui/PhasePanels";
import { RaidHud } from "./ui/RaidHud";
import { TouchControls } from "./ui/TouchControls";

export function App() {
  return (
    <LocaleProvider>
      <main className="raid-shell">
        <div className="raid-world" aria-hidden="true">
          <GameCanvas />
        </div>

        <RaidDirector />
        <RaidHud />
        <PhasePanels />
        <TouchControls />

        <div className="ink-vignette" aria-hidden="true" />
        <div className="ink-grain" aria-hidden="true" />
      </main>
    </LocaleProvider>
  );
}
