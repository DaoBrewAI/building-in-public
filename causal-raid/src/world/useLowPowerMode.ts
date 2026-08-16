import { useEffect, useState } from "react";

function detectLowPowerMode() {
  const memory = (navigator as Navigator & { deviceMemory?: number }).deviceMemory ?? 8;
  return (
    window.matchMedia("(max-width: 900px), (pointer: coarse)").matches ||
    navigator.hardwareConcurrency <= 4 ||
    memory <= 4
  );
}

export function useLowPowerMode() {
  const [lowPower, setLowPower] = useState(detectLowPowerMode);

  useEffect(() => {
    const media = window.matchMedia("(max-width: 900px), (pointer: coarse)");
    const update = () => setLowPower(detectLowPowerMode());
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  return lowPower;
}
