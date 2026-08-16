import { Line } from "@react-three/drei";
import { useFrame } from "@react-three/fiber";
import { useEffect, useMemo, useRef } from "react";
import * as THREE from "three";
import { playTone } from "../game/audio";
import { ACTION_STEPS, CAUSAL_WEAPON_POSITION, CONTEXT_SOURCES } from "../game/demo-world";
import type { ActionStepSpec, ContextSourceSpec, Vector3Tuple } from "../game/contracts";
import { useRaidStore } from "../game/store";
import { isHitStopped, registerPlayerImpact, seededRandom, worldRuntime } from "./runtime";

const BOSS_BASE: Vector3Tuple = [0, 0.05, -1.2];
const BOSS_AGGRO_RANGE = 5;
const BOSS_WINDUP_SECONDS = 1.45;
const BOSS_COOLDOWN_SECONDS = 3.4;

type BossAttackMode = "cooldown" | "telegraph" | "release" | "stagger";

function ContextSourceShape({ source }: { source: ContextSourceSpec }) {
  if (source.shape === "watch") {
    return (
      <group>
        <mesh rotation={[Math.PI / 2, 0, 0]} castShadow>
          <torusGeometry args={[0.42, 0.105, 8, 30]} />
          <meshStandardMaterial
            color={source.tint}
            emissive={source.tint}
            emissiveIntensity={1.1}
            metalness={0.48}
            roughness={0.25}
          />
        </mesh>
        <mesh position={[-0.16, 0, -0.08]} scale={[0.16, 0.055, 0.035]}>
          <boxGeometry />
          <meshBasicMaterial color="#f7d889" toneMapped={false} />
        </mesh>
        <mesh position={[0, 0.07, -0.08]} rotation={[0, 0, -0.7]} scale={[0.16, 0.035, 0.035]}>
          <boxGeometry />
          <meshBasicMaterial color="#f7d889" toneMapped={false} />
        </mesh>
        <mesh position={[0.17, -0.01, -0.08]} scale={[0.17, 0.045, 0.035]}>
          <boxGeometry />
          <meshBasicMaterial color="#f7d889" toneMapped={false} />
        </mesh>
      </group>
    );
  }

  if (source.shape === "calendar") {
    const cells = [-0.22, 0, 0.22];
    return (
      <group>
        <mesh scale={[0.72, 0.62, 0.12]} castShadow>
          <boxGeometry />
          <meshStandardMaterial color={source.tint} emissive="#665c49" emissiveIntensity={0.45} roughness={0.54} />
        </mesh>
        {cells.flatMap((x, column) =>
          [-0.18, 0.08, 0.34].map((y, row) => (
            <mesh key={`${column}-${row}`} position={[x, y - 0.08, -0.14]} scale={[0.13, 0.1, 0.025]}>
              <boxGeometry />
              <meshBasicMaterial color={row === 0 && column === 1 ? "#e8b75d" : "#3a3930"} />
            </mesh>
          )),
        )}
        <mesh position={[-0.22, 0.42, 0]}>
          <cylinderGeometry args={[0.035, 0.035, 0.24, 6]} />
          <meshBasicMaterial color="#e5cf9d" />
        </mesh>
        <mesh position={[0.22, 0.42, 0]}>
          <cylinderGeometry args={[0.035, 0.035, 0.24, 6]} />
          <meshBasicMaterial color="#e5cf9d" />
        </mesh>
      </group>
    );
  }

  if (source.shape === "notes") {
    const waveform = [0.12, 0.32, 0.2, 0.48, 0.26, 0.38, 0.15];
    return (
      <group>
        <mesh scale={[0.76, 0.92, 0.1]} castShadow>
          <boxGeometry />
          <meshStandardMaterial color="#d6ccb0" emissive={source.tint} emissiveIntensity={0.38} roughness={0.72} />
        </mesh>
        <mesh position={[0, 0.25, -0.13]} scale={[0.5, 0.035, 0.02]}>
          <boxGeometry />
          <meshBasicMaterial color="#5b3b23" />
        </mesh>
        {waveform.map((height, index) => (
          <mesh
            key={index}
            position={[(index - 3) * 0.105, -0.13, -0.14]}
            scale={[0.05, height, 0.025]}
          >
            <boxGeometry />
            <meshBasicMaterial color={source.tint} toneMapped={false} />
          </mesh>
        ))}
      </group>
    );
  }

  return (
    <group>
      <mesh rotation={[0.25, 0.18, Math.PI / 4]} castShadow>
        <octahedronGeometry args={[0.55, 0]} />
        <meshStandardMaterial
          color={source.tint}
          emissive={source.tint}
          emissiveIntensity={1.25}
          metalness={0.52}
          roughness={0.22}
          flatShading
        />
      </mesh>
      <mesh rotation={[0.25, 0.18, Math.PI / 4]} scale={1.48}>
        <octahedronGeometry args={[0.55, 0]} />
        <meshBasicMaterial color="#f4d487" transparent opacity={0.16} wireframe depthWrite={false} />
      </mesh>
      {[-0.28, 0, 0.28].map((y, index) => (
        <mesh key={y} position={[0, y, -0.6]} scale={[0.42 - index * 0.05, 0.035, 0.03]}>
          <boxGeometry />
          <meshBasicMaterial color="#f5d78a" toneMapped={false} />
        </mesh>
      ))}
    </group>
  );
}

