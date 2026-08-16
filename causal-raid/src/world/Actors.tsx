import { useFrame } from "@react-three/fiber";
import { useEffect, useMemo, useRef } from "react";
import * as THREE from "three";
import { CAUSAL_WEAPON_POSITION, CONTEXT_SOURCES } from "../game/demo-world";
import type { ContextSourceSpec } from "../game/contracts";
import { useRaidStore } from "../game/store";
import { isHitStopped, registerImpact, registerPlayerImpact, worldRuntime } from "./runtime";

const PLAYER_MIN_X = -11.8;
const PLAYER_MAX_X = 11.8;
const PLAYER_MIN_Z = -13.9;
const PLAYER_MAX_Z = 12.6;
const PLAYER_STRIKE_CONTACT_SECONDS = 0.125;
const PLAYER_STRIKE_RECOVERY_SECONDS = 0.27;
const SOURCE_AGGRO_RANGE = 6;
const SOURCE_WINDUP_SECONDS = 1.2;
const SOURCE_COOLDOWN_SECONDS = 3.3;

type EnemyAttackMode = "cooldown" | "telegraph" | "release" | "stagger";

function HatBrim() {
  return (
    <group position={[0, 1.58, 0]}>
      <mesh castShadow>
        <cylinderGeometry args={[0.62, 0.78, 0.08, 20]} />
        <meshStandardMaterial color="#10110e" roughness={0.82} />
      </mesh>
      <mesh position={[0, 0.24, 0]} castShadow>
        <coneGeometry args={[0.46, 0.58, 20]} />
        <meshStandardMaterial color="#191813" roughness={0.88} />
      </mesh>
    </group>
  );
}

