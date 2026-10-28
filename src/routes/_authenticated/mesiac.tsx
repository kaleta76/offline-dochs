import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { loadMonth, labelOf } from "@/lib/month";
import { MonthPicker, MonthTable } from "@/components/MonthTable";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";

export const Route = createFileRoute("/_authenticated/mesiac")({
  head: () => ({ meta: [{ title: "Môj mesiac – Dochádzka" }, { name: "description", content: "Mesačný prehľad odpracovaného času a korekcie." }, { property: "og:title", content: "Môj mesiac – Dochádzka" }, { property: "og:description", content: "Mesačný prehľad odpracovaného času a korekcie." }, { property: "og:type", content: "website" }, { name: "twitter:card", content: "summary" }] }),
  component: MyMonth,
});

const TYPES = ["WORK:IN", "WORK:OUT", "DOCTOR:OUT", "FAMILY:OUT", "TRIP:OUT", "PRIV:OUT", "LEAVE:OUT", "SICK:OUT"];
const STATUS: Record<string, string> = { pending: "čaká", approved: "schválená", rejected: "zamietnutá" };

function MyMonth() {
  const { session } = useAuth();
  const uid = session?.user.id;
  const now = new Date();
  const [ym, setYm] = useState({ y: now.getFullYear(), m: now.getMonth() + 1 });
  const qc = useQueryClient();
  const month = useQuery({ queryKey: ["month", uid, ym.y, ym.m], enabled: !!uid, queryFn: () => loadMonth(uid!, ym.y, ym.m) });
  const corr = useQuery({
    queryKey: ["corr", uid],
    enabled: !!uid,
    queryFn: async () => (await supabase.from("corrections").select("*").eq("user_id", uid!).order("created_at", { ascending: false }).limit(20)).data ?? [],
  });

  const [form, setForm] = useState({ date: "", time: "", type: "WORK:IN", reason: "" });
  const [msg, setMsg] = useState<string | null>(null);
  const submit = useMutation({
    mutationFn: async () => {
      const [code = "WORK", direction = "IN"] = form.type.split(":");
      const at = new Date(`${form.date}T${form.time || "08:00"}:00`);
      const { error } = await supabase.from("corrections").insert({ user_id: uid!, code, direction, at_time: at.toISOString(), reason: form.reason.trim() });
      if (error) throw error;
    },
    onSuccess: () => { setMsg("Žiadosť odoslaná manažérovi."); setForm({ ...form, reason: "" }); qc.invalidateQueries({ queryKey: ["corr"] }); },
    onError: (e: Error) => setMsg(e.message.includes("row-level") ? "Mesiac je uzavretý." : e.message),
  });

  return (
    <div className="grid gap-8 lg:grid-cols-[1fr_300px]">
      <section>
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
          <h1 className="text-2xl font-black uppercase">Môj mesiac</h1>
          <MonthPicker ym={ym} onChange={setYm} />
        </div>
        {month.data?.closedAt && <p className="mb-3 rounded-sm bg-muted px-3 py-2 text-sm font-semibold">Mesiac je uzavretý manažérom.</p>}
        {month.isLoading && <p className="text-muted-foreground">Načítavam…</p>}
        {month.error && <p className="text-destructive">Nepodarilo sa načítať (ste offline?).</p>}
        {month.data && <MonthTable data={month.data} />}
      </section>
      <aside className="space-y-6">
        <form
          className="space-y-3 rounded-sm border-2 border-foreground bg-card p-4"
          onSubmit={(e) => { e.preventDefault(); setMsg(null); submit.mutate(); }}
        >
          <h2 className="text-sm font-bold uppercase tracking-widest">Žiadosť o korekciu</h2>
          <div className="grid grid-cols-2 gap-2">
            <Input type="date" required value={form.date} onChange={(e) => setForm({ ...form, date: e.target.value })} aria-label="Dátum" />
            <Input type="time" required value={form.time} onChange={(e) => setForm({ ...form, time: e.target.value })} aria-label="Čas" />
          </div>
          <select className="h-9 w-full rounded-sm border border-input bg-background px-2 text-sm" value={form.type} onChange={(e) => setForm({ ...form, type: e.target.value })} aria-label="Typ">
            {TYPES.map((t) => { const [c = "", d = ""] = t.split(":"); return <option key={t} value={t}>{labelOf(c, d)}</option>; })}
          </select>
          <Textarea required minLength={3} maxLength={500} placeholder="Dôvod (napr. zabudnutý odchod)" value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} />
          <Button type="submit" className="w-full" disabled={submit.isPending}>Odoslať</Button>
          {msg && <p className="text-sm">{msg}</p>}
        </form>
        <div>
          <h2 className="mb-2 text-sm font-bold uppercase tracking-widest">Moje žiadosti</h2>
          <ul className="space-y-1 text-sm">
            {(corr.data ?? []).map((c) => (
              <li key={c.id} className="flex justify-between border-b border-border pb-1">
                <span>{new Date(c.at_time).toLocaleString("sk-SK", { day: "numeric", month: "numeric", hour: "2-digit", minute: "2-digit" })} · {labelOf(c.code, c.direction)}</span>
                <span className={c.status === "approved" ? "text-success" : c.status === "rejected" ? "text-destructive" : "text-muted-foreground"}>{STATUS[c.status]}</span>
              </li>
            ))}
          </ul>
        </div>
      </aside>
    </div>
  );
}
