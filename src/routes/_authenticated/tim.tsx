import { personnelLabel } from "@/lib/personnel";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { loadMonth, labelOf, hm } from "@/lib/month";
import { unverifiedSummary } from "@/lib/device-trace";
import { fmtMin } from "@/lib/engine";
import { presenceOf, summarizePresence, type Presence } from "@/lib/presence";
import { MonthPicker } from "@/components/MonthTable";
import { Button } from "@/components/ui/button";
import { DevicesPanel } from "@/components/DevicesPanel";

export const Route = createFileRoute("/_authenticated/tim")({
  head: () => ({ meta: [{ title: "Môj tím – Dochádzka" }, { name: "description", content: "Schvaľovanie korekcií a uzávierka mesiaca." }, { property: "og:title", content: "Môj tím – Dochádzka" }, { property: "og:description", content: "Schvaľovanie korekcií a uzávierka mesiaca." }, { property: "og:type", content: "website" }, { name: "twitter:card", content: "summary" }] }),
  component: Team,
});

/** Stav zamestnanca teraz; undefined = ešte sa nenačítalo. Text nesie význam, farba je len doplnok. */
function PresenceBadge({ presence }: { presence: Presence | undefined }) {
  if (!presence) return <span className="text-xs text-muted-foreground">…</span>;
  const at = presence.since ? hm(presence.since) : "";
  if (presence.state === "none") return <span className="text-xs text-muted-foreground">bez razenia</span>;
  if (presence.state === "in") return <span className="whitespace-nowrap rounded-sm bg-success px-2 py-1 text-xs font-bold text-success-foreground">Prítomný · od {at}</span>;
  if (presence.state === "away") return <span className="whitespace-nowrap rounded-sm bg-warning px-2 py-1 text-xs font-bold text-warning-foreground">{labelOf(presence.code ?? "", "OUT")} · od {at}</span>;
  return <span className="whitespace-nowrap rounded-sm bg-muted px-2 py-1 text-xs font-bold">Odišiel · {at}</span>;
}

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
      if (!uid) throw new Error("Prihlásenie je potrebné.");
      let q = supabase.from("profiles").select("id, sap_id, department").order("sap_id");
      if (!isAdmin) q = q.eq("manager_id", uid);
      const { data, error } = await q;
      if (error) throw error;
      return Promise.all((data ?? []).map(async (p) => ({ p, m: await loadMonth(p.id, ym.y, ym.m) })));
    },
  });

  // Kto je teraz v práci: dnešné razenia tímu (rovnaké oprávnenia ako Prehľad mesiaca). Čas sa berie pri každom načítaní,
  // aby stránka nechaná otvorenú cez polnoc nezostala na včerajšku. Obnovuje sa každú minútu.
  const teamIds = (team.data ?? []).map(({ p }) => p.id);
  const presence = useQuery({
    queryKey: ["presence", teamIds.join(",")],
    enabled: teamIds.length > 0,
    refetchInterval: 60_000,
    queryFn: async () => {
      const start = new Date();
      start.setHours(0, 0, 0, 0);
      const { data, error } = await supabase
        .from("punches")
        .select("user_id, code, direction, client_time, voided_at")
        .in("user_id", teamIds)
        .gte("client_time", start.toISOString())
        .order("client_time");
      if (error) throw error;
      const byUser = new Map<string, Presence>();
      for (const id of teamIds) {
        const own = (data ?? []).filter((r) => r.user_id === id);
        byUser.set(id, presenceOf(own.map((r) => ({ code: r.code, direction: r.direction as "IN" | "OUT", time: new Date(r.client_time), voided: !!r.voided_at }))));
      }
      return byUser;
    },
  });
  const presenceSummary = presence.data ? summarizePresence([...presence.data.values()]) : null;

  const pending = useQuery({
    queryKey: ["pending-corr", uid],
    enabled: !!uid,
    queryFn: async () => {
      if (!uid) throw new Error("Prihlásenie je potrebné.");
      const { data } = await supabase.from("corrections").select("*").eq("status", "pending").neq("user_id", isAdmin ? "00000000-0000-0000-0000-000000000000" : uid).order("at_time");
      const ids = [...new Set((data ?? []).map((c) => c.user_id))];
      const { data: ps } = ids.length ? await supabase.from("profiles").select("id, sap_id").in("id", ids) : { data: [] };
      const names = new Map((ps ?? []).map((p) => [p.id, personnelLabel(p)]));
      return (data ?? []).map((c) => ({ ...c, name: names.get(c.user_id) ?? "?" }));
    },
  });

  const pendingVoids = useQuery({
    queryKey: ["pending-voids", uid],
    enabled: !!uid,
    queryFn: async () => {
      if (!uid) throw new Error("Prihlásenie je potrebné.");
      const { data, error } = await supabase
        .from("punch_void_requests")
        .select("*")
        .eq("status", "pending")
        .neq("user_id", isAdmin ? "00000000-0000-0000-0000-000000000000" : uid)
        .order("created_at");
      if (error) throw error;
      const rows = data ?? [];
      const punchIds = rows.map((r) => r.punch_id);
      const userIds = [...new Set(rows.map((r) => r.user_id))];
      const { data: pun } = punchIds.length ? await supabase.from("punches").select("id, code, direction, client_time").in("id", punchIds) : { data: [] };
      const { data: ps } = userIds.length ? await supabase.from("profiles").select("id, sap_id").in("id", userIds) : { data: [] };
      const punchById = new Map((pun ?? []).map((x) => [x.id, x]));
      const names = new Map((ps ?? []).map((x) => [x.id, personnelLabel(x)]));
      return rows.map((r) => ({ ...r, punch: punchById.get(r.punch_id) ?? null, name: names.get(r.user_id) ?? "?" }));
    },
  });
  const decideVoid = useMutation({
    mutationFn: async ({ id, ok }: { id: string; ok: boolean }) => {
      const { error } = await supabase.rpc("decide_punch_void", { _id: id, _approve: ok });
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries(),
    onError: (e: Error) => alert(e.message),
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
      if (!uid) throw new Error("Prihlásenie je potrebné.");
      const { error } = await supabase.from("month_closures").insert({ user_id: userId, year: ym.y, month: ym.m, closed_by: uid });
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

      <section>
        <h2 className="mb-2 text-sm font-bold uppercase tracking-widest">Žiadosti o zneplatnenie razenia</h2>
        {(pendingVoids.data ?? []).length === 0 && <p className="text-sm text-muted-foreground">Žiadne čakajúce žiadosti.</p>}
        <ul className="space-y-2">
          {(pendingVoids.data ?? []).map((v) => (
            <li key={v.id} className="flex flex-wrap items-center gap-3 rounded-sm border-2 border-foreground bg-card px-3 py-2 text-sm">
              <span className="font-bold">{v.name}</span>
              <span>
                {v.punch ? labelOf(v.punch.code, v.punch.direction) : "razenie"} ·{" "}
                <span className="num">{v.punch ? new Date(v.punch.client_time).toLocaleString("sk-SK", { day: "numeric", month: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" }) : ""}</span>
              </span>
              <span className="flex-1 text-muted-foreground">„{v.reason}“</span>
              <Button size="sm" onClick={() => decideVoid.mutate({ id: v.id, ok: true })}>Zneplatniť razenie</Button>
              <Button size="sm" variant="outline" onClick={() => decideVoid.mutate({ id: v.id, ok: false })}>Zamietnuť</Button>
            </li>
          ))}
        </ul>
        <p className="mt-2 text-xs text-muted-foreground">Zneplatnené razenie ostáva v zázname (nemaže sa), ale nepočíta sa do dochádzky a do Accessu ide v zozname zneplatnených razení.</p>
      </section>

      {uid && <DevicesPanel uid={uid} />}

      <section>
        <h2 className="mb-2 text-sm font-bold uppercase tracking-widest">Prehľad mesiaca</h2>
        {presenceSummary && (
          <div role="status" className="mb-3 text-sm">
            <span className="font-bold">Teraz v práci: {presenceSummary.in} z {presenceSummary.total}</span>
            {presenceSummary.away > 0 && <> · mimo pracoviska {presenceSummary.away}</>}
            {presenceSummary.out > 0 && <> · odišlo {presenceSummary.out}</>}
            {presenceSummary.none > 0 && <> · dnes bez razenia {presenceSummary.none}</>}
            <span className="block text-xs text-muted-foreground">Stĺpec Teraz platí pre dnešok bez ohľadu na zvolený mesiac. Berie len razenia, ktoré už dorazili na server (razenia z offline terminálov sa ukážu po synchronizácii). Obnovuje sa každú minútu.</span>
          </div>
        )}
        {presence.isError && <p className="mb-3 text-sm text-muted-foreground">Stav „Teraz“ sa nepodarilo načítať (ste offline?).</p>}
        {team.isLoading && <p className="text-muted-foreground">Načítavam…</p>}
        {team.data?.length === 0 && <p className="text-sm text-muted-foreground">Nemáte priradených zamestnancov. Správca ich priradí v sekcii Správa.</p>}
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b-2 border-foreground text-left text-xs uppercase tracking-wider">
                <th className="py-2">Zamestnanec</th><th className="py-2">Teraz</th><th className="py-2 text-right">Spolu</th><th className="py-2 text-right">Saldo</th>
                <th className="py-2 text-center">Chýba odchod</th><th className="py-2 text-center">Offline odchýlky</th><th className="py-2 text-center">Neoverené</th><th className="py-2 text-right">Akcie</th>
              </tr>
            </thead>
            <tbody>
              {(team.data ?? []).map(({ p, m }) => (
                <tr key={p.id} className="border-b border-border">
                  <td className="py-2"><div className="font-semibold">{personnelLabel(p)}</div><div className="text-xs text-muted-foreground">{p.department}</div></td>
                  <td className="py-2"><PresenceBadge presence={presence.data?.get(p.id)} /></td>
                  <td className="num py-2 text-right">{fmtMin(m.totals.total)}</td>
                  <td className={`num py-2 text-right ${m.totals.balance < 0 ? "text-destructive" : "text-success"}`}>{fmtMin(m.totals.balance)}</td>
                  <td className={`py-2 text-center font-bold ${m.openDays ? "text-destructive" : ""}`}>{m.openDays}</td>
                  <td className={`py-2 text-center font-bold ${m.driftCount ? "text-warning-foreground" : ""}`}>{m.driftCount}</td>
                  <td className={`py-2 text-center font-bold ${m.unverifiedCount ? "text-warning-foreground" : ""}`}>{m.unverifiedCount}</td>
                  <td className="py-2 text-right">
                    <div className="flex justify-end gap-2">
                      <Link to="/vykaz/$userId/$ym" params={{ userId: p.id, ym: `${ym.y}-${ym.m}` }} className="rounded-sm border-2 border-foreground px-2 py-1 text-xs font-bold">Výkaz A4</Link>
                      {m.closedAt ? (
                        <span className="rounded-sm bg-muted px-2 py-1 text-xs font-bold">Uzavretý</span>
                      ) : (
                        <Button size="sm" onClick={() => confirm(`Uzavrieť ${ym.m}/${ym.y} pre ${personnelLabel(p)}?${m.unverifiedCount ? `\n\nPozor: ${unverifiedSummary(m.unverifiedCount)}` : ""}`) && close.mutate(p.id)}>Uzavrieť</Button>
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