function PlayerModel({ attack }: { attack: React.MutableRefObject<number> }) {
  const model = useRef<THREE.Group>(null);
  const sword = useRef<THREE.Group>(null);
  const slash = useRef<THREE.Mesh>(null);
  const slashMaterial = useRef<THREE.MeshBasicMaterial>(null);
  const coatMaterial = useRef<THREE.MeshStandardMaterial>(null);
  const bladeMaterial = useRef<THREE.MeshStandardMaterial>(null);
  const bladeLight = useRef<THREE.PointLight>(null);
  const hurt = useRef(0);
  const death = useRef(0);
  const playerDamageNonce = useRaidStore((state) => state.playerDamageNonce);
  const playerDead = useRaidStore((state) => state.playerDead);
  const runNonce = useRaidStore((state) => state.runNonce);
  const weaponEquipped = useRaidStore((state) => state.weaponEquipped);

  useEffect(() => {
    if (playerDamageNonce > 0) hurt.current = 1;
  }, [playerDamageNonce]);

  useEffect(() => {
    hurt.current = 0;
    death.current = 0;
    if (!model.current) return;
    model.current.position.set(0, 0, 0);
    model.current.rotation.set(0, 0, 0);
    model.current.scale.setScalar(1);
  }, [runNonce]);

  useFrame((state, delta) => {
    if (!model.current || isHitStopped()) return;
    const dt = Math.min(delta, 0.05);
    const controls = useRaidStore.getState().controls;
    const moving = !playerDead && (controls.forward || controls.backward || controls.left || controls.right);
    const bob = moving
      ? Math.sin(state.clock.elapsedTime * 11) * 0.055
      : Math.sin(state.clock.elapsedTime * 2.2) * 0.022;

    hurt.current = Math.max(0, hurt.current - dt * 4.8);
    death.current = THREE.MathUtils.damp(
      death.current,
      playerDead ? 1 : 0,
      playerDead ? 4.6 : 13,
      dt,
    );
    const recoil = Math.sin(hurt.current * Math.PI) * hurt.current;
    model.current.position.y = bob - death.current * 0.34 + recoil * 0.08;
    model.current.position.z = recoil * 0.2;
    model.current.rotation.x = -recoil * 0.16;
    model.current.rotation.z =
      -death.current * 1.34 + Math.sin(state.clock.elapsedTime * 36) * hurt.current * 0.055;
    model.current.scale.setScalar(1 - death.current * 0.08);

    if (playerDead) attack.current = 0;
    else attack.current = Math.max(0, attack.current - dt * 3.8);
    const strike = Math.sin((1 - attack.current) * Math.PI);
    if (sword.current) {
      sword.current.rotation.z = -0.35 - strike * 2.1;
      sword.current.rotation.x = 0.28 + strike * 0.7;
      const causalPulse = weaponEquipped ? 1 + Math.sin(state.clock.elapsedTime * 5.5) * 0.035 : 1;
      sword.current.scale.setScalar(causalPulse);
    }
    if (slash.current && slashMaterial.current) {
      slash.current.visible = !playerDead && attack.current > 0.08;
      slash.current.scale.setScalar((0.75 + strike * 0.85) * (weaponEquipped ? 1.2 : 1));
      slash.current.rotation.z = -0.8 + strike * 1.4;
      slashMaterial.current.color.set(weaponEquipped ? "#fff0a6" : "#d6b56d");
      slashMaterial.current.opacity = Math.max(0, attack.current * (weaponEquipped ? 0.92 : 0.5));
    }
    if (coatMaterial.current) {
      coatMaterial.current.emissive.set("#7e2d18");
      coatMaterial.current.emissiveIntensity = hurt.current * 1.35;
    }
    if (bladeMaterial.current) {
      bladeMaterial.current.color.set(weaponEquipped ? "#ffe493" : "#8d8879");
      bladeMaterial.current.emissive.set(weaponEquipped ? "#d38b28" : "#2b2922");
      bladeMaterial.current.emissiveIntensity = weaponEquipped ? 2.5 + strike * 1.4 : 0.18;
      bladeMaterial.current.metalness = weaponEquipped ? 0.7 : 0.35;
    }
    if (bladeLight.current) {
      bladeLight.current.intensity = weaponEquipped ? 2.6 + strike * 2.2 : 0.25;
    }
  });

  return (
    <group ref={model}>
      <mesh position={[0, 0.8, 0]} castShadow>
        <coneGeometry args={[0.55, 1.6, 9]} />
        <meshStandardMaterial ref={coatMaterial} color="#171917" roughness={0.94} flatShading />
      </mesh>
      <mesh position={[0, 1.35, 0]} castShadow>
        <sphereGeometry args={[0.25, 14, 10]} />
        <meshStandardMaterial color="#b59d77" roughness={0.9} />
      </mesh>
      <mesh position={[0, 1.15, 0.1]} scale={[0.6, 0.7, 0.35]} castShadow>
        <dodecahedronGeometry args={[0.78, 0]} />
        <meshStandardMaterial color="#24241d" roughness={0.86} flatShading />
      </mesh>
      <HatBrim />

      {/* 牛马打工人的角、长耳、领带与工牌，保持为原生水墨几何。 */}
      <group>
        <mesh position={[-0.27, 1.57, -0.01]} rotation={[0.1, 0, 0.64]} castShadow>
          <coneGeometry args={[0.085, 0.38, 6]} />
          <meshStandardMaterial color="#b7a071" roughness={0.78} flatShading />
        </mesh>
        <mesh position={[0.27, 1.57, -0.01]} rotation={[0.1, 0, -0.64]} castShadow>
          <coneGeometry args={[0.085, 0.38, 6]} />
          <meshStandardMaterial color="#b7a071" roughness={0.78} flatShading />
        </mesh>
        <mesh position={[-0.17, 1.66, 0.06]} rotation={[0.18, 0, 0.28]} scale={[0.7, 1, 0.45]}>
          <coneGeometry args={[0.12, 0.42, 5]} />
          <meshStandardMaterial color="#29271f" roughness={0.95} flatShading />
        </mesh>
        <mesh position={[0.17, 1.66, 0.06]} rotation={[0.18, 0, -0.28]} scale={[0.7, 1, 0.45]}>
          <coneGeometry args={[0.12, 0.42, 5]} />
          <meshStandardMaterial color="#29271f" roughness={0.95} flatShading />
        </mesh>
        <mesh position={[0, 0.98, -0.5]} rotation={[0, 0, Math.PI]} castShadow>
          <coneGeometry args={[0.085, 0.58, 4]} />
          <meshStandardMaterial color="#7b321f" emissive="#42150c" emissiveIntensity={0.18} roughness={0.82} />
        </mesh>
        <mesh position={[0.25, 1.08, -0.49]} castShadow>
          <boxGeometry args={[0.3, 0.21, 0.035]} />
          <meshStandardMaterial color="#c7bea4" roughness={0.7} />
        </mesh>
        <mesh position={[0.25, 1.12, -0.512]}>
          <boxGeometry args={[0.22, 0.028, 0.009]} />
          <meshBasicMaterial color="#9b6a2e" />
        </mesh>
      </group>

      <group ref={sword} position={[0.42, 1.03, -0.08]} rotation={[0.28, 0.12, -0.35]}>
        <mesh position={[0, -0.02, 0]} castShadow>
          <cylinderGeometry args={[0.055, 0.055, 0.43, 7]} />
          <meshStandardMaterial color="#6c4b26" roughness={0.7} />
        </mesh>
        <mesh position={[0, weaponEquipped ? 0.84 : 0.63, 0]} castShadow>
          <boxGeometry args={[weaponEquipped ? 0.12 : 0.075, weaponEquipped ? 1.46 : 1.02, 0.045]} />
          <meshStandardMaterial
            ref={bladeMaterial}
            color={weaponEquipped ? "#ffe493" : "#8d8879"}
            emissive={weaponEquipped ? "#d38b28" : "#2b2922"}
            emissiveIntensity={weaponEquipped ? 2.5 : 0.18}
            metalness={weaponEquipped ? 0.7 : 0.35}
            roughness={weaponEquipped ? 0.18 : 0.42}
          />
        </mesh>
        {weaponEquipped && (
          <>
            <mesh position={[0, 1.58, 0]} rotation={[0, 0, Math.PI]} castShadow>
              <coneGeometry args={[0.13, 0.42, 4]} />
              <meshStandardMaterial color="#fff1ae" emissive="#e39a2e" emissiveIntensity={2.8} />
            </mesh>
            <mesh position={[0, 0.18, 0]} rotation={[Math.PI / 2, 0, 0]}>
              <torusGeometry args={[0.22, 0.035, 6, 24]} />
              <meshBasicMaterial color="#f8d47c" toneMapped={false} />
            </mesh>
          </>
        )}
        <pointLight ref={bladeLight} color="#f0b54c" intensity={weaponEquipped ? 2.6 : 0.25} distance={5} />
      </group>

      <mesh ref={slash} visible={false} position={[0, 1.1, -0.72]} rotation={[-Math.PI / 2, 0, -0.8]}>
        <torusGeometry args={[1.1, 0.035, 6, 48, Math.PI * 0.92]} />
        <meshBasicMaterial
          ref={slashMaterial}
          color="#f4cf79"
          transparent
          opacity={0}
          depthWrite={false}
          blending={THREE.AdditiveBlending}
        />
      </mesh>
    </group>
  );
}

