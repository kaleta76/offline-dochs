import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { loadMonth, MONTHS } from "@/lib/month";
import { MonthPicker } from "@/components/MonthTable";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export const Route = createFileRoute("/_authenticated/admin")({
  head: () => ({ meta: [{ title: "Správa – Dochádzka" }, { name: "description", content: "Pravidlá, číselníky, zamestnanci a SAP export." }] }),
  component: Admin,
});

const H = ({ children }: { children: React.ReactNode }) => <h2 className="mb-3 text-sm font-bold uppercase tracking-widest">{children}</h2>;
const box = "rounded-sm border-2 border-foreground bg-card p-4";

function Admin() {
  const { roles } = useAuth();
  const qc = useQueryClient();
  const settings = useQuery({ queryKey: ["settings"], queryFn: async () => (await supabase.from("settings").select("*").order("key")).data ?? [] });
  const codes = useQuery({ queryKey: ["codes"], queryFn: async () => (await supabase.from("absence_codes").select("*").order("sort")).data ?? [] });
  const holidays = useQuery({ queryKey: ["holidays"], queryFn: async () => (await supabase.from("holidays").select("*").order("day")).data ?? [] });
  const people = useQuery({
    queryKey: ["people"],
    queryFn: async () => {
      const [p, r] = await Promise.all([supabase.from("profiles").select("*").order("full_name"), supabase.from("user_roles").select("user_id, role")]);
      return (p.data ?? []).map((x) => ({ ...x, roles: (r.data ?? []).filter((y) => y.user_id === x.id).map((y) => y.role) }));
    },
  });
  const [newHol, setNewHol] = useState({ day: "", name: "" });
  const now = new Date();
  const [ym, setYm] = useState({ y: now.getFullYear(), m: now.getMonth() + 1 });
  const [exporting, setExporting] = useState(false);

  if (!roles.includes("admin")) return <p>Táto sekcia je iba pre správcu.</p>;

  const run = async (p: PromiseLike<{ error: { message: string } | null }>, key: string) => {
    const { error } = await p;
    if (error) alert(error.message);
    qc.invalidateQueries({ queryKey: [key] });
  };

  async function exportSap() {
    setExporting(true);
    try {
      const ExcelJS = (await import("exceljs")).default;
      const wb = new ExcelJS.Workbook();
      const ws = wb.addWorksheet(`${MONTHS[ym.m - 1]} ${ym.y}`);
      ws.columns = [
        { header: "SAP ID", key: "sap", width: 12 }, { header: "Meno", key: "name", width: 28 }, { header: "Stredisko", key: "dep", width: 16 },
        { header: "Mzdový druh", key: "wt", width: 12 }, { header: "Názov", key: "label", width: 30 }, { header: "Hodiny", key: "h", width: 10 },
        { header: "Uzavreté", key: "closed", width: 10 },
      ];
      ws.getRow(1).font = { bold: true };
      const codeMap = new Map((codes.data ?? []).map((c) => [c.code, c]));
      for (const p of people.data ?? []) {
        const m = await loadMonth(p.id, ym.y, ym.m);
        for (const [code, min] of Object.entries(m.byCode)) {
          const c = codeMap.get(code);
          ws.addRow({ sap: p.sap_id ?? "", name: p.full_name, dep: p.department ?? "", wt: c?.sap_code ?? code, label: c?.name ?? code, h: Math.round((min / 60) * 100) / 100, closed: m.closedAt ? "áno" : "NIE" });
        }
      }
      const buf = await wb.xlsx.writeBuffer();
      const url = URL.createObjectURL(new Blob([buf], { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }));
      const a = document.createElement("a");
      a.href = url; a.download = `SAP_export_${ym.y}_${String(ym.m).padStart(2, "0")}.xlsx`; a.click();
      URL.revokeObjectURL(url);
    } finally { setExporting(false); }
  }

  return (
    <div className="space-y-8">
      <h1 className="text-2xl font-black uppercase">Správa</h1>

      <section className={box}>
        <H>Export pre mzdovú účtáreň (SAP)</H>
        <div className="flex flex-wrap items-center gap-3">
          <MonthPicker ym={ym} onChange={setYm} />
          <Button onClick={exportSap} disabled={exporting}>{exporting ? "Pripravujem…" : "Stiahnuť .xlsx"}</Button>
          <span className="text-xs text-muted-foreground">Hodiny podľa mzdových druhov za každého zamestnanca.</span>
        </div>
      </section>

      <section className={box}>
        <H>Zamestnanci</H>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="border-b-2 border-foreground text-left text-xs uppercase"><th className="py-1">Meno</th><th>Stredisko</th><th>SAP ID</th><th>Fond h</th><th>Manažér</th><th>Roly</th></tr></thead>
            <tbody>
              {(people.data ?? []).map((p) => (
                <tr key={p.id} className="border-b border-border align-middle">
                  <td className="py-1.5 pr-2"><div className="font-semibold">{p.full_name}</div><div className="text-xs text-muted-foreground">{p.email}</div></td>
                  <td className="pr-2"><Input defaultValue={p.department ?? ""} onBlur={(e) => run(supabase.from("profiles").update({ department: e.target.value }).eq("id", p.id), "people")} /></td>
                  <td className="pr-2"><Input defaultValue={p.sap_id ?? ""} className="w-24" onBlur={(e) => run(supabase.from("profiles").update({ sap_id: e.target.value }).eq("id", p.id), "people")} /></td>
                  <td className="pr-2"><Input type="number" step="0.25" defaultValue={p.daily_fund} className="w-20" onBlur={(e) => run(supabase.from("profiles").update({ daily_fund: Number(e.target.value) }).eq("id", p.id), "people")} /></td>
                  <td className="pr-2">
                    <select className="h-9 rounded-sm border border-input bg-background px-2" value={p.manager_id ?? ""} onChange={(e) => run(supabase.from("profiles").update({ manager_id: e.target.value || null }).eq("id", p.id), "people")}>
                      <option value="">—</option>
                      {(people.data ?? []).filter((x) => x.id !== p.id).map((x) => <option key={x.id} value={x.id}>{x.full_name}</option>)}
                    </select>
                  </td>
                  <td className="whitespace-nowrap">
                    {(["manager", "admin"] as const).map((r) => (
                      <label key={r} className="mr-3 inline-flex items-center gap-1 text-xs">
                        <input type="checkbox" checked={p.roles.includes(r)} onChange={(e) => run(
                          e.target.checked ? supabase.from("user_roles").insert({ user_id: p.id, role: r }) : supabase.from("user_roles").delete().eq("user_id", p.id).eq("role", r),
                          "people")} />
                        {r === "manager" ? "manažér" : "správca"}
                      </label>
                    ))}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <div className="grid gap-8 lg:grid-cols-2">
        <section className={box}>
          <H>Pravidlá výpočtu</H>
          <div className="space-y-2">
            {(settings.data ?? []).map((s) => (
              <div key={s.key} className="grid grid-cols-[1fr_110px] items-center gap-2">
                <div><div className="num text-xs font-bold">{s.key}</div><div className="text-xs text-muted-foreground">{s.description}</div></div>
                <Input defaultValue={s.value} onBlur={(e) => e.target.value !== s.value && run(supabase.from("settings").update({ value: e.target.value }).eq("key", s.key), "settings")} />
              </div>
            ))}
          </div>
        </section>

        <div className="space-y-8">
          <section className={box}>
            <H>Číselník prerušení</H>
            {(codes.data ?? []).map((c) => (
              <div key={c.code} className="mb-1.5 grid grid-cols-[70px_80px_1fr] items-center gap-2">
                <span className="num text-xs font-bold">{c.code}</span>
                <Input defaultValue={c.sap_code} onBlur={(e) => run(supabase.from("absence_codes").update({ sap_code: e.target.value }).eq("code", c.code), "codes")} aria-label="SAP kód" />
                <Input defaultValue={c.name} onBlur={(e) => run(supabase.from("absence_codes").update({ name: e.target.value }).eq("code", c.code), "codes")} aria-label="Názov" />
              </div>
            ))}
          </section>

          <section className={box}>
            <H>Sviatky</H>
            <form className="mb-3 flex gap-2" onSubmit={(e) => { e.preventDefault(); run(supabase.from("holidays").insert(newHol), "holidays"); setNewHol({ day: "", name: "" }); }}>
              <Input type="date" required value={newHol.day} onChange={(e) => setNewHol({ ...newHol, day: e.target.value })} className="w-40" />
              <Input required placeholder="Názov" value={newHol.name} onChange={(e) => setNewHol({ ...newHol, name: e.target.value })} />
              <Button type="submit">Pridať</Button>
            </form>
            <ul className="max-h-64 space-y-1 overflow-y-auto text-sm">
              {(holidays.data ?? []).map((h) => (
                <li key={h.day} className="flex justify-between border-b border-border pb-1">
                  <span><span className="num">{new Date(h.day).toLocaleDateString("sk-SK")}</span> {h.name}</span>
                  <button className="text-xs text-destructive" onClick={() => run(supabase.from("holidays").delete().eq("day", h.day), "holidays")}>odstrániť</button>
                </li>
              ))}
            </ul>
          </section>
        </div>
      </div>
    </div>
  );
}
