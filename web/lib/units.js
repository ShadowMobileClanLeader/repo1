// Unit conversion and display formatting. The database stores SI units;
// imperial values exist only at display time. Every function passes null through.

const KG_TO_LB = 2.20462;
const M_PER_MI = 1609.344;
const KM_PER_MI = 1.609344;

const missing = (x) => x === null || x === undefined || Number.isNaN(x);

export const kgToLb = (kg) => (missing(kg) ? null : kg * KG_TO_LB);
export const mToMi = (m) => (missing(m) ? null : m / M_PER_MI);
export const paceSecPerKmToSecPerMi = (s) => (missing(s) ? null : s * KM_PER_MI);

/** 579.36 → "9:39" (minutes:seconds per mile) */
export function fmtPace(secPerMi) {
  if (missing(secPerMi)) return null;
  const total = Math.round(secPerMi);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

/** 7.7 → "7 h 42 m" */
export function fmtHM(hours) {
  if (missing(hours)) return null;
  const mins = Math.round(hours * 60);
  return `${Math.floor(mins / 60)} h ${String(mins % 60).padStart(2, "0")} m`;
}