interface StrikeTarget {
  kind: "source" | "boss";
  id?: string;
  distance: number;
  direction: THREE.Vector3;
}

export function PlayerController({ reducedMotion }: { reducedMotion: boolean }) {
  const root = useRef<THREE.Group>(null);
  const velocity = useRef(new THREE.Vector3());
  const knockbackVelocity = useRef(new THREE.Vector3());
  const desired = useRef(new THREE.Vector3());
  const facingAngle = useRef(Math.PI);
  const attack = useRef(0);
  const observedAttackNonce = useRef(0);
  const strikeActive = useRef(false);
  const strikeResolved = useRef(false);
  const strikeClock = useRef(0);
  const strikeCooldown = useRef(0);
  const storeWriteClock = useRef(0);
  const runNonce = useRaidStore((state) => state.runNonce);
  const playerDamageNonce = useRaidStore((state) => state.playerDamageNonce);

  useEffect(() => {
    const state = useRaidStore.getState();
    worldRuntime.player.set(0, 0.55, 9);
    worldRuntime.playerFacing.set(0, 0, -1);
    worldRuntime.hitStopUntil = 0;
    velocity.current.set(0, 0, 0);
    knockbackVelocity.current.set(0, 0, 0);
    facingAngle.current = Math.PI;
    attack.current = 0;
    observedAttackNonce.current = state.attackNonce;
    strikeActive.current = false;
    strikeResolved.current = false;
    strikeClock.current = 0;
    strikeCooldown.current = 0;
    storeWriteClock.current = 0;
    if (root.current) {
      root.current.position.copy(worldRuntime.player);
      root.current.rotation.set(0, Math.PI, 0);
    }
  }, [runNonce]);

  useEffect(() => {
    if (playerDamageNonce === 0) return;
    const state = useRaidStore.getState();
    const source = state.lastDamageSource;
    if (!source) return;
    const contextSource =
      source.kind === "source"
        ? CONTEXT_SOURCES.find((candidate) => candidate.id === source.id)
        : undefined;
    if (source.kind === "source" && !contextSource) return;
    const sourceX = source.kind === "boss" ? worldRuntime.boss.x : contextSource!.position[0];
    const sourceZ = source.kind === "boss" ? worldRuntime.boss.z : contextSource!.position[2];
    knockbackVelocity.current.set(
      worldRuntime.player.x - sourceX,
      0,
      worldRuntime.player.z - sourceZ,
    );
    if (knockbackVelocity.current.lengthSq() < 0.001) {
      knockbackVelocity.current.copy(worldRuntime.playerFacing).multiplyScalar(-1);
    }
    knockbackVelocity.current.normalize().multiplyScalar(state.playerDead ? 7.4 : 5.1);
    strikeActive.current = false;
    attack.current = 0;
  }, [playerDamageNonce]);

  const resolveStrike = () => {
    const state = useRaidStore.getState();
    if (state.playerDead || (state.phase !== "hunt" && state.phase !== "boss")) return;

    let nearest: StrikeTarget | undefined;
    if (state.phase === "hunt") {
      for (const source of CONTEXT_SOURCES) {
        if (state.sourceEnemies[source.id]?.defeated) continue;
        const direction = new THREE.Vector3(
          source.position[0] - worldRuntime.player.x,
          0,
          source.position[2] - worldRuntime.player.z,
        );
        const distance = direction.length();
        if (distance > 2.85) continue;
        direction.normalize();
        const inArc = distance < 1.25 || direction.dot(worldRuntime.playerFacing) > -0.08;
        if (inArc && (!nearest || distance < nearest.distance)) {
          nearest = { kind: "source", id: source.id, distance, direction };
        }
      }
    }

    if (state.bossLocks > 0) {
      const direction = new THREE.Vector3(
        worldRuntime.boss.x - worldRuntime.player.x,
        0,
        worldRuntime.boss.z - worldRuntime.player.z,
      );
      const distance = direction.length();
      direction.normalize();
      const inArc = distance < 1.6 || direction.dot(worldRuntime.playerFacing) > -0.08;
      if (distance <= 3.65 && inArc && (!nearest || distance < nearest.distance)) {
        nearest = { kind: "boss", distance, direction };
      }
    }

    if (!nearest) return;
    if (nearest.kind === "source" && nearest.id) {
      const before = state.sourceEnemies[nearest.id]?.health ?? 0;
      state.hitSource(nearest.id);
      const after = useRaidStore.getState().sourceEnemies[nearest.id]?.health ?? before;
      if (after < before) registerImpact(nearest.direction, reducedMotion ? 28 : 64);
      return;
    }

    const result = state.hitBoss();
    if (result === "hit") registerImpact(nearest.direction, reducedMotion ? 30 : 68);
    else if (result === "blocked") registerImpact(nearest.direction, reducedMotion ? 20 : 38);
  };

  useFrame((_, delta) => {
    if (!root.current || isHitStopped()) return;
    const dt = Math.min(delta, 0.05);
    const state = useRaidStore.getState();

    strikeCooldown.current = Math.max(0, strikeCooldown.current - dt);
    if (state.attackNonce !== observedAttackNonce.current) {
      observedAttackNonce.current = state.attackNonce;
      if (
        !state.playerDead &&
        (state.phase === "hunt" || state.phase === "boss") &&
        strikeCooldown.current <= 0
      ) {
        strikeActive.current = true;
        strikeResolved.current = false;
        strikeClock.current = 0;
        strikeCooldown.current = reducedMotion ? 0.18 : PLAYER_STRIKE_RECOVERY_SECONDS;
        attack.current = 1;
      }
    }

    if (strikeActive.current) {
      strikeClock.current += dt;
      const contact = reducedMotion ? 0.035 : PLAYER_STRIKE_CONTACT_SECONDS;
      if (!strikeResolved.current && strikeClock.current >= contact) {
        strikeResolved.current = true;
        resolveStrike();
      }
      if (strikeClock.current >= (reducedMotion ? 0.18 : PLAYER_STRIKE_RECOVERY_SECONDS)) {
        strikeActive.current = false;
      }
    }

    const canMove =
      !state.playerDead &&
      (state.phase === "hunt" ||
        state.phase === "root-reveal" ||
        state.phase === "boss" ||
        state.phase === "loot");
    desired.current.set(
      Number(state.controls.right) - Number(state.controls.left),
      0,
      Number(state.controls.backward) - Number(state.controls.forward),
    );
    if (!canMove) desired.current.set(0, 0, 0);
    if (desired.current.lengthSq() > 0) {
      desired.current.normalize().multiplyScalar(state.phase === "boss" ? 5.1 : 5.7);
      facingAngle.current = Math.atan2(desired.current.x, desired.current.z);
      worldRuntime.playerFacing.copy(desired.current).normalize();
    }

    velocity.current.x = THREE.MathUtils.damp(velocity.current.x, desired.current.x, 10.5, dt);
    velocity.current.z = THREE.MathUtils.damp(velocity.current.z, desired.current.z, 10.5, dt);
    worldRuntime.player.addScaledVector(velocity.current, dt);
    worldRuntime.player.addScaledVector(knockbackVelocity.current, dt);
    knockbackVelocity.current.multiplyScalar(Math.exp(-dt * 7.5));
    if (knockbackVelocity.current.lengthSq() < 0.002) knockbackVelocity.current.set(0, 0, 0);

    worldRuntime.player.x = THREE.MathUtils.clamp(worldRuntime.player.x, PLAYER_MIN_X, PLAYER_MAX_X);
    worldRuntime.player.z = THREE.MathUtils.clamp(worldRuntime.player.z, PLAYER_MIN_Z, PLAYER_MAX_Z);
    if (state.phase !== "handled" && worldRuntime.player.z < -9.95) {
      worldRuntime.player.z = -9.95;
    }

    root.current.position.copy(worldRuntime.player);
    root.current.rotation.y = THREE.MathUtils.damp(root.current.rotation.y, facingAngle.current, 13, dt);
    storeWriteClock.current += dt;
    if (storeWriteClock.current > 0.09) {
      storeWriteClock.current = 0;
      state.setPlayerPosition([worldRuntime.player.x, worldRuntime.player.y, worldRuntime.player.z]);
    }
  });

  return (
    <group ref={root} position={[0, 0.55, 9]}>
      <PlayerModel attack={attack} />
      <mesh position={[0, 0.035, 0]} rotation={[-Math.PI / 2, 0, 0]} receiveShadow>
        <circleGeometry args={[0.64, 28]} />
        <meshBasicMaterial color="#050604" transparent opacity={0.58} depthWrite={false} />
      </mesh>
    </group>
  );
}

