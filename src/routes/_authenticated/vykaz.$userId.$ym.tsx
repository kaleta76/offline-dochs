import { personnelLabel } from "@/lib/personnel";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { loadMonth, MONTHS } from "@/lib/month";
import { MonthPicker, MonthTable } from "@/components/MonthTable";
import { useVoidRequest } from "@/components/VoidRequest";
import { Button } from "@/components/ui/button";

export const Route = createFileRoute("/_authenticated/vykaz/$userId/$ym")({
  head: () => ({ meta: [{ title: "Mesačný výkaz – Dochádzka" }, { name: "description", content: "Mesačný výkaz dochádzky na podpis." }, { property: "og:title", content: "Mesačný výkaz – Dochádzka" }, { property: "og:description", content: "Mesačný výkaz dochádzky na podpis." }, { property: "og:type", content: "website" }, { name: "twitter:card", content: "summary" }] }),
  component: Report,
});

function Report() {
  const { userId, ym } = Route.useParams();
  const [y = 2026, m = 1] = ym.split("-").map(Number);
  const navigate = useNavigate();
  const q = useQuery({ queryKey: ["month", userId, y, m], queryFn: () => loadMonth(userId, y, m) });
  // vedúci alebo správca môže za zamestnanca požiadať o zneplatnenie duplicitného razenia (rozhoduje sa v Môj tím)
  const voidRequest = useVoidRequest();
  const d = q.data;
  return (
    <div className="mx-auto max-w-3xl bg-card p-6 print:p-0">
      <div className="no-print mb-4 flex flex-wrap items-center justify-between gap-3">
        <Link to="/tim" className="text-sm underline">← Späť na tím</Link>
        {/* výkaz za ľubovoľný mesiac: zmena mesiaca otvorí výkaz toho istého zamestnanca za iný mesiac */}
        <MonthPicker ym={{ y, m }} onChange={(v) => void navigate({ to: "/vykaz/$userId/$ym", params: { userId, ym: `${v.y}-${v.m}` } })} />
        <Button onClick={() => window.print()} disabled={!d}>Tlačiť</Button>
      </div>
      {!d && !q.error && <p className="text-muted-foreground">Načítavam…</p>}
      {!d && q.error && <p className="text-destructive">Nepodarilo sa načítať výkaz (ste offline?).</p>}
      {d && (
        <>
          <div className="mb-4 flex items-end justify-between border-b-2 border-foreground pb-2">
            <div>
              <div className="text-xs uppercase tracking-widest text-muted-foreground">Mesačný výkaz dochádzky</div>
              <div className="text-xl font-black">{personnelLabel(d.profile)}</div>
              <div className="text-sm">{d.profile?.department}</div>
            </div>
            <div className="text-right text-lg font-bold">{MONTHS[m - 1]} {y}</div>
          </div>
          {voidRequest.panel}
          <MonthTable data={d} compact onVoid={voidRequest.open} />
          <p className="mt-2 text-xs text-muted-foreground">K = záznam doplnený schválenou korekciou. {d.closedAt ? `Uzavreté ${new Date(d.closedAt).toLocaleDateString("sk-SK")}.` : "Mesiac nie je uzavretý."}</p>
          <div className="mt-16 grid grid-cols-2 gap-12 text-center text-sm">
            <div className="border-t border-foreground pt-1">Podpis zamestnanca</div>
            <div className="border-t border-foreground pt-1">Podpis vedúceho</div>
          </div>
        </>
      )}
    </div>
  );
}
