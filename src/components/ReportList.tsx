import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { MonthPicker } from "@/components/MonthTable";
import { personnelLabel } from "@/lib/personnel";

type Person = { id: string; sap_id: string | null };

/**
 * Predtlač výkazu dochádzky pre tých, čo nepoužívajú Access: za zvolený mesiac zoznam osobných čísel, každé otvorí mesačný výkaz
 * (A4 na tlač). Výkaz obsahuje len osobné číslo, razenia a salda; meno a priezvisko sa dopíše ručne (je tam na to riadok).
 */
export function ReportList({
  people,
  loading,
  failed,
}: {
  people: Person[];
  loading: boolean;
  failed: boolean;
}) {
  const now = new Date();
  const [ym, setYm] = useState({ y: now.getFullYear(), m: now.getMonth() + 1 });
  const sorted = [...people].sort((a, b) =>
    personnelLabel(a).localeCompare(personnelLabel(b), "sk", { numeric: true }),
  );

  return (
    <section className="rounded-sm border-2 border-foreground bg-card p-4">
      <h2 className="mb-3 text-sm font-bold uppercase tracking-widest">Výkazy dochádzky na tlač</h2>
      <div className="flex flex-wrap items-center gap-3">
        <MonthPicker ym={ym} onChange={setYm} />
      </div>
      <p className="mt-2 text-xs text-muted-foreground">
        Pre tých, čo nepoužívajú Access. Výkaz má osobné číslo, razenia a salda za mesiac a podpisy;
        meno a priezvisko doplňte ručne. Otvorí sa na samostatnej stránke a vytlačíte ho tlačidlom
        Tlačiť.
      </p>
      {loading && <p className="mt-3 text-sm text-muted-foreground">Načítavam…</p>}
      {failed && (
        <p role="alert" className="mt-3 text-sm text-destructive">
          Zoznam zamestnancov sa nepodarilo načítať.
        </p>
      )}
      {!loading && !failed && sorted.length === 0 && (
        <p className="mt-3 text-sm text-muted-foreground">Zatiaľ nie sú žiadni zamestnanci.</p>
      )}
      <ul className="mt-3 flex flex-wrap gap-2">
        {sorted.map((p) => (
          <li key={p.id}>
            <Link
              to="/vykaz/$userId/$ym"
              params={{ userId: p.id, ym: `${ym.y}-${ym.m}` }}
              className="num inline-block rounded-sm border-2 border-foreground px-2 py-1 text-xs font-bold"
              aria-label={`Výkaz ${personnelLabel(p)}`}
            >
              {personnelLabel(p)}
            </Link>
          </li>
        ))}
      </ul>
    </section>
  );
}