function ContextPickup({ source, index }: { source: ContextSourceSpec; index: number }) {
  const group = useRef<THREE.Group>(null);
  const halo = useRef<THREE.Mesh>(null);
  const spawn = useRef(0);
  const collectionSent = useRef(false);
  const defeated = useRaidStore((state) => state.sourceEnemies[source.id]?.defeated ?? false);
  const collected = useRaidStore((state) => state.collectedSources.includes(source.id));
  const phase = useRaidStore((state) => state.phase);
  const runNonce = useRaidStore((state) => state.runNonce);

  useEffect(() => {
    spawn.current = 0;
    collectionSent.current = false;
  }, [runNonce]);

  useFrame((state, delta) => {
    if (!group.current || !defeated) return;
    const dt = Math.min(delta, 0.05);
    spawn.current = Math.min(1, spawn.current + dt / 0.46);
    const eased = 1 - Math.pow(1 - spawn.current, 3);
    group.current.rotation.y += dt * (0.72 + index * 0.08);
    group.current.position.y =
      source.position[1] +
      0.38 +
      Math.sin(state.clock.elapsedTime * 2.3 + index) * 0.13 +
      Math.sin(spawn.current * Math.PI) * 0.9;
    const targetScale = collected ? 0 : eased;
    group.current.scale.setScalar(
      THREE.MathUtils.damp(group.current.scale.x, targetScale, collected ? 9 : 14, dt),
    );
    if (halo.current) {
      halo.current.rotation.z -= dt * 0.42;
      halo.current.scale.setScalar(1 + Math.sin(state.clock.elapsedTime * 3.5 + index) * 0.07);
    }

    if (
      phase === "hunt" &&
      !collected &&
      !collectionSent.current &&
      spawn.current >= 0.72 &&
      worldRuntime.player.distanceTo(group.current.position) < 1.36
    ) {
      collectionSent.current = true;
      useRaidStore.getState().collectSource(source.id);
    }
  });

  if (!defeated) return null;
  return (
    <group ref={group} position={[source.position[0], source.position[1] + 0.38, source.position[2]]} scale={0.001}>
      <ContextSourceShape source={source} />
      <mesh ref={halo} position={[0, -0.55, 0]} rotation={[-Math.PI / 2, 0, 0]}>
        <ringGeometry args={[0.52, 0.8, 32]} />
        <meshBasicMaterial color={source.tint} transparent opacity={0.34} depthWrite={false} side={THREE.DoubleSide} />
      </mesh>
      <pointLight color={source.tint} intensity={2.1} distance={5} />
    </group>
  );
}

function CausalityBladeForge() {
  const root = useRef<THREE.Group>(null);
  const blade = useRef<THREE.Group>(null);
  const rings = useRef<THREE.Group>(null);
  const equipSent = useRef(false);
  const forged = useRaidStore((state) => state.weaponForged);
  const equipped = useRaidStore((state) => state.weaponEquipped);
  const phase = useRaidStore((state) => state.phase);
  const runNonce = useRaidStore((state) => state.runNonce);
  const weaponPoint = useMemo(() => new THREE.Vector3(...CAUSAL_WEAPON_POSITION), []);

  useEffect(() => {
    equipSent.current = false;
    if (root.current) root.current.scale.setScalar(0.001);
  }, [runNonce]);

  useFrame((state, delta) => {
    if (!root.current || !forged) return;
    const dt = Math.min(delta, 0.05);
    const targetScale = equipped ? 0 : 1;
    root.current.scale.setScalar(
      THREE.MathUtils.damp(root.current.scale.x, targetScale, equipped ? 8 : 3.8, dt),
    );
    root.current.position.y =
      CAUSAL_WEAPON_POSITION[1] + 0.32 + Math.sin(state.clock.elapsedTime * 2.1) * 0.12;
    if (blade.current) blade.current.rotation.y += dt * 0.55;
    if (rings.current) {
      rings.current.rotation.y -= dt * 0.38;
      rings.current.rotation.z += dt * 0.17;
    }

    if (
      phase === "root-reveal" &&
      !equipped &&
      !equipSent.current &&
      worldRuntime.player.distanceTo(weaponPoint) < 1.45
    ) {
      equipSent.current = true;
      useRaidStore.getState().equipWeapon();
    }
  });

  if (!forged) return null;
  return (
    <group ref={root} position={CAUSAL_WEAPON_POSITION} scale={0.001}>
      <group ref={blade} rotation={[0.12, 0, -0.16]}>
        <mesh position={[0, 0.62, 0]} castShadow>
          <boxGeometry args={[0.18, 1.76, 0.07]} />
          <meshStandardMaterial color="#ffe8a0" emissive="#d88923" emissiveIntensity={3.1} metalness={0.72} roughness={0.16} />
        </mesh>
        <mesh position={[0, 1.64, 0]} rotation={[0, 0, Math.PI]} castShadow>
          <coneGeometry args={[0.19, 0.52, 4]} />
          <meshStandardMaterial color="#fff0b0" emissive="#e49a2f" emissiveIntensity={3.4} />
        </mesh>
        <mesh position={[0, -0.42, 0]} castShadow>
          <cylinderGeometry args={[0.075, 0.075, 0.72, 7]} />
          <meshStandardMaterial color="#5b3b1c" roughness={0.68} />
        </mesh>
        <mesh position={[0, -0.04, 0]} rotation={[Math.PI / 2, 0, 0]}>
          <torusGeometry args={[0.31, 0.045, 7, 28]} />
          <meshBasicMaterial color="#ffd77c" toneMapped={false} />
        </mesh>
      </group>
      <group ref={rings}>
        {[0, 1, 2, 3].map((index) => {
          const angle = (index / 4) * Math.PI * 2;
          return (
            <mesh
              key={CONTEXT_SOURCES[index]?.id ?? index}
              position={[Math.cos(angle) * 1.08, (index % 2) * 0.28 + 0.34, Math.sin(angle) * 1.08]}
              rotation={[0.3, angle, Math.PI / 4]}
            >
              <octahedronGeometry args={[0.16, 0]} />
              <meshBasicMaterial color={CONTEXT_SOURCES[index]?.tint ?? "#e2b45f"} toneMapped={false} />
            </mesh>
          );
        })}
      </group>
      <mesh position={[0, -0.63, 0]} rotation={[-Math.PI / 2, 0, 0]}>
        <ringGeometry args={[0.72, 1.18, 52]} />
        <meshBasicMaterial color="#efbd5d" transparent opacity={0.42} depthWrite={false} side={THREE.DoubleSide} />
      </mesh>
      <pointLight color="#f1b64c" intensity={6.2} distance={11} position={[0, 0.8, 0]} />
    </group>
  );
}

