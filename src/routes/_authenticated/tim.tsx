import { createFileRoute, Link } from "@tanstack/react-router";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { loadMonth, labelOf } from "@/lib/month";
import { fmtMin } from "@/lib/engine";
import { MonthPicker } from "@/components/MonthTable";
import { Button } from "@/components/ui/button";
import { DevicesPanel } from "@/components/DevicesPanel";

export const Route = createFileRoute("/_authenticated/tim")({
  head: () => ({ meta: [{ title: "Môj tím – Dochádzka" }, { name: "description", content: "Schvaľovanie korekcií a uzávierka mesiaca." }, { property: "og:title", content: "Môj tím – Dochádzka" }, { property: "og:description", content: "Schvaľovanie korekcií a uzávierka mesiaca." }, { property: "og:type", content: "website" }, { name: "twitter:card", content: "summary" }] }),
  component: Team,
});

function Team() {
  const { session, roles } = useAuth();
  const uid = session?.user.id;
  const isAdmin = roles.includes("admin");
  const now = new Date();
  const [ym, setYm] = useState({ y: now.getFullYear(), m: now.getMonth() + 1 });
  const qc = useQueryClient();

  const team = useQuery({
    queryKey: ["team", uid, isAdmin, ym.y, ym.m],
    enabled: !!uid,
    queryFn: async () => {
      let q = supabase.from("profiles").select("id, full_name, department").order("full_name");
      if (!isAdmin) q = q.eq("manager_id", uid!);
      const { data, error } = await q;
      if (error) throw error;
      return Promise.all((data ?? []).map(async (p) => ({ p, m: await loadMonth(p.id, ym.y, ym.m) })));
    },
  });

  const pending = useQuery({
    queryKey: ["pending-corr", uid],
    enabled: !!uid,
    queryFn: async () => {
      const { data } = await supabase.from("corrections").select("*").eq("status", "pending").neq("user_id", isAdmin ? "00000000-0000-0000-0000-000000000000" : uid!).order("at_time");
      const ids = [...new Set((data ?? []).map((c) => c.user_id))];
      const { data: ps } = ids.length ? await supabase.from("profiles").select("id, full_name").in("id", ids) : { data: [] };
      const names = new Map((ps ?? []).map((p) => [p.id, p.full_name]));
      return (data ?? []).map((c) => ({ ...c, name: names.get(c.user_id) ?? "?" }));
    },
  });

  const decide = useMutation({
    mutationFn: async ({ id, ok }: { id: string; ok: boolean }) => {
      const { error } = await supabase.rpc("decide_correction", { _id: id, _approve: ok });
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries(),
    onError: (e: Error) => alert(e.message),
  });
  const close = useMutation({
    mutationFn: async (userId: string) => {
      const { error } = await supabase.from("month_closures").insert({ user_id: userId, year: ym.y, month: ym.m, closed_by: uid! });
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ["team"] }),
    onError: (e: Error) => alert(e.message),
  });

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-black uppercase">Môj tím</h1>
        <MonthPicker ym={ym} onChange={setYm} />
      </div>

      <section>
        <h2 className="mb-2 text-sm font-bold uppercase tracking-widest">Korekcie na schválenie</h2>
        {(pending.data ?? []).length === 0 && <p className="text-sm text-muted-foreground">Žiadne čakajúce žiadosti.</p>}
        <ul className="space-y-2">
          {(pending.data ?? []).map((c) => (
            <li key={c.id} className="flex flex-wrap items-center gap-3 rounded-sm border-2 border-foreground bg-card px-3 py-2 text-sm">
              <span className="font-bold">{c.name}</span>
              <span>{labelOf(c.code, c.direction)} · <span className="num">{new Date(c.at_time).toLocaleString("sk-SK", { day: "numeric", month: "numeric", hour: "2-digit", minute: "2-digit" })}</span></span>
              <span className="flex-1 text-muted-foreground">„{c.reason}“</span>
              <Button size="sm" onClick={() => decide.mutate({ id: c.id, ok: true })}>Schváliť</Button>
              <Button size="sm" variant="outline" onClick={() => decide.mutate({ id: c.id, ok: false })}>Zamietnuť</Button>
            </li>
          ))}
        </ul>
      </section>

      {uid && <DevicesPanel uid={uid} />}

      <section>
        <h2 className="mb-2 text-sm font-bold uppercase tracking-widest">Prehľad mesiaca</h2>
        {team.isLoading && <p className="text-muted-foreground">Načítavam…</p>}
        {team.data?.length === 0 && <p className="text-sm text-muted-foreground">Nemáte priradených zamestnancov. Správca ich priradí v sekcii Správa.</p>}
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b-2 border-foreground text-left text-xs uppercase tracking-wider">
                <th className="py-2">Zamestnanec</th><th className="py-2 text-right">Spolu</th><th className="py-2 text-right">Saldo</th>
                <th className="py-2 text-center">Chýba odchod</th><th className="py-2 text-center">Offline odchýlky</th><th className="py-2 text-right">Akcie</th>
              </tr>
            </thead>
            <tbody>
              {(team.data ?? []).map(({ p, m }) => (
                <tr key={p.id} className="border-b border-border">
                  <td className="py-2"><div className="font-semibold">{p.full_name}</div><div className="text-xs text-muted-foreground">{p.department}</div></td>
                  <td className="num py-2 text-right">{fmtMin(m.totals.total)}</td>
                  <td className={`num py-2 text-right ${m.totals.balance < 0 ? "text-destructive" : "text-success"}`}>{fmtMin(m.totals.balance)}</td>
                  <td className={`py-2 text-center font-bold ${m.openDays ? "text-destructive" : ""}`}>{m.openDays}</td>
                  <td className={`py-2 text-center font-bold ${m.driftCount ? "text-warning-foreground" : ""}`}>{m.driftCount}</td>
                  <td className="py-2 text-right">
                    <div className="flex justify-end gap-2">
                      <Link to="/vykaz/$userId/$ym" params={{ userId: p.id, ym: `${ym.y}-${ym.m}` }} className="rounded-sm border-2 border-foreground px-2 py-1 text-xs font-bold">Výkaz A4</Link>
                      {m.closedAt ? (
                        <span className="rounded-sm bg-muted px-2 py-1 text-xs font-bold">Uzavretý</span>
                      ) : (
                        <Button size="sm" onClick={() => confirm(`Uzavrieť ${ym.m}/${ym.y} pre ${p.full_name}?`) && close.mutate(p.id)}>Uzavrieť</Button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}