/** Diegetic wisps point to: living source -> dropped source -> forged blade. */
export function HuntGuide({ reducedMotion }: { reducedMotion: boolean }) {
  const phase = useRaidStore((state) => state.phase);
  const sourceEnemies = useRaidStore((state) => state.sourceEnemies);
  const collectedSources = useRaidStore((state) => state.collectedSources);
  const weaponForged = useRaidStore((state) => state.weaponForged);
  const weaponEquipped = useRaidStore((state) => state.weaponEquipped);
  const bossBlockedNonce = useRaidStore((state) => state.bossBlockedNonce);
  const lastDamageSource = useRaidStore((state) => state.lastDamageSource);
  const wisps = useRef<(THREE.Mesh | null)[]>([]);
  const target = useMemo(() => new THREE.Vector3(), []);
  const point = useMemo(() => new THREE.Vector3(), []);
  const lateral = useMemo(() => new THREE.Vector3(), []);
  const visible = phase === "hunt" || phase === "root-reveal";

  useFrame((state) => {
    if (!visible) return;
    let nearestDistance = Number.POSITIVE_INFINITY;
    let found = false;

    const bossLessonSeen =
      bossBlockedNonce > 0 || lastDamageSource?.kind === "boss";
    if (phase === "hunt" && !bossLessonSeen) {
      target.copy(worldRuntime.boss).setY(0.74);
      nearestDistance = worldRuntime.player.distanceTo(worldRuntime.boss);
      found = true;
    }

    const chooseSource = (source: ContextSourceSpec) => {
      const distance = Math.hypot(
        source.position[0] - worldRuntime.player.x,
        source.position[2] - worldRuntime.player.z,
      );
      if (distance >= nearestDistance) return;
      nearestDistance = distance;
      target.set(source.position[0], 0.74, source.position[2]);
      found = true;
    };

    if (!found) {
      for (const source of CONTEXT_SOURCES) {
        if (!sourceEnemies[source.id]?.defeated) chooseSource(source);
      }
    }
    if (!found) {
      for (const source of CONTEXT_SOURCES) {
        if (!collectedSources.includes(source.id)) chooseSource(source);
      }
    }
    if (!found && weaponForged && !weaponEquipped) {
      target.set(...CAUSAL_WEAPON_POSITION);
      found = true;
    }

    wisps.current.forEach((wisp) => {
      if (wisp) wisp.visible = found;
    });
    if (!found) return;

    lateral.set(target.z - worldRuntime.player.z, 0, -(target.x - worldRuntime.player.x)).normalize();
    wisps.current.forEach((wisp, index) => {
      if (!wisp) return;
      const t = (index + 1) / (wisps.current.length + 1);
      point.lerpVectors(worldRuntime.player, target, t);
      const wave = reducedMotion ? 0 : Math.sin(state.clock.elapsedTime * 2.1 + index * 0.9) * 0.18;
      point.addScaledVector(lateral, wave);
      point.y =
        0.34 +
        Math.sin(t * Math.PI) * 0.52 +
        (reducedMotion ? 0 : Math.sin(state.clock.elapsedTime * 3.4 + index) * 0.06);
      wisp.position.copy(point);
      const pulse = reducedMotion
        ? 0.8
        : 0.72 + Math.sin(state.clock.elapsedTime * 4.2 - index * 0.75) * 0.24;
      wisp.scale.setScalar(pulse);
    });
  });

  if (!visible) return null;
  return (
    <group>
      {Array.from({ length: 7 }, (_, index) => (
        <mesh
          key={index}
          ref={(node) => {
            wisps.current[index] = node;
          }}
        >
          <octahedronGeometry args={[0.075 + index * 0.004, 0]} />
          <meshBasicMaterial color="#e5b65e" transparent opacity={0.74} toneMapped={false} />
        </mesh>
      ))}
    </group>
  );
}

