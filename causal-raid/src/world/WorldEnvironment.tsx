import { useFrame } from "@react-three/fiber";
import { useMemo, useRef } from "react";
import * as THREE from "three";
import { useRaidStore } from "../game/store";
import { seededRandom } from "./runtime";

const groundVertex = /* glsl */ `
  varying vec2 vUv;
  varying vec3 vWorld;
  void main() {
    vUv = uv;
    vec3 p = position;
    p.z += sin(p.x * .23) * .055 + sin(p.y * .17) * .045;
    vec4 world = modelMatrix * vec4(p, 1.0);
    vWorld = world.xyz;
    gl_Position = projectionMatrix * viewMatrix * world;
  }
`;

const groundFragment = /* glsl */ `
  precision highp float;
  varying vec2 vUv;
  varying vec3 vWorld;
  uniform float uHandled;

  float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
  }

  float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1., 0.)), f.x),
               mix(hash(i + vec2(0., 1.)), hash(i + vec2(1., 1.)), f.x), f.y);
  }

  float fbm(vec2 p) {
    float value = 0.;
    float amp = .5;
    for (int i = 0; i < 5; i++) {
      value += noise(p) * amp;
      p = p * 2.03 + vec2(9.1, 4.7);
      amp *= .48;
    }
    return value;
  }

  void main() {
    vec2 p = vWorld.xz;
    float broad = fbm(p * .075);
    float fibers = noise(vec2(p.x * 1.8, p.y * .12));
    float brush = smoothstep(.42, .7, fbm(p * .23 + vec2(2.3, -1.4)));
    float river = 1.0 - smoothstep(1.2, 2.85, abs(p.y + 11.5 + sin(p.x * .16) * .55));
    vec3 paper = vec3(.105, .105, .088);
    vec3 ink = vec3(.018, .022, .019);
    vec3 warm = vec3(.22, .155, .07);
    vec3 col = mix(ink, paper, broad * .72 + .12);
    col -= brush * .035;
    col += (fibers - .5) * .018;
    col = mix(col, vec3(.008, .013, .012), river * .82);
    col += warm * uHandled * (1.0 - smoothstep(2., 16., length(p))) * .25;
    float edge = smoothstep(34., 17., length(p));
    gl_FragColor = vec4(col * edge, 1.0);
  }
`;

function InkGround() {
  const phase = useRaidStore((state) => state.phase);
  const material = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader: groundVertex,
        fragmentShader: groundFragment,
        uniforms: { uHandled: { value: 0 } },
        side: THREE.DoubleSide,
      }),
    [],
  );

  useFrame((_, delta) => {
    const target = phase === "handled" ? 1 : 0;
    material.uniforms.uHandled.value = THREE.MathUtils.damp(
      material.uniforms.uHandled.value,
      target,
      2.2,
      delta,
    );
  });

  return (
    <mesh rotation={[-Math.PI / 2, 0, 0]} receiveShadow>
      <planeGeometry args={[72, 72, 96, 96]} />
      <primitive object={material} attach="material" />
    </mesh>
  );
}

interface MountainSpec {
  position: [number, number, number];
  scale: [number, number, number];
  shade: string;
  rotation: number;
}

function InkMountains() {
  const mountains = useMemo<MountainSpec[]>(() => {
    const random = seededRandom(84621);
    return Array.from({ length: 23 }, (_, index) => {
      const side = index % 2 === 0 ? -1 : 1;
      const z = -20 + random() * 38;
      const x = side * (15 + random() * 11);
      const height = 5 + random() * 10;
      return {
        position: [x, height * 0.48 - 0.4, z],
        scale: [3.5 + random() * 5.5, height, 3.2 + random() * 5],
        shade: index % 3 === 0 ? "#141713" : index % 3 === 1 ? "#0c100d" : "#202019",
        rotation: random() * Math.PI,
      };
    });
  }, []);

  return (
    <group>
      {mountains.map((mountain, index) => (
        <group key={index} position={mountain.position} rotation={[0, mountain.rotation, 0]}>
          <mesh scale={mountain.scale} castShadow receiveShadow>
            <coneGeometry args={[1, 1, index % 4 === 0 ? 5 : 7, 3]} />
            <meshStandardMaterial
              color={mountain.shade}
              roughness={1}
              metalness={0}
              flatShading
            />
          </mesh>
          <mesh
            position={[-0.12, mountain.scale[1] * 0.17, 0.08]}
            scale={[mountain.scale[0] * 0.73, mountain.scale[1] * 0.74, mountain.scale[2] * 0.72]}
          >
            <coneGeometry args={[1, 1, 5, 1]} />
            <meshBasicMaterial color="#444035" transparent opacity={0.08} depthWrite={false} />
          </mesh>
        </group>
      ))}
    </group>
  );
}

function Reed({ x, z, height, lean }: { x: number; z: number; height: number; lean: number }) {
  return (
    <group position={[x, 0.02, z]} rotation={[0, 0, lean]}>
      <mesh position={[0, height / 2, 0]}>
        <cylinderGeometry args={[0.012, 0.028, height, 4]} />
        <meshStandardMaterial color="#39382d" roughness={1} />
      </mesh>
      <mesh position={[0.05, height * 0.76, 0]} rotation={[0, 0, -0.65]}>
        <coneGeometry args={[0.045, 0.35, 4]} />
        <meshStandardMaterial color="#75623b" emissive="#4a3215" emissiveIntensity={0.2} />
      </mesh>
    </group>
  );
}

