import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { loadMonth, MONTHS } from "@/lib/month";
import { MonthTable } from "@/components/MonthTable";
import { Button } from "@/components/ui/button";

export const Route = createFileRoute("/_authenticated/vykaz/$userId/$ym")({
  head: () => ({ meta: [{ title: "Mesačný výkaz – Dochádzka" }, { name: "description", content: "Mesačný výkaz dochádzky na podpis." }] }),
  component: Report,
});

function Report() {
  const { userId, ym } = Route.useParams();
  const [y = 2026, m = 1] = ym.split("-").map(Number);
  const q = useQuery({ queryKey: ["month", userId, y, m], queryFn: () => loadMonth(userId, y, m) });
  if (!q.data) return <p className="text-muted-foreground">Načítavam…</p>;
  const d = q.data;
  return (
    <div className="mx-auto max-w-3xl bg-card p-6 print:p-0">
      <div className="no-print mb-4 flex justify-between">
        <Link to="/tim" className="text-sm underline">← Späť na tím</Link>
        <Button onClick={() => window.print()}>Tlačiť</Button>
      </div>
      <div className="mb-4 flex items-end justify-between border-b-2 border-foreground pb-2">
        <div>
          <div className="text-xs uppercase tracking-widest text-muted-foreground">Mesačný výkaz dochádzky</div>
          <div className="text-xl font-black">{d.profile?.full_name}</div>
          <div className="text-sm">{d.profile?.department} {d.profile?.sap_id && `· SAP ${d.profile.sap_id}`}</div>
        </div>
        <div className="text-right text-lg font-bold">{MONTHS[m - 1]} {y}</div>
      </div>
      <MonthTable data={d} compact />
      <p className="mt-2 text-xs text-muted-foreground">K = záznam doplnený schválenou korekciou. {d.closedAt ? `Uzavreté ${new Date(d.closedAt).toLocaleDateString("sk-SK")}.` : "Mesiac nie je uzavretý."}</p>
      <div className="mt-16 grid grid-cols-2 gap-12 text-center text-sm">
        <div className="border-t border-foreground pt-1">Podpis zamestnanca</div>
        <div className="border-t border-foreground pt-1">Podpis vedúceho</div>
      </div>
    </div>
  );
}
