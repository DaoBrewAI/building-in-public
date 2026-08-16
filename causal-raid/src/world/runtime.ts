import * as THREE from "three";

/**
 * Mutable render-only state shared by actors and the camera. The public Zustand
 * store receives a throttled copy for UI, while frame-rate motion stays out of
 * React state.
 */
export const worldRuntime = {
  player: new THREE.Vector3(0, 0.55, 9),
  playerFacing: new THREE.Vector3(0, 0, -1),
  impactDirection: new THREE.Vector3(0, 0, -1),
  hitStopUntil: 0,
  boss: new THREE.Vector3(0, 1.25, -1.2),
  bridge: new THREE.Vector3(0, 0.15, -11.5),
  portal: new THREE.Vector3(0, 3.2, -16),
};

export function registerImpact(direction: THREE.Vector3, durationMs = 62) {
  worldRuntime.impactDirection.copy(direction).setY(0).normalize();
  worldRuntime.hitStopUntil = performance.now() + durationMs;
}

/**
 * Enemy-to-player contact uses the same short render freeze as a sword hit,
 * but is triggered from the independent player damage nonce. Keeping the
 * entry point explicit prevents combat code from treating incoming damage as
 * a successful player attack.
 */
export function registerPlayerImpact(direction: THREE.Vector3, durationMs = 46) {
  worldRuntime.impactDirection.copy(direction).setY(0).normalize();
  worldRuntime.hitStopUntil = performance.now() + durationMs;
}

export function isHitStopped() {
  return performance.now() < worldRuntime.hitStopUntil;
}

export const WORLD_UP = new THREE.Vector3(0, 1, 0);

export function seededRandom(seed: number) {
  let value = seed >>> 0;
  return () => {
    value = (value * 1664525 + 1013904223) >>> 0;
    return value / 4294967296;
  };
}