function SourceSigil({ source }: { source: ContextSourceSpec }) {
  if (source.shape === "watch") {
    return (
      <group>
        <mesh rotation={[Math.PI / 2, 0, 0]}>
          <torusGeometry args={[0.34, 0.08, 7, 24]} />
          <meshStandardMaterial color={source.tint} emissive={source.tint} emissiveIntensity={0.55} />
        </mesh>
        <mesh scale={[0.45, 0.08, 0.11]}>
          <boxGeometry />
          <meshBasicMaterial color="#f0cb77" toneMapped={false} />
        </mesh>
      </group>
    );
  }
  if (source.shape === "calendar") {
    return (
      <group>
        <mesh scale={[0.55, 0.48, 0.08]}>
          <boxGeometry />
          <meshStandardMaterial color={source.tint} emissive="#5b5445" emissiveIntensity={0.35} />
        </mesh>
        {[-0.22, 0, 0.22].map((x) => (
          <mesh key={x} position={[x, -0.04, -0.1]} scale={[0.07, 0.24, 0.025]}>
            <boxGeometry />
            <meshBasicMaterial color="#2b2b24" />
          </mesh>
        ))}
      </group>
    );
  }
  if (source.shape === "notes") {
    return (
      <group>
        <mesh scale={[0.58, 0.44, 0.06]}>
          <boxGeometry />
          <meshStandardMaterial color={source.tint} emissive="#6d3218" emissiveIntensity={0.32} />
        </mesh>
        {[-0.22, -0.08, 0.08, 0.22].map((x, index) => (
          <mesh key={x} position={[x, 0, -0.08]} scale={[0.045, 0.12 + (index % 2) * 0.15, 0.02]}>
            <boxGeometry />
            <meshBasicMaterial color="#f1c777" />
          </mesh>
        ))}
      </group>
    );
  }
  return (
    <group>
      <mesh rotation={[0.3, 0, Math.PI / 4]}>
        <octahedronGeometry args={[0.43, 0]} />
        <meshStandardMaterial color={source.tint} emissive={source.tint} emissiveIntensity={0.72} flatShading />
      </mesh>
      <mesh scale={1.38} rotation={[0.3, 0, Math.PI / 4]}>
        <octahedronGeometry args={[0.43, 0]} />
        <meshBasicMaterial color="#f4d17c" transparent opacity={0.16} wireframe />
      </mesh>
    </group>
  );
}