/** ContextField is kept under the old export to avoid breaking InkWorld. */
export function EvidenceNetwork() {
  const collectedSources = useRaidStore((state) => state.collectedSources);
  return (
    <group>
      {CONTEXT_SOURCES.map((source, index) => (
        <group key={source.id}>
          <ContextPickup source={source} index={index} />
          {collectedSources.includes(source.id) && (
            <Line
              points={[
                [source.position[0], 0.16, source.position[2]],
                [CAUSAL_WEAPON_POSITION[0], 0.18, CAUSAL_WEAPON_POSITION[2]],
              ]}
              color={source.tint}
              lineWidth={0.82}
              transparent
              opacity={0.36}
              dashed
              dashSize={0.28}
              gapSize={0.2}
            />
          )}
        </group>
      ))}
      <CausalityBladeForge />
    </group>
  );
}

function KnotTendril({ rotation, radius }: { rotation: [number, number, number]; radius: number }) {
  return (
    <mesh rotation={rotation} castShadow>
      <torusKnotGeometry args={[radius, 0.095, 72, 8, 2, 3]} />
      <meshStandardMaterial color="#11130f" roughness={0.76} metalness={0.08} flatShading />
    </mesh>
  );
}

function EvidenceLock({ index, active }: { index: number; active: boolean }) {
  const group = useRef<THREE.Group>(null);
  const burst = useRef(0);
  const wasActive = useRef(true);
  const positions: [number, number, number][] = [
    [-0.72, 2.65, 0.62],
    [0.72, 2.65, 0.62],
    [-0.48, 1.74, 0.83],
    [0.48, 1.74, 0.83],
  ];

  useEffect(() => {
    if (wasActive.current && !active) burst.current = 1;
    wasActive.current = active;
  }, [active]);

  useFrame((state, delta) => {
    if (!group.current || isHitStopped()) return;
    const dt = Math.min(delta, 0.05);
    burst.current = Math.max(0, burst.current - dt * 2.2);
    const target = active ? 1 : burst.current * 1.65;
    const scale = THREE.MathUtils.damp(group.current.scale.x, target, active ? 11 : 5, dt);
    group.current.scale.setScalar(Math.max(0.001, scale));
    group.current.rotation.z = Math.sin(state.clock.elapsedTime * 1.8 + index) * 0.09 + burst.current * 0.7;
    group.current.rotation.y += dt * burst.current * 4;
  });

  return (
    <group ref={group} position={positions[index]}>
      <mesh castShadow rotation={[0, 0, Math.PI / 4]}>
        <octahedronGeometry args={[0.34, 0]} />
        <meshStandardMaterial
          color="#e4b65e"
          emissive="#b66f1f"
          emissiveIntensity={1.25}
          metalness={0.58}
          roughness={0.24}
          flatShading
        />
      </mesh>
      <mesh scale={1.4}>
        <octahedronGeometry args={[0.34, 0]} />
        <meshBasicMaterial color="#f4d98c" transparent opacity={0.14} wireframe depthWrite={false} />
      </mesh>
    </group>
  );
}

