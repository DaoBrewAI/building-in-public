import { ContactShadows } from "@react-three/drei";
import { AgentJourney, EvidenceNetwork, LootField, RootBoss } from "./Encounters";
import { HuntGuide, PlayerController, SymptomEnemies } from "./Actors";
import { InkPostProcessing, SceneDirector } from "./SceneDirector";
import { WorldEnvironment } from "./WorldEnvironment";

export function InkWorld({ reducedMotion, lowPower }: { reducedMotion: boolean; lowPower: boolean }) {
  return (
    <>
      <color attach="background" args={["#080a08"]} />
      <fogExp2 attach="fog" args={["#090c09", 0.027]} />
      <WorldEnvironment reducedMotion={reducedMotion} />
      <EvidenceNetwork />
      <SymptomEnemies />
      <HuntGuide reducedMotion={reducedMotion} />
      <RootBoss />
      <LootField />
      <AgentJourney reducedMotion={reducedMotion} />
      <PlayerController reducedMotion={reducedMotion} />
      <ContactShadows
        position={[0, 0.02, 0]}
        scale={28}
        opacity={0.32}
        blur={2.4}
        far={7}
        resolution={reducedMotion || lowPower ? 256 : 512}
        color="#020302"
      />
      <SceneDirector reducedMotion={reducedMotion} />
      <InkPostProcessing reducedMotion={reducedMotion} lowPower={lowPower} />
    </>
  );
}
