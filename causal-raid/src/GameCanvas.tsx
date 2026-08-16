import { Canvas } from "@react-three/fiber";
import * as THREE from "three";
import { InkWorld } from "./world/InkWorld";
import { useLowPowerMode } from "./world/useLowPowerMode";
import { useReducedMotion } from "./world/useReducedMotion";

export interface GameCanvasProps {
  className?: string;
}

export function GameCanvas({ className }: GameCanvasProps) {
  const reducedMotion = useReducedMotion();
  const lowPower = useLowPowerMode();

  return (
    <Canvas
      className={className}
      shadows="basic"
      dpr={[1, reducedMotion || lowPower ? 1.25 : 1.6]}
      camera={{ position: [8.8, 7.4, 17.5], fov: 46, near: 0.1, far: 110 }}
      gl={{ antialias: !lowPower, alpha: false, powerPreference: "high-performance", stencil: false }}
      onCreated={({ gl }) => {
        gl.toneMapping = THREE.ACESFilmicToneMapping;
        gl.toneMappingExposure = 1.22;
        gl.outputColorSpace = THREE.SRGBColorSpace;
        gl.shadowMap.enabled = true;
        gl.shadowMap.type = THREE.PCFShadowMap;
      }}
      onContextMenu={(event) => event.preventDefault()}
      style={{ width: "100%", height: "100%", display: "block", touchAction: "none" }}
    >
      <InkWorld reducedMotion={reducedMotion} lowPower={lowPower} />
    </Canvas>
  );
}

export default GameCanvas;
