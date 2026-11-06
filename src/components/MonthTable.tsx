import { AlertTriangle } from "lucide-react";
import { fmtMin } from "@/lib/engine";
import { hm, labelOf, WEEKDAYS, type MonthData } from "@/lib/month";
import { unverifiedSummary } from "@/lib/device-trace";

export interface VoidTarget {
  id: number;
  label: string;
  time: string;
}

/**
 * Mesačná tabuľka. S `onVoid` sa pri každom razení ukáže odkaz „zneplatniť“ (žiadosť o zneplatnenie, napr. pri duplicite).
 * Zneplatnené razenia sú preškrtnuté a do výpočtu sa nezapočítavajú.
 */
export function MonthTable({
  data,
  compact = false,
  onVoid,
  approvalCodes,
}: {
  data: MonthData;
  compact?: boolean;
  onVoid?: (target: VoidTarget) => void;
  /** Kódy prerušení z konfigurácie Accessu s needs_approval = true; označenie nevyjadruje stav schválenia. */
  approvalCodes?: ReadonlySet<string>;
}) {
  return (
    <div className="overflow-x-auto">
      {data.unverifiedCount > 0 && (
        <p
          role="status"
          className="no-print mb-2 rounded-sm border border-warning bg-muted px-3 py-2 text-sm"
        >
          {unverifiedSummary(data.unverifiedCount)}
        </p>
      )}
      <table className="w-full border-collapse text-sm">
        <thead>
          <tr className="border-b-2 border-foreground text-left text-xs uppercase tracking-wider">
            <th className="py-2 pr-2">Deň</th>
            <th className="py-2 pr-2">Záznamy</th>
            <th className="py-2 pr-2 text-right">Práca</th>
            <th className="py-2 pr-2 text-right">Dopočet</th>
            <th className="py-2 pr-2 text-right">Spolu</th>
            <th className="py-2 text-right">Saldo</th>
          </tr>
        </thead>
        <tbody>
          {data.days.map((d) => {
            const off = d.weekend || d.holiday;
            return (
              <tr
                key={d.key}
                className={`border-b border-border ${off ? "bg-muted/60 text-muted-foreground" : ""}`}
              >
                <td className="num whitespace-nowrap py-1.5 pr-2">
                  {WEEKDAYS[d.date.getDay()]} {d.date.getDate()}.
                </td>
                <td className="py-1.5 pr-2">
                  {d.holiday && <span className="mr-2 text-xs font-semibold">{d.holiday}</span>}
                  {d.punches.map((p, i) => (
                    <span
                      key={i}
                      className={`mr-2 whitespace-nowrap text-xs ${p.voided ? "text-muted-foreground line-through" : ""}`}
                      title={p.voided ? "Razenie je zneplatnené a nepočíta sa" : undefined}
                    >
                      {labelOf(p.code, p.direction)} <span className="num">{hm(p.time)}</span>
                      {!compact && p.source === "terminal" && Math.abs(p.drift) > data.maxDrift && (
                        <span
                          title={`Odoslané o ${p.drift} min neskôr (offline)`}
                          className="ml-0.5 inline-flex text-warning-foreground"
                        >
                          <AlertTriangle className="inline h-3 w-3 text-warning" />
                        </span>
                      )}
                      {p.source === "correction" && (
                        <sup className="ml-0.5 font-bold text-primary">K</sup>
                      )}
                      {p.verification === "unverified" && !p.voided && (
                        <span
                          className="ml-1 rounded-sm border border-warning px-1 text-[10px] font-semibold uppercase text-warning-foreground"
                          title="Razenie z neschváleného zariadenia. Počíta sa, kým ho vedúci nepotvrdí."
                        >
                          neoverené
                        </span>
                      )}
                      {p.voidPending && (
                        <span className="ml-1 font-semibold text-warning-foreground">
                          (čaká na zneplatnenie)
                        </span>
                      )}
                      {!p.voided && approvalCodes?.has(p.code) && (
                        <span
                          className="ml-1 rounded-sm border border-warning px-1 text-[10px] font-semibold uppercase text-warning-foreground"
                          title="Toto prerušenie schvaľuje vedúci; terminál stav schválenia nepozná."
                        >
                          vyžaduje schválenie
                        </span>
                      )}
                      {onVoid && !p.voided && !p.voidPending && !data.closedAt && (
                        <button
                          type="button"
                          className="no-print ml-1 rounded-sm border border-border px-1 text-[10px] text-muted-foreground hover:border-foreground hover:text-foreground"
                          aria-label={`Požiadať o zneplatnenie: ${labelOf(p.code, p.direction)} ${hm(p.time)}`}
                          onClick={() =>
                            onVoid({
                              id: p.id,
                              label: labelOf(p.code, p.direction),
                              time: hm(p.time),
                            })
                          }
                        >
                          zneplatniť
                        </button>
                      )}
                    </span>
                  ))}
                  {d.open && !d.future && (
                    <span className="text-xs font-bold text-destructive">chýba odchod</span>
                  )}
                </td>
                <td className="num py-1.5 pr-2 text-right">{d.workMin ? fmtMin(d.workMin) : ""}</td>
                <td className="num py-1.5 pr-2 text-right">
                  {d.creditMin ? fmtMin(d.creditMin) : ""}
                </td>
                <td className="num py-1.5 pr-2 text-right font-semibold">
                  {d.totalMin ? fmtMin(d.totalMin) : ""}
                </td>
                <td
                  className={`num py-1.5 text-right ${d.balanceMin < 0 ? "text-destructive" : d.balanceMin > 0 ? "text-success" : ""}`}
                >
                  {d.balanceMin ? fmtMin(d.balanceMin) : ""}
                </td>
              </tr>
            );
          })}
        </tbody>
        <tfoot>
          <tr className="border-t-2 border-foreground font-bold">
            <td className="py-2" colSpan={2}>
              Spolu (fond {fmtMin(data.totals.expected)})
            </td>
            <td className="num py-2 pr-2 text-right">{fmtMin(data.totals.work)}</td>
            <td className="num py-2 pr-2 text-right">{fmtMin(data.totals.credit)}</td>
            <td className="num py-2 pr-2 text-right">{fmtMin(data.totals.total)}</td>
            <td
              className={`num py-2 text-right ${data.totals.balance < 0 ? "text-destructive" : "text-success"}`}
            >
              {fmtMin(data.totals.balance)}
            </td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

export function MonthPicker({
  ym,
  onChange,
}: {
  ym: { y: number; m: number };
  onChange: (v: { y: number; m: number }) => void;
}) {
  const shift = (d: number) => {
    const dt = new Date(ym.y, ym.m - 1 + d, 1);
    onChange({ y: dt.getFullYear(), m: dt.getMonth() + 1 });
  };
  const label = new Date(ym.y, ym.m - 1, 1).toLocaleDateString("sk-SK", {
    month: "long",
    year: "numeric",
  });
  return (
    <div className="flex items-center gap-1">
      <button
        className="rounded-sm border-2 border-foreground px-2.5 py-1 font-bold"
        onClick={() => shift(-1)}
        aria-label="Predchádzajúci mesiac"
      >
        ‹
      </button>
      <span className="min-w-36 text-center font-bold capitalize">{label}</span>
      <button
        className="rounded-sm border-2 border-foreground px-2.5 py-1 font-bold"
        onClick={() => shift(1)}
        aria-label="Nasledujúci mesiac"
      >
        ›
      </button>
    </div>
  );
}
