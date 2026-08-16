import { Bloom, EffectComposer, Vignette } from "@react-three/postprocessing";
import { useFrame, useThree } from "@react-three/fiber";
import { useEffect, useMemo, useRef } from "react";
import * as THREE from "three";
import { CAUSAL_WEAPON_POSITION } from "../game/demo-world";
import { useRaidStore } from "../game/store";
import { isHitStopped, worldRuntime } from "./runtime";

export function SceneDirector({ reducedMotion }: { reducedMotion: boolean }) {
  const { camera } = useThree();
  const phase = useRaidStore((state) => state.phase);
  const impactNonce = useRaidStore((state) => state.impactNonce);
  const playerDamageNonce = useRaidStore((state) => state.playerDamageNonce);
  const playerDead = useRaidStore((state) => state.playerDead);
  const phaseClock = useRef(0);
  const shake = useRef(0);
  const desired = useMemo(() => new THREE.Vector3(), []);
  const target = useMemo(() => new THREE.Vector3(), []);
  const smoothTarget = useMemo(() => new THREE.Vector3(0, 1, 0), []);
  const agentPoint = useMemo(() => new THREE.Vector3(), []);
  const weaponPoint = useMemo(
    () => new THREE.Vector3(...CAUSAL_WEAPON_POSITION),
    [],
  );
  const agentCurve = useMemo(
    () =>
      new THREE.CatmullRomCurve3([
        new THREE.Vector3(0, 1.25, -1.2),
        new THREE.Vector3(-3.1, 3.1, -4.2),
        new THREE.Vector3(2.4, 4.25, -8.2),
        new THREE.Vector3(-1.7, 2.7, -12.1),
        worldRuntime.portal.clone(),
      ]),
    [],
  );

  useEffect(() => {
    phaseClock.current = 0;
  }, [phase]);

  useEffect(() => {
    if (impactNonce > 0 && !reducedMotion) shake.current = 1;
  }, [impactNonce, reducedMotion]);

  useEffect(() => {
    if (playerDamageNonce > 0 && !reducedMotion) shake.current = 1.35;
  }, [playerDamageNonce, reducedMotion]);

  useFrame((state, delta) => {
    if (isHitStopped()) return;
    phaseClock.current += delta;
    const raid = useRaidStore.getState();

    if (playerDead) {
      desired.set(worldRuntime.player.x + 5.2, 4.1, worldRuntime.player.z + 6.4);
      target.copy(worldRuntime.player).setY(0.72);
    } else if (phase === "intro") {
      desired.set(8.8, 7.4, 17.5);
      target.set(0, 1.2, 0.8);
    } else if (phase === "hunt") {
      desired.set(worldRuntime.player.x + 7.3, 6.6, worldRuntime.player.z + 8.6);
      target.set(worldRuntime.player.x, 1.05, worldRuntime.player.z - 2.25);
    } else if (phase === "root-reveal") {
      desired.set(worldRuntime.player.x + 6.4, 5.8, worldRuntime.player.z + 7.4);
      target.lerpVectors(worldRuntime.player, weaponPoint, 0.58).setY(1.15);
    } else if (phase === "boss") {
      desired.set(worldRuntime.player.x + 7.8, 7.25, worldRuntime.player.z + 9.8);
      target.lerpVectors(worldRuntime.player, worldRuntime.boss, 0.56).setY(1.65);
    } else if (phase === "loot" || phase === "permission") {
      const drift = reducedMotion ? 0.4 : phaseClock.current * 0.08 + 0.4;
      desired.set(Math.sin(drift) * 8.8, 6.15, Math.cos(drift) * 8.8 - 1.2);
      target.set(0, 1.05, -1.2);
    } else if (phase === "dispatch" || phase === "running") {
      const routeProgress = phase === "dispatch" ? 0 : raid.agentProgress;
      agentCurve.getPointAt(THREE.MathUtils.clamp(routeProgress, 0, 1), agentPoint);
      desired.copy(agentPoint).add(new THREE.Vector3(7.4, 5.6, 8.2));
      target.copy(agentPoint).add(new THREE.Vector3(0, 0.25, -1.5));
    } else {
      const t = reducedMotion ? 1 : Math.min(1, phaseClock.current / 3.1);
      desired.set(THREE.MathUtils.lerp(5.6, 0.5, t), THREE.MathUtils.lerp(6.5, 9.2, t), THREE.MathUtils.lerp(-3.2, 15.5, t));
      target.set(0, THREE.MathUtils.lerp(2.1, 0.65, t), THREE.MathUtils.lerp(-10.8, -7.7, t));
    }

    const cameraRate = reducedMotion
      ? 10
      : playerDead
        ? 3.2
        : phase === "handled"
          ? 2.1
          : 5.8;
    camera.position.lerp(desired, 1 - Math.exp(-delta * cameraRate));
    smoothTarget.lerp(target, 1 - Math.exp(-delta * (reducedMotion ? 12 : 6.5)));

    shake.current = Math.max(0, shake.current - delta * 6.2);
    if (shake.current > 0 && !reducedMotion) {
      const strength = shake.current * 0.12;
      camera.position.addScaledVector(worldRuntime.impactDirection, -strength * 1.1);
      camera.position.x += Math.sin(state.clock.elapsedTime * 83) * strength * 0.35;
      camera.position.y += Math.sin(state.clock.elapsedTime * 61 + 1.4) * strength * 0.52;
    }
    camera.lookAt(smoothTarget);

    if (camera instanceof THREE.PerspectiveCamera) {
      const fovTarget = playerDead ? 41 : phase === "root-reveal" ? 43 : phase === "handled" ? 44 : 46;
      camera.fov = THREE.MathUtils.damp(camera.fov, fovTarget, 3.5, delta);
      camera.updateProjectionMatrix();
    }
  });

  return null;
}

export function InkPostProcessing({ reducedMotion, lowPower }: { reducedMotion: boolean; lowPower: boolean }) {
  return (
    <EffectComposer multisampling={reducedMotion || lowPower ? 0 : 4}>
      <Bloom
        mipmapBlur
        intensity={reducedMotion ? 0.24 : lowPower ? 0.32 : 0.42}
        luminanceThreshold={0.72}
        luminanceSmoothing={0.22}
        radius={0.52}
      />
      <Vignette eskil={false} offset={0.2} darkness={lowPower ? 0.46 : 0.56} />
    </EffectComposer>
  );
}