export function RootBoss() {
  const boss = useRef<THREE.Group>(null);
  const coreMaterial = useRef<THREE.MeshStandardMaterial>(null);
  const shield = useRef<THREE.Mesh>(null);
  const shieldMaterial = useRef<THREE.MeshBasicMaterial>(null);
  const warningRing = useRef<THREE.Mesh>(null);
  const warningMaterial = useRef<THREE.MeshBasicMaterial>(null);
  const phaseBreakRing = useRef<THREE.Mesh>(null);
  const phaseBreakMaterial = useRef<THREE.MeshBasicMaterial>(null);
  const reveal = useRef(0);
  const hitImpulse = useRef(0);
  const shieldPulse = useRef(0);
  const phaseBreak = useRef(0);
  const defeatVacuum = useRef(0);
  const attackMode = useRef<BossAttackMode>("cooldown");
  const attackClock = useRef(0);
  const attackCooldown = useRef(1.15);
  const previousLocks = useRef(4);
  const previousBlockedNonce = useRef(0);
  const phase = useRaidStore((state) => state.phase);
  const bossLocks = useRaidStore((state) => state.bossLocks);
  const bossBlockedNonce = useRaidStore((state) => state.bossBlockedNonce);
  const weaponEquipped = useRaidStore((state) => state.weaponEquipped);
  const playerDead = useRaidStore((state) => state.playerDead);
  const runNonce = useRaidStore((state) => state.runNonce);

  useEffect(() => {
    reveal.current = 0;
    hitImpulse.current = 0;
    shieldPulse.current = 0;
    phaseBreak.current = 0;
    defeatVacuum.current = 0;
    attackMode.current = "cooldown";
    attackClock.current = 0;
    attackCooldown.current = 1.15;
    previousLocks.current = useRaidStore.getState().bossLocks;
    previousBlockedNonce.current = useRaidStore.getState().bossBlockedNonce;
    if (warningRing.current) warningRing.current.visible = false;
  }, [runNonce]);

  useEffect(() => {
    if (bossLocks < previousLocks.current) {
      hitImpulse.current = 1;
      attackMode.current = "stagger";
      attackClock.current = 0;
      attackCooldown.current = 1.2;
      if (warningRing.current) warningRing.current.visible = false;
      if (bossLocks === 2) {
        phaseBreak.current = 1;
        const away = worldRuntime.player.clone().sub(worldRuntime.boss).setY(0);
        if (away.lengthSq() > 0.01) worldRuntime.player.addScaledVector(away.normalize(), 1.15);
      }
      if (bossLocks === 0) defeatVacuum.current = 0.001;
    }
    previousLocks.current = bossLocks;
  }, [bossLocks]);

  useEffect(() => {
    if (bossBlockedNonce > previousBlockedNonce.current) {
      shieldPulse.current = 1;
      const away = worldRuntime.player.clone().sub(worldRuntime.boss).setY(0);
      if (away.lengthSq() > 0.01) worldRuntime.player.addScaledVector(away.normalize(), 0.72);
    }
    previousBlockedNonce.current = bossBlockedNonce;
  }, [bossBlockedNonce]);

  useFrame((state, delta) => {
    if (!boss.current || isHitStopped()) return;
    const dt = Math.min(delta, 0.05);
    const raid = useRaidStore.getState();
    const time = state.clock.elapsedTime;
    const activeCombat = (phase === "hunt" || phase === "boss") && bossLocks > 0 && !playerDead;
    const distance = Math.hypot(
      worldRuntime.player.x - worldRuntime.boss.x,
      worldRuntime.player.z - worldRuntime.boss.z,
    );

    if (!activeCombat) {
      if (attackMode.current === "telegraph" || attackMode.current === "release") {
        attackMode.current = "cooldown";
        attackCooldown.current = 1;
      }
    } else if (attackMode.current === "cooldown") {
      attackCooldown.current = Math.max(0, attackCooldown.current - dt);
      if (attackCooldown.current <= 0 && distance <= BOSS_AGGRO_RANGE && phaseBreak.current <= 0.02) {
        attackMode.current = "telegraph";
        attackClock.current = 0;
      }
    } else if (attackMode.current === "telegraph") {
      attackClock.current += dt;
      if (attackClock.current >= BOSS_WINDUP_SECONDS) {
        const direction = new THREE.Vector3(
          worldRuntime.player.x - worldRuntime.boss.x,
          0,
          worldRuntime.player.z - worldRuntime.boss.z,
        );
        const currentDistance = direction.length();
        if (currentDistance <= BOSS_AGGRO_RANGE + 0.15) {
          direction.normalize();
          const landed = raid.takePlayerHit({ kind: "boss" });
          if (landed) {
            registerPlayerImpact(direction, weaponEquipped ? 44 : 58);
            worldRuntime.player.addScaledVector(direction, weaponEquipped ? 0.68 : 1.35);
          }
        }
        attackMode.current = "release";
        attackClock.current = 0;
      }
    } else if (attackMode.current === "release") {
      attackClock.current += dt;
      if (attackClock.current >= 0.3) {
        attackMode.current = "cooldown";
        attackCooldown.current = BOSS_COOLDOWN_SECONDS;
        attackClock.current = 0;
      }
    } else {
      attackClock.current += dt;
      if (attackClock.current >= 0.7) {
        attackMode.current = "cooldown";
        attackCooldown.current = 1.2;
        attackClock.current = 0;
      }
    }

    hitImpulse.current = Math.max(0, hitImpulse.current - dt * 3.3);
    shieldPulse.current = Math.max(0, shieldPulse.current - dt * 2.7);
    phaseBreak.current = Math.max(0, phaseBreak.current - dt / 1.05);
    if (defeatVacuum.current > 0) {
      defeatVacuum.current = Math.min(1, defeatVacuum.current + dt / 0.36);
    }
    const target = phase === "hunt" || phase === "root-reveal" || phase === "boss" ? 1 : 0;
    reveal.current = THREE.MathUtils.damp(reveal.current, target, phase === "loot" ? 3.8 : 2.15, dt);
    const eased = reveal.current * reveal.current * (3 - 2 * reveal.current);
    const telegraph =
      attackMode.current === "telegraph"
        ? THREE.MathUtils.clamp(attackClock.current / BOSS_WINDUP_SECONDS, 0, 1)
        : 0;
    const release =
      attackMode.current === "release" ? 1 - THREE.MathUtils.clamp(attackClock.current / 0.3, 0, 1) : 0;
    const attackCharge = 1 + Math.sin(telegraph * Math.PI) * 0.075;
    const vacuumScale = defeatVacuum.current > 0 ? 1 - defeatVacuum.current * 0.42 : 1;

    boss.current.position.y = -4.8 + eased * 4.85 - telegraph * 0.15;
    boss.current.position.x = Math.sin(time * 58) * hitImpulse.current * 0.24;
    boss.current.position.z = BOSS_BASE[2] + Math.cos(time * 47) * hitImpulse.current * 0.12;
    boss.current.scale.setScalar(
      Math.max(
        0.001,
        eased *
          (phase === "loot" ? 0.78 : 1) *
          (1 + hitImpulse.current * 0.07) *
          vacuumScale *
          attackCharge,
      ),
    );
    boss.current.rotation.y = Math.sin(time * 0.23) * 0.12 + hitImpulse.current * 0.12;
    boss.current.rotation.z = Math.sin(time * 41) * hitImpulse.current * 0.045;

    if (coreMaterial.current) {
      coreMaterial.current.emissive.set(weaponEquipped ? "#8b5117" : "#69210f");
      coreMaterial.current.emissiveIntensity =
        0.12 +
        Math.sin(time * 2.3) * 0.05 +
        (4 - bossLocks) * 0.13 +
        hitImpulse.current * 1.8 +
        defeatVacuum.current * 4.2 +
        telegraph * (2.2 + Math.sin(time * 16) * 0.55);
    }
    if (shield.current && shieldMaterial.current) {
      const shieldActive = !weaponEquipped && bossLocks > 0 && phase !== "loot";
      shield.current.visible = shieldActive;
      shield.current.scale.setScalar(1 + shieldPulse.current * 0.22 + Math.sin(time * 1.8) * 0.018);
      shieldMaterial.current.opacity = shieldActive ? 0.1 + shieldPulse.current * 0.48 : 0;
    }
    if (warningRing.current && warningMaterial.current) {
      const active = telegraph > 0 || release > 0;
      warningRing.current.visible = active;
      warningRing.current.scale.setScalar(
        telegraph > 0 ? 0.9 + telegraph * (BOSS_AGGRO_RANGE - 0.9) : BOSS_AGGRO_RANGE + (1 - release) * 2.2,
      );
      warningMaterial.current.opacity =
        telegraph > 0
          ? 0.18 + telegraph * 0.62 + Math.sin(time * 20) * telegraph * 0.08
          : release * 0.82;
    }
    if (phaseBreakRing.current && phaseBreakMaterial.current) {
      const progress = 1 - phaseBreak.current;
      phaseBreakRing.current.visible = phaseBreak.current > 0;
      phaseBreakRing.current.scale.setScalar(0.8 + progress * 7.5);
      phaseBreakMaterial.current.opacity = phaseBreak.current * 0.66;
    }
  });

  return (
    <group ref={boss} position={BOSS_BASE} scale={0.001}>
      <mesh position={[0, 2.1, 0]} scale={[1.65, 2.2, 1.15]} castShadow>
        <icosahedronGeometry args={[1, 1]} />
        <meshStandardMaterial
          ref={coreMaterial}
          color="#141510"
          emissive="#69210f"
          emissiveIntensity={0.12}
          roughness={0.72}
          metalness={0.12}
          flatShading
        />
      </mesh>
      <mesh position={[0, 4.45, 0]} scale={[0.9, 0.76, 0.7]} castShadow>
        <dodecahedronGeometry args={[1, 0]} />
        <meshStandardMaterial color="#0a0c09" roughness={0.88} flatShading />
      </mesh>
      <mesh position={[0, 4.34, 0.65]} rotation={[Math.PI / 2, 0, 0]}>
        <torusGeometry args={[0.5, 0.095, 7, 28, Math.PI * 1.72]} />
        <meshStandardMaterial color="#bb7d35" emissive="#6e320d" emissiveIntensity={0.72} />
      </mesh>
      <group position={[0, 2.35, 0]}>
        <KnotTendril rotation={[0.2, 0.1, 0.7]} radius={0.73} />
        <KnotTendril rotation={[-0.4, 0.6, -0.55]} radius={0.66} />
        <KnotTendril rotation={[0.7, -0.2, 0.2]} radius={0.58} />
      </group>
      <mesh position={[-1.35, 1.05, 0]} rotation={[0, 0, -0.15]} castShadow>
        <coneGeometry args={[0.52, 2.4, 6]} />
        <meshStandardMaterial color="#0c0e0b" roughness={0.95} flatShading />
      </mesh>
      <mesh position={[1.35, 1.05, 0]} rotation={[0, 0, 0.15]} castShadow>
        <coneGeometry args={[0.52, 2.4, 6]} />
        <meshStandardMaterial color="#0c0e0b" roughness={0.95} flatShading />
      </mesh>
      {[0, 1, 2, 3].map((index) => (
        <EvidenceLock key={index} index={index} active={index < bossLocks} />
      ))}
      <mesh ref={shield} visible={false} position={[0, 2.15, 0]} scale={[2.2, 2.85, 1.75]}>
        <icosahedronGeometry args={[1, 2]} />
        <meshBasicMaterial
          ref={shieldMaterial}
          color="#e1a246"
          transparent
          opacity={0.1}
          wireframe
          depthWrite={false}
        />
      </mesh>
      {/* Rust-red boss attack tell: deliberately separate from the gold phase-break ring. */}
      <mesh ref={warningRing} visible={false} position={[0, 0.08, 0]} rotation={[-Math.PI / 2, 0, 0]}>
        <ringGeometry args={[0.86, 1, 56]} />
        <meshBasicMaterial
          ref={warningMaterial}
          color="#c64f32"
          transparent
          opacity={0}
          depthWrite={false}
          side={THREE.DoubleSide}
        />
      </mesh>
      <mesh ref={phaseBreakRing} visible={false} position={[0, 0.1, 0]} rotation={[-Math.PI / 2, 0, 0]}>
        <ringGeometry args={[0.72, 0.84, 48]} />
        <meshBasicMaterial
          ref={phaseBreakMaterial}
          color="#e5b456"
          transparent
          opacity={0}
          depthWrite={false}
          side={THREE.DoubleSide}
        />
      </mesh>
      <pointLight
        color={weaponEquipped ? "#d49b40" : "#b94c2c"}
        intensity={2.8 + (4 - bossLocks) * 0.7}
        distance={10}
        position={[0, 2.5, 1]}
      />
    </group>
  );
}