function SourceEnemy({ source, index }: { source: ContextSourceSpec; index: number }) {
  const enemy = useRef<THREE.Group>(null);
  const core = useRef<THREE.Mesh>(null);
  const coreMaterial = useRef<THREE.MeshStandardMaterial>(null);
  const warningRing = useRef<THREE.Mesh>(null);
  const warningMaterial = useRef<THREE.MeshBasicMaterial>(null);
  const hitImpulse = useRef(0);
  const attackMode = useRef<EnemyAttackMode>("cooldown");
  const attackClock = useRef(0);
  const attackCooldown = useRef(0.8 + index * 0.24);
  const previousHealth = useRef(2);
  const health = useRaidStore((state) => state.sourceEnemies[source.id]?.health ?? 0);
  const defeated = useRaidStore((state) => state.sourceEnemies[source.id]?.defeated ?? false);
  const runNonce = useRaidStore((state) => state.runNonce);

  useEffect(() => {
    previousHealth.current = useRaidStore.getState().sourceEnemies[source.id]?.health ?? 2;
    hitImpulse.current = 0;
    attackMode.current = "cooldown";
    attackClock.current = 0;
    attackCooldown.current = 0.8 + index * 0.24;
    if (warningRing.current) warningRing.current.visible = false;
  }, [index, runNonce, source.id]);

  useEffect(() => {
    if (health < previousHealth.current) {
      hitImpulse.current = 1;
      attackMode.current = defeated ? "cooldown" : "stagger";
      attackClock.current = 0;
      attackCooldown.current = 1.15;
      if (warningRing.current) warningRing.current.visible = false;
    }
    previousHealth.current = health;
  }, [defeated, health]);

  useFrame((state, delta) => {
    if (!enemy.current || isHitStopped()) return;
    const dt = Math.min(delta, 0.05);
    const raid = useRaidStore.getState();
    const time = state.clock.elapsedTime + index * 1.71;
    const distance = Math.hypot(
      worldRuntime.player.x - source.position[0],
      worldRuntime.player.z - source.position[2],
    );

    if (raid.phase !== "hunt" || raid.playerDead || defeated) {
      if (attackMode.current === "telegraph" || attackMode.current === "release") {
        attackMode.current = "cooldown";
        attackCooldown.current = 0.8;
      }
    } else if (attackMode.current === "cooldown") {
      attackCooldown.current = Math.max(0, attackCooldown.current - dt);
      if (attackCooldown.current <= 0 && distance <= SOURCE_AGGRO_RANGE) {
        attackMode.current = "telegraph";
        attackClock.current = 0;
      }
    } else if (attackMode.current === "telegraph") {
      attackClock.current += dt;
      if (attackClock.current >= SOURCE_WINDUP_SECONDS) {
        const direction = new THREE.Vector3(
          worldRuntime.player.x - source.position[0],
          0,
          worldRuntime.player.z - source.position[2],
        );
        const currentDistance = direction.length();
        if (currentDistance <= SOURCE_AGGRO_RANGE + 0.15) {
          direction.normalize();
          const landed = raid.takePlayerHit({ kind: "source", id: source.id });
          if (landed) {
            registerPlayerImpact(direction, 46);
            worldRuntime.player.addScaledVector(direction, 0.38);
          }
        }
        attackMode.current = "release";
        attackClock.current = 0;
      }
    } else if (attackMode.current === "release") {
      attackClock.current += dt;
      if (attackClock.current >= 0.22) {
        attackMode.current = "cooldown";
        attackCooldown.current = SOURCE_COOLDOWN_SECONDS;
        attackClock.current = 0;
      }
    } else {
      attackClock.current += dt;
      if (attackClock.current >= 0.58) {
        attackMode.current = "cooldown";
        attackCooldown.current = 1.15;
        attackClock.current = 0;
      }
    }

    hitImpulse.current = Math.max(0, hitImpulse.current - dt * 3.8);
    const telegraph =
      attackMode.current === "telegraph"
        ? THREE.MathUtils.clamp(attackClock.current / SOURCE_WINDUP_SECONDS, 0, 1)
        : 0;
    const release =
      attackMode.current === "release" ? 1 - THREE.MathUtils.clamp(attackClock.current / 0.22, 0, 1) : 0;
    const alive = defeated ? 0 : 1;
    const charge = 1 + Math.sin(telegraph * Math.PI) * 0.13;
    const targetScale = alive * charge * (1 + Math.sin(time * 2.1) * 0.025) + hitImpulse.current * 0.16;
    enemy.current.scale.setScalar(
      THREE.MathUtils.damp(enemy.current.scale.x, targetScale, defeated ? 7 : 16, dt),
    );
    enemy.current.position.y =
      source.position[1] +
      Math.sin(time * 1.7) * 0.16 +
      hitImpulse.current * 0.22 -
      telegraph * 0.12;
    enemy.current.rotation.y = Math.atan2(
      worldRuntime.player.x - source.position[0],
      worldRuntime.player.z - source.position[2],
    );
    if (core.current) core.current.rotation.y += dt * (index % 2 === 0 ? 0.7 : -0.6);
    if (coreMaterial.current) {
      coreMaterial.current.emissiveIntensity =
        0.18 + hitImpulse.current * 3.6 + telegraph * (1.2 + Math.sin(time * 15) * 0.35);
      coreMaterial.current.color.set(hitImpulse.current > 0.3 ? "#f7d58a" : source.tint);
    }
    if (warningRing.current && warningMaterial.current) {
      const active = telegraph > 0 || release > 0;
      warningRing.current.visible = active;
      warningRing.current.scale.setScalar(
        telegraph > 0 ? 0.75 + telegraph * (SOURCE_AGGRO_RANGE - 0.75) : SOURCE_AGGRO_RANGE + (1 - release) * 1.8,
      );
      warningMaterial.current.opacity =
        telegraph > 0
          ? 0.18 + telegraph * 0.58 + Math.sin(time * 18) * telegraph * 0.08
          : release * 0.72;
    }
  });

  return (
    <group ref={enemy} position={source.position}>
      <mesh ref={core} castShadow>
        <dodecahedronGeometry args={[0.72, 0]} />
        <meshStandardMaterial
          ref={coreMaterial}
          color={source.tint}
          emissive={source.tint}
          emissiveIntensity={0.18}
          roughness={0.58}
          metalness={0.12}
          flatShading
        />
      </mesh>
      <mesh position={[0, -0.74, 0]} rotation={[Math.PI, 0, 0]} castShadow>
        <coneGeometry args={[0.64, 1.5, 7]} />
        <meshStandardMaterial color="#11130f" transparent opacity={0.9} roughness={1} flatShading />
      </mesh>
      <group position={[0, 0.02, -0.72]}>
        <SourceSigil source={source} />
      </group>
      {Array.from({ length: health }, (_, pip) => (
        <mesh key={pip} position={[(pip - 0.5) * 0.34, 1.18, 0]} rotation={[0, 0, Math.PI / 4]}>
          <octahedronGeometry args={[0.105, 0]} />
          <meshBasicMaterial color="#efc875" toneMapped={false} />
        </mesh>
      ))}
      <mesh
        ref={warningRing}
        visible={false}
        position={[0, -0.66, 0]}
        rotation={[-Math.PI / 2, 0, 0]}
      >
        <ringGeometry args={[0.88, 1, 48]} />
        <meshBasicMaterial
          ref={warningMaterial}
          color="#c85a38"
          transparent
          opacity={0}
          depthWrite={false}
          side={THREE.DoubleSide}
        />
      </mesh>
      <pointLight color={source.tint} intensity={1.45} distance={4.2} />
    </group>
  );
}

/** Kept under the original export name so InkWorld remains integration-stable. */
export function SymptomEnemies() {
  const phase = useRaidStore((state) => state.phase);
  if (phase !== "hunt") return null;
  return (
    <group>
      {CONTEXT_SOURCES.map((source, index) => (
        <SourceEnemy key={source.id} source={source} index={index} />
      ))}
    </group>
  );
}
