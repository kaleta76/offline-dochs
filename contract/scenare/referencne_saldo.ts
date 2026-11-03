// Referenčné denné saldá z enginu terminálu (src/lib/engine.ts) pre scenár z make_mesiac.py.
// Použitie:  TZ=Europe/Bratislava tsx contract/scenare/referencne_saldo.ts popis_2026-10.csv.json ocakavane_saldo_2026-10.csv RRRR MM
// Výstup má rovnaké stĺpce ako súbor „Stiahnuť saldá“ v administrácii terminála (buildBalanceCsv).
import { readFileSync, writeFileSync } from "node:fs";
import { computeDay, settingsFromRows, type PunchLike } from "../../src/lib/engine";
import { buildBalanceCsv, type BalanceDay } from "../../src/lib/test-import";

const [popisPath, outPath, yearArg, monthArg] = process.argv.slice(2);
if (!popisPath || !outPath || !yearArg || !monthArg) throw new Error("Použitie: referencne_saldo.ts popis.json vystup.csv RRRR MM");
const year = Number(yearArg);
const month = Number(monthArg);
const scen = JSON.parse(readFileSync(popisPath, "utf8")) as { osc: string; den: string; razenia: [string, string, string][] }[];
const s = settingsFromRows([]);
const HOLIDAYS = new Set<string>(); // v októbri 2026 nie je štátny sviatok
const pad = (n: number) => String(n).padStart(2, "0");

const persons = [...new Set(scen.map((x) => x.osc))].sort();
const days: BalanceDay[] = [];
for (const osc of persons) {
  for (let d = 1; d <= new Date(year, month, 0).getDate(); d++) {
    const key = `${year}-${pad(month)}-${pad(d)}`;
    const punches: PunchLike[] = scen
      .filter((x) => x.osc === osc && x.den === key)
      .flatMap((x) => x.razenia)
      .map(([code, direction, hm]) => ({
        code,
        direction: direction as "IN" | "OUT",
        time: new Date(`${key}T${hm.length === 5 ? hm + ":00" : hm}`),
      }));
    const dow = new Date(`${key}T12:00:00`).getDay();
    const weekend = dow === 0 || dow === 6;
    const holiday = HOLIDAYS.has(key);
    const r = computeDay({ punches, fundHours: s.fund, isWorkday: !weekend && !holiday }, s);
    days.push({
      sap: osc, key, weekend, holiday,
      expectedMin: r.expectedMin, totalMin: r.totalMin, balanceMin: r.balanceMin,
      workMin: r.workMin, creditMin: r.creditMin, breakMin: r.breakMin, open: r.open, byCode: r.byCode,
    });
  }
}
writeFileSync(outPath, buildBalanceCsv(days));
const sums = new Map<string, number>();
for (const x of days) sums.set(x.sap, (sums.get(x.sap) ?? 0) + x.balanceMin);
console.log([...sums].map(([k, v]) => `${k}: saldo mesiaca ${v} min`).join("\n"));