function ActionStepShape({ index, step }: { index: number; step: ActionStepSpec }) {
  const material = (
    <meshStandardMaterial
      color={step.tint}
      emissive={step.tint}
      emissiveIntensity={0.86}
      metalness={0.42}
      roughness={0.28}
      flatShading
    />
  );
  if (index === 0) {
    return (
      <mesh castShadow>
        <icosahedronGeometry args={[0.46, 1]} />
        {material}
      </mesh>
    );
  }
  if (index === 1) {
    return (
      <group>
        {[-0.22, 0, 0.22].map((y, layer) => (
          <mesh key={y} position={[(layer - 1) * 0.06, y, 0]} rotation={[0, layer * 0.2, 0]} castShadow>
            <boxGeometry args={[0.8, 0.12, 0.5]} />
            {material}
          </mesh>
        ))}
      </group>
    );
  }
  return (
    <group>
      <mesh castShadow rotation={[Math.PI / 2, 0, 0]}>
        <torusGeometry args={[0.43, 0.1, 8, 30]} />
        {material}
      </mesh>
      <mesh position={[0.19, -0.04, 0]} rotation={[0, 0, -0.55]}>
        <boxGeometry args={[0.08, 0.52, 0.08]} />
        {material}
      </mesh>
    </group>
  );
}

