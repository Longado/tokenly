// tokenmeter desktop widget for Übersicht (https://tracesof.net/uebersicht/)
// Shows API-equivalent cost today / last 30 days, plus per-model breakdown.
// If tokenmeter is not on PATH, change TOKENMETER to e.g. "python3 /path/to/tokenmeter.py".
const TOKENMETER = "tokenmeter";

export const command =
  `export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"; ${TOKENMETER} 30 --json`;
export const refreshFrequency = 5 * 60 * 1000;

export const className = `
  top: 40px; right: 40px; width: 300px;
  padding: 16px 18px; border-radius: 14px;
  background: rgba(20, 20, 24, 0.55);
  -webkit-backdrop-filter: blur(20px);
  color: #f2f2f2; font: 12px -apple-system, sans-serif;
  .h { display: flex; justify-content: space-between; opacity: .6; font-size: 11px; }
  .big { display: flex; gap: 24px; margin: 6px 0 12px; }
  .big b { font-size: 26px; font-weight: 600; display: block; }
  .big span { opacity: .6; font-size: 11px; }
  .m { margin-top: 8px; }
  .m .l { display: flex; justify-content: space-between; }
  .bar { height: 4px; border-radius: 2px; background: rgba(255,255,255,.12); margin-top: 3px; }
  .bar i { display: block; height: 100%; border-radius: 2px; background: #7aa2ff; }
  .err { color: #ff8a80; white-space: pre-wrap; }
`;

const usd = (v) => "$" + v.toFixed(2);
const tok = (r) => {
  const n = r.input + r.output + r.cache_read + r.cache_write;
  return n >= 1e6 ? (n / 1e6).toFixed(1) + "M" : (n / 1e3).toFixed(0) + "K";
};

export const render = ({ output, error }) => {
  let d;
  try { d = JSON.parse(output); } catch (e) {
    return <div className="err">tokenmeter: {error || output || "no output"}</div>;
  }
  const today = new Date().toISOString().slice(0, 10);
  const t = d.day[today] || { cost_usd: 0 };
  const models = Object.entries(d.model).sort((a, b) => b[1].cost_usd - a[1].cost_usd);
  const total = models.reduce((s, [, r]) => s + r.cost_usd, 0);
  return (
    <div>
      <div className="h"><span>tokenmeter</span><span>{new Date().toLocaleTimeString().slice(0, 5)}</span></div>
      <div className="big">
        <div><b>{usd(t.cost_usd)}</b><span>today</span></div>
        <div><b>{usd(total)}</b><span>last 30 days</span></div>
      </div>
      {models.map(([name, r]) => (
        <div className="m" key={name}>
          <div className="l"><span>{name.split(":")[1]}</span><span>{tok(r)} · {usd(r.cost_usd)}</span></div>
          <div className="bar"><i style={{ width: (total ? (100 * r.cost_usd) / total : 0) + "%" }} /></div>
        </div>
      ))}
    </div>
  );
};