function RiverReeds() {
  const reeds = useMemo(() => {
    const random = seededRandom(9911);
    return Array.from({ length: 74 }, (_, index) => {
      const x = -16 + random() * 32;
      const bank = index % 2 === 0 ? -1 : 1;
      return {
        x,
        z: -11.5 + bank * (1.7 + random() * 1.65) - Math.sin(x * 0.16) * 0.55,
        height: 0.35 + random() * 0.85,
        lean: (random() - 0.5) * 0.35,
      };
    });
  }, []);
  return <group>{reeds.map((reed, index) => <Reed key={index} {...reed} />)}</group>;
}

function DriftingAsh({ reducedMotion }: { reducedMotion: boolean }) {
  const points = useRef<THREE.Points>(null);
  const positions = useMemo(() => {
    const random = seededRandom(7742);
    const array = new Float32Array(360 * 3);
    for (let index = 0; index < 360; index += 1) {
      array[index * 3] = (random() - 0.5) * 46;
      array[index * 3 + 1] = 0.4 + random() * 10;
      array[index * 3 + 2] = (random() - 0.5) * 46;
    }
    return array;
  }, []);

  useFrame((state, delta) => {
    if (!points.current || reducedMotion) return;
    points.current.rotation.y += delta * 0.008;
    points.current.position.y = Math.sin(state.clock.elapsedTime * 0.07) * 0.25;
  });

  return (
    <points ref={points}>
      <bufferGeometry>
        <bufferAttribute attach="attributes-position" args={[positions, 3]} />
      </bufferGeometry>
      <pointsMaterial
        color="#d8b36a"
        size={0.055}
        sizeAttenuation
        transparent
        opacity={0.34}
        depthWrite={false}
        blending={THREE.AdditiveBlending}
      />
    </points>
  );
}

function BrokenBridge() {
  const phase = useRaidStore((state) => state.phase);
  const repaired = useRef<THREE.Group>(null);
  const glow = useRef<THREE.PointLight>(null);

  useFrame((_, delta) => {
    const target = phase === "handled" ? 1 : 0;
    if (repaired.current) {
      const next = THREE.MathUtils.damp(repaired.current.scale.y, target, 3.4, delta);
      repaired.current.scale.setScalar(Math.max(0.001, next));
      repaired.current.position.y = THREE.MathUtils.damp(repaired.current.position.y, target ? 0 : -2, 3, delta);
    }
    if (glow.current) glow.current.intensity = THREE.MathUtils.damp(glow.current.intensity, target * 7, 2.2, delta);
  });

  const stones = [-4.2, -3.25, -2.35, 2.35, 3.25, 4.2];
  const repairedStones = [-1.55, -0.78, 0, 0.78, 1.55];
  return (
    <group position={[0, 0.08, -11.5]} rotation={[0, 0.06, 0]}>
      {stones.map((x, index) => (
        <mesh key={x} position={[x * 0.46, index % 2 * 0.06, 0]} rotation={[0, (index % 3 - 1) * 0.12, 0]} castShadow receiveShadow>
          <boxGeometry args={[0.76, 0.16, 2.05]} />
          <meshStandardMaterial color="#27271f" roughness={0.92} flatShading />
        </mesh>
      ))}
      <group ref={repaired} position={[0, -2, 0]} scale={0.001}>
        {repairedStones.map((x, index) => (
          <mesh key={x} position={[x * 0.46, Math.abs(index - 2) * -0.025, 0]} castShadow receiveShadow>
            <boxGeometry args={[0.72, 0.17, 2.05]} />
            <meshStandardMaterial
              color="#504125"
              emissive="#a56d22"
              emissiveIntensity={0.22}
              roughness={0.8}
              flatShading
            />
          </mesh>
        ))}
      </group>
      <pointLight ref={glow} color="#e2a847" distance={10} intensity={0} position={[0, 2.1, 0]} />
    </group>
  );
}

function InkGate() {
  return (
    <group position={[0, 0, -16]}>
      <mesh position={[-2.15, 2.6, 0]} castShadow>
        <boxGeometry args={[0.42, 5.2, 0.55]} />
        <meshStandardMaterial color="#171714" roughness={0.9} />
      </mesh>
      <mesh position={[2.15, 2.6, 0]} castShadow>
        <boxGeometry args={[0.42, 5.2, 0.55]} />
        <meshStandardMaterial color="#171714" roughness={0.9} />
      </mesh>
      <mesh position={[0, 5.05, 0]} castShadow>
        <boxGeometry args={[5.45, 0.42, 0.62]} />
        <meshStandardMaterial color="#261d13" emissive="#4f2d0e" emissiveIntensity={0.15} roughness={0.86} />
      </mesh>
      <mesh position={[0, 4.35, 0]} castShadow>
        <boxGeometry args={[4.55, 0.25, 0.5]} />
        <meshStandardMaterial color="#121410" roughness={0.94} />
      </mesh>
    </group>
  );
}

export function WorldEnvironment({ reducedMotion }: { reducedMotion: boolean }) {
  const handled = useRaidStore((state) => state.phase === "handled");
  return (
    <>
      <ambientLight intensity={handled ? 0.62 : 0.42} color={handled ? "#d8c593" : "#aab0a1"} />
      <hemisphereLight args={["#8b947f", "#090b09", handled ? 1.15 : 0.72]} />
      <directionalLight
        castShadow
        color="#f0c57d"
        intensity={handled ? 2.8 : 1.75}
        position={[-8, 14, 9]}
        shadow-mapSize-width={1024}
        shadow-mapSize-height={1024}
        shadow-camera-far={44}
        shadow-camera-left={-20}
        shadow-camera-right={20}
        shadow-camera-top={20}
        shadow-camera-bottom={-20}
      />
      <InkGround />
      <InkMountains />
      <RiverReeds />
      <BrokenBridge />
      <InkGate />
      <DriftingAsh reducedMotion={reducedMotion} />
    </>
  );
}