function ActionStepItem({ step, index, position }: { step: ActionStepSpec; index: number; position: Vector3Tuple }) {
  const group = useRef<THREE.Group>(null);
  const spawn = useRef(0);
  const collectionSent = useRef(false);
  const collected = useRaidStore((state) => state.collectedSteps.includes(step.id));
  const phase = useRaidStore((state) => state.phase);
  const runNonce = useRaidStore((state) => state.runNonce);

  useEffect(() => {
    spawn.current = 0;
    collectionSent.current = false;
  }, [runNonce]);

  useFrame((state, delta) => {
    if (!group.current) return;
    const dt = Math.min(delta, 0.05);
    spawn.current = Math.min(1, spawn.current + dt / (0.62 + index * 0.08));
    const launch = 1 - Math.pow(1 - spawn.current, 3);
    group.current.rotation.y += dt * (0.58 + index * 0.09);
    group.current.position.x = THREE.MathUtils.lerp(0, position[0], launch);
    group.current.position.z = THREE.MathUtils.lerp(BOSS_BASE[2], position[2], launch);
    group.current.position.y =
      spawn.current < 1
        ? THREE.MathUtils.lerp(2.3, position[1], launch) + Math.sin(spawn.current * Math.PI) * (1.35 + index * 0.12)
        : position[1] + Math.sin(state.clock.elapsedTime * 2.1 + index) * 0.17;
    const targetScale = collected ? 0 : 1;
    const bounce = spawn.current < 1 ? 1 + Math.sin(spawn.current * Math.PI) * 0.25 : 1;
    group.current.scale.setScalar(
      Math.max(0.001, THREE.MathUtils.damp(group.current.scale.x, targetScale * bounce, collected ? 9 : 12, dt)),
    );

    if (
      phase === "loot" &&
      !collected &&
      !collectionSent.current &&
      spawn.current >= 1 &&
      worldRuntime.player.distanceTo(group.current.position) < 1.35
    ) {
      collectionSent.current = true;
      useRaidStore.getState().collectStep(step.id);
      playTone("loot", useRaidStore.getState().audioEnabled);
    }
  });

  return (
    <group ref={group} position={[0, 2.3, BOSS_BASE[2]]} scale={0.001}>
      <ActionStepShape index={index} step={step} />
      <mesh rotation={[-Math.PI / 2, 0, 0]} position={[0, -0.48, 0]}>
        <ringGeometry args={[0.48, 0.76, 34]} />
        <meshBasicMaterial color={step.tint} transparent opacity={0.34} depthWrite={false} side={THREE.DoubleSide} />
      </mesh>
      <pointLight color={step.tint} intensity={2.4} distance={5.2} />
    </group>
  );
}

