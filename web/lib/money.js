// Display formatting for money and Plaid category codes.
// Amounts in the database keep Plaid's sign (positive = money out); callers decide the sign to show.

const cents = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const whole = new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 });
const missing = (n) => n === null || n === undefined || Number.isNaN(n);

/** 1234.5 → "$1,234.50"; -12 → "−$12.00"; null → "–" */
export function fmtUSD(n) {
  if (missing(n)) return "–";
  return `${n < 0 ? "−" : ""}$${cents.format(Math.abs(n))}`;
}

/** 1234.5 → "$1,235" (chart axes, headline numbers) */
export function fmtUSDWhole(n) {
  if (missing(n)) return "–";
  const r = Math.round(n);
  return `${r < 0 ? "−" : ""}$${whole.format(Math.abs(r))}`;
}

/** "FOOD_AND_DRINK" → "Food & drink" */
export function categoryLabel(code) {
  if (!code) return "Uncategorized";
  const text = String(code).toLowerCase().split("_").map((w) => (w === "and" ? "&" : w)).join(" ");
  return text.charAt(0).toUpperCase() + text.slice(1);
}
