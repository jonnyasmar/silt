/** Layers of river sediment, as on the app icon: a quiet band between sections. */
export function Strata({ className = "" }: { className?: string }) {
  return (
    <svg
      className={`block w-full ${className}`}
      viewBox="0 0 1440 120"
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <path d="M0 38 C 240 20 420 48 720 34 S 1200 18 1440 36 L1440 120 L0 120 Z" fill="var(--strata-1)" />
      <path d="M0 62 C 260 50 480 74 760 60 S 1180 46 1440 64 L1440 120 L0 120 Z" fill="var(--strata-2)" />
      <path d="M0 84 C 300 76 520 96 800 84 S 1220 72 1440 88 L1440 120 L0 120 Z" fill="var(--strata-3)" />
      <path d="M0 104 C 320 98 560 112 840 104 S 1240 96 1440 108 L1440 120 L0 120 Z" fill="var(--strata-4)" />
    </svg>
  );
}