function ActionBurst() {
  const points = useRef<THREE.Points>(null);
  const material = useRef<THREE.PointsMaterial>(null);
  const ring = useRef<THREE.Mesh>(null);
  const ringMaterial = useRef<THREE.MeshBasicMaterial>(null);
  const age = useRef(0);
  const particleData = useMemo(() => {
    const random = seededRandom(77221);
    const velocities = new Float32Array(48 * 3);
    const positions = new Float32Array(48 * 3);
    for (let index = 0; index < 48; index += 1) {
      const angle = random() * Math.PI * 2;
      const speed = 2.5 + random() * 5.1;
      velocities[index * 3] = Math.cos(angle) * speed;
      velocities[index * 3 + 1] = 2.2 + random() * 4.2;
      velocities[index * 3 + 2] = Math.sin(angle) * speed;
      positions[index * 3 + 1] = 2.1;
      positions[index * 3 + 2] = BOSS_BASE[2];
    }
    return { positions, velocities };
  }, []);

  useFrame((_, delta) => {
    age.current = Math.min(1.4, age.current + Math.min(delta, 0.05));
    const attribute = points.current?.geometry.getAttribute("position") as THREE.BufferAttribute | undefined;
    if (attribute) {
      const t = age.current;
      for (let index = 0; index < 48; index += 1) {
        attribute.array[index * 3] = particleData.velocities[index * 3] * t;
        attribute.array[index * 3 + 1] = 2.1 + particleData.velocities[index * 3 + 1] * t - 5.4 * t * t;
        attribute.array[index * 3 + 2] = BOSS_BASE[2] + particleData.velocities[index * 3 + 2] * t;
      }
      attribute.needsUpdate = true;
    }
    if (material.current) material.current.opacity = Math.max(0, 1 - age.current / 1.15) * 0.92;
    if (ring.current && ringMaterial.current) {
      ring.current.scale.setScalar(0.5 + age.current * 8.5);
      ringMaterial.current.opacity = Math.max(0, 1 - age.current / 0.72) * 0.8;
    }
  });

  return (
    <group>
      <points ref={points}>
        <bufferGeometry>
          <bufferAttribute attach="attributes-position" args={[particleData.positions, 3]} />
        </bufferGeometry>
        <pointsMaterial
          ref={material}
          color="#f1c66f"
          size={0.11}
          sizeAttenuation
          transparent
          opacity={0.92}
          depthWrite={false}
          blending={THREE.AdditiveBlending}
        />
      </points>
      <mesh ref={ring} position={[0, 0.1, BOSS_BASE[2]]} rotation={[-Math.PI / 2, 0, 0]}>
        <ringGeometry args={[0.45, 0.62, 48]} />
        <meshBasicMaterial
          ref={ringMaterial}
          color="#f2c56a"
          transparent
          opacity={0.8}
          depthWrite={false}
          side={THREE.DoubleSide}
        />
      </mesh>
    </group>
  );
}

/** ACTION_STEPS are kept under the old export name for integration stability. */
export function LootField() {
  const phase = useRaidStore((state) => state.phase);
  const positions = useMemo<Vector3Tuple[]>(
    () =>
      ACTION_STEPS.map((_, index) => {
        const angle = -Math.PI / 2 + (index / ACTION_STEPS.length) * Math.PI * 2;
        return [Math.cos(angle) * 2.45, 0.88, BOSS_BASE[2] + Math.sin(angle) * 2.45];
      }),
    [],
  );
  if (phase !== "loot") return null;
  return (
    <group>
      <ActionBurst />
      {ACTION_STEPS.map((step, index) => (
        <ActionStepItem key={step.id} step={step} index={index} position={positions[index]} />
      ))}
    </group>
  );
}

function PaperAgent({ progress, visible }: { progress: number; visible: boolean }) {
  const group = useRef<THREE.Group>(null);
  const wingLeft = useRef<THREE.Mesh>(null);
  const wingRight = useRef<THREE.Mesh>(null);
  const smoothProgress = useRef(progress);
  const curve = useMemo(
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
  const tangent = useMemo(() => new THREE.Vector3(), []);
  const point = useMemo(() => new THREE.Vector3(), []);

  useEffect(() => {
    if (!visible || progress === 0) smoothProgress.current = progress;
  }, [progress, visible]);

  useFrame((state, delta) => {
    if (!group.current || !visible) return;
    const dt = Math.min(delta, 0.05);
    smoothProgress.current = THREE.MathUtils.damp(smoothProgress.current, progress, 13, dt);
    curve.getPointAt(THREE.MathUtils.clamp(smoothProgress.current, 0, 1), point);
    curve.getTangentAt(THREE.MathUtils.clamp(smoothProgress.current, 0, 1), tangent);
    group.current.position.lerp(point, 1 - Math.exp(-dt * 12));
    group.current.lookAt(point.clone().add(tangent));
    group.current.rotation.z = Math.sin(state.clock.elapsedTime * 6.5) * 0.13;
    const flap = Math.sin(state.clock.elapsedTime * 12) * 0.55;
    if (wingLeft.current) wingLeft.current.rotation.z = 0.42 + flap;
    if (wingRight.current) wingRight.current.rotation.z = -0.42 - flap;
  });

  if (!visible) return null;
  return (
    <group ref={group} position={[0, 1.25, -1.2]} scale={0.62}>
      <mesh rotation={[Math.PI / 2, 0, 0]} castShadow>
        <coneGeometry args={[0.34, 1.05, 4]} />
        <meshStandardMaterial color="#e9dfbd" emissive="#c18a35" emissiveIntensity={0.62} roughness={0.68} flatShading />
      </mesh>
      <mesh ref={wingLeft} position={[-0.35, 0, 0]} rotation={[0, 0, 0.42]}>
        <planeGeometry args={[0.82, 0.56]} />
        <meshStandardMaterial color="#d8cba6" side={THREE.DoubleSide} roughness={0.8} />
      </mesh>
      <mesh ref={wingRight} position={[0.35, 0, 0]} rotation={[0, 0, -0.42]}>
        <planeGeometry args={[0.82, 0.56]} />
        <meshStandardMaterial color="#d8cba6" side={THREE.DoubleSide} roughness={0.8} />
      </mesh>
      <pointLight color="#e0ad58" intensity={2.5} distance={5} />
    </group>
  );
}

function ArtifactReturn({ visible, reducedMotion }: { visible: boolean; reducedMotion: boolean }) {
  const group = useRef<THREE.Group>(null);
  const elapsed = useRef(0);
  const returnCurve = useMemo(
    () =>
      new THREE.CatmullRomCurve3([
        worldRuntime.portal.clone(),
        new THREE.Vector3(4.8, 6.8, -13.5),
        new THREE.Vector3(-3.2, 5.2, -9.4),
        worldRuntime.bridge.clone().add(new THREE.Vector3(0, 1.45, 0)),
      ]),
    [],
  );
  const point = useMemo(() => new THREE.Vector3(), []);

  useEffect(() => {
    if (visible) elapsed.current = 0;
  }, [visible]);

  useFrame((state, delta) => {
    if (!visible || !group.current) return;
    const dt = Math.min(delta, 0.05);
    elapsed.current = Math.min(1, elapsed.current + dt / (reducedMotion ? 0.7 : 2.7));
    const t = 1 - Math.pow(1 - elapsed.current, 3);
    returnCurve.getPointAt(t, point);
    group.current.position.copy(point);
    group.current.rotation.x += dt * 0.8;
    group.current.rotation.y += dt * 1.5;
    group.current.scale.setScalar(0.7 + Math.sin(state.clock.elapsedTime * 4) * 0.05);
  });

  if (!visible) return null;
  return (
    <group ref={group} position={worldRuntime.portal.toArray()}>
      <mesh castShadow>
        <boxGeometry args={[0.82, 1.05, 0.12]} />
        <meshStandardMaterial color="#f1e4b9" emissive="#d8902e" emissiveIntensity={1.6} roughness={0.45} />
      </mesh>
      <mesh position={[0, 0, 0.08]} rotation={[0, 0, Math.PI / 4]}>
        <torusGeometry args={[0.22, 0.035, 6, 20]} />
        <meshBasicMaterial color="#33210d" />
      </mesh>
      <pointLight color="#f0b74f" intensity={5} distance={9} />
    </group>
  );
}

function ExecutionPortal({ active }: { active: boolean }) {
  const group = useRef<THREE.Group>(null);
  const randomShards = useMemo(() => {
    const random = seededRandom(2468);
    return Array.from({ length: 12 }, () => ({
      angle: random() * Math.PI * 2,
      radius: 0.9 + random() * 1.1,
      y: (random() - 0.5) * 2.2,
      size: 0.08 + random() * 0.15,
    }));
  }, []);

  useFrame((state, delta) => {
    if (!group.current || !active) return;
    const dt = Math.min(delta, 0.05);
    group.current.rotation.y += dt * 0.24;
    group.current.scale.setScalar(1 + Math.sin(state.clock.elapsedTime * 2.4) * 0.035);
  });

  if (!active) return null;
  return (
    <group ref={group} position={worldRuntime.portal.toArray()}>
      <mesh>
        <ringGeometry args={[0.95, 1.12, 7]} />
        <meshStandardMaterial color="#14140f" emissive="#9d5f1d" emissiveIntensity={0.74} side={THREE.DoubleSide} />
      </mesh>
      <mesh position={[0, 0, -0.05]}>
        <circleGeometry args={[0.94, 40]} />
        <meshBasicMaterial color="#d09034" transparent opacity={0.09} side={THREE.DoubleSide} depthWrite={false} />
      </mesh>
      {randomShards.map((shard, index) => (
        <mesh
          key={index}
          position={[Math.cos(shard.angle) * shard.radius, shard.y, Math.sin(shard.angle) * 0.22]}
          rotation={[0, 0, shard.angle]}
        >
          <tetrahedronGeometry args={[shard.size, 0]} />
          <meshBasicMaterial color="#c9984d" transparent opacity={0.58} />
        </mesh>
      ))}
      <pointLight color="#d39436" intensity={4.5} distance={10} />
    </group>
  );
}

export function AgentJourney({ reducedMotion }: { reducedMotion: boolean }) {
  const phase = useRaidStore((state) => state.phase);
  const storedProgress = useRaidStore((state) => state.agentProgress);
  const route = useMemo(
    () =>
      [
        [0, 1.25, -1.2],
        [-3.1, 3.1, -4.2],
        [2.4, 4.25, -8.2],
        [-1.7, 2.7, -12.1],
        [0, 3.2, -16],
      ] as Vector3Tuple[],
    [],
  );
  const routeVisible = phase === "dispatch" || phase === "running" || phase === "handled";

  return (
    <group>
      {routeVisible && (
        <Line
          points={route}
          color="#d6a14b"
          lineWidth={1.2}
          transparent
          opacity={phase === "handled" ? 0.22 : 0.62}
          dashed
          dashSize={0.34}
          gapSize={0.19}
        />
      )}
      <ExecutionPortal active={routeVisible} />
      <PaperAgent progress={storedProgress} visible={phase === "dispatch" || phase === "running"} />
      <ArtifactReturn visible={phase === "handled"} reducedMotion={reducedMotion} />
    </group>
  );
}
