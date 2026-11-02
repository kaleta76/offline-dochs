import { personnelLabel } from "@/lib/personnel";
import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { labelOf } from "@/lib/month";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

const STATUS: Record<string, string> = { pending: "čaká", active: "primárne", backup: "záložné", revoked: "zrušené" };

export function DevicesPanel({ uid }: { uid: string }) {
  const qc = useQueryClient();
  const [filter, setFilter] = useState("");
  const [onlyPending, setOnlyPending] = useState(true);
  const devices = useQuery({
    queryKey: ["devices", uid],
    queryFn: async () => {
      const { data, error } = await supabase.from("devices")
        .select("id, user_id, status, pairing_code, pairing_expires_at, created_at, last_seen_at, user_agent_hint, replaces_device_id")
        .order("created_at", { ascending: false });
      if (error) throw error;
      const names = new Map(((await supabase.from("profiles").select("id, sap_id")).data ?? []).map((p) => [p.id, personnelLabel(p)]));
      return (data ?? []).map((d) => ({ ...d, name: names.get(d.user_id) ?? personnelLabel({ id: d.user_id, sap_id: null }) }));
    },
  });
  const unverified = useQuery({
    queryKey: ["unverified-punches", uid],
    queryFn: async () => {
      const { data, error } = await supabase.from("punches").select("id, user_id, code, direction, client_time")
        .eq("device_verification", "unverified").neq("user_id", uid).order("client_time", { ascending: false }).limit(100);
      if (error) throw error;
      const names = new Map(((await supabase.from("profiles").select("id, sap_id")).data ?? []).map((p) => [p.id, personnelLabel(p)]));
      return (data ?? []).map((p) => ({ ...p, name: names.get(p.user_id) ?? personnelLabel({ id: p.user_id, sap_id: null }) }));
    },
  });
  async function act(p: PromiseLike<{ error: { message: string } | null }>) {
    const { error } = await p;
    if (error) alert(error.message);
    void qc.invalidateQueries({ queryKey: ["devices"] });
    void qc.invalidateQueries({ queryKey: ["unverified-punches"] });
  }
  const list = (devices.data ?? []).filter((d) => (!onlyPending || d.status === "pending") &&
    (!filter || d.pairing_code?.includes(filter) || d.name.toLowerCase().includes(filter.toLowerCase())));

  return (
    <section className="space-y-6">
      <div>
        <h2 className="mb-2 text-sm font-bold uppercase tracking-widest">Zariadenia zamestnancov</h2>
        <div className="mb-2 flex flex-wrap items-center gap-3">
          <Input className="max-w-60" placeholder="Párovací kód alebo osobné číslo" value={filter} onChange={(e) => setFilter(e.target.value.trim())} />
          <label className="flex items-center gap-1.5 text-sm"><input type="checkbox" checked={onlyPending} onChange={(e) => setOnlyPending(e.target.checked)} /> iba čakajúce</label>
        </div>
        {list.length === 0 && <p className="text-sm text-muted-foreground">Žiadne zariadenia.</p>}
        <ul className="space-y-2">
          {list.map((d) => {
            const expired = d.pairing_expires_at && new Date(d.pairing_expires_at) < new Date();
            return (
              <li key={d.id} className="flex flex-wrap items-center gap-3 rounded-sm border-2 border-foreground bg-card px-3 py-2 text-sm">
                <span className="font-bold">{d.name}</span>
                <span className="rounded-sm bg-muted px-1.5 text-xs font-bold uppercase">{STATUS[d.status] ?? d.status}</span>
                {d.status === "pending" && d.pairing_code && <span className={`num font-black tracking-widest ${expired ? "text-muted-foreground line-through" : ""}`}>{d.pairing_code}</span>}
                {d.replaces_device_id && d.status === "pending" && <span className="text-xs text-warning">náhrada zariadenia</span>}
                <span className="flex-1 truncate text-xs text-muted-foreground">{d.user_agent_hint} · {d.last_seen_at ? `naposledy ${new Date(d.last_seen_at).toLocaleString("sk-SK")}` : `vytvorené ${new Date(d.created_at).toLocaleString("sk-SK")}`}</span>
                {d.status === "pending" && <>
                  <Button size="sm" onClick={() => act(supabase.rpc("approve_device", { _id: d.id, _as_backup: false }))}>Schváliť ako primárne</Button>
                  <Button size="sm" variant="outline" onClick={() => act(supabase.rpc("approve_device", { _id: d.id, _as_backup: true }))}>Ako záložné</Button>
                </>}
                {d.status !== "revoked" && <Button size="sm" variant="outline" onClick={() => {
                  const reason = prompt("Dôvod zrušenia (strata, výmena…)");
                  if (reason && reason.trim().length >= 3) void act(supabase.rpc("revoke_device", { _id: d.id, _reason: reason.trim() }));
                }}>Zrušiť</Button>}
              </li>
            );
          })}
        </ul>
      </div>
      <div>
        <h2 className="mb-2 text-sm font-bold uppercase tracking-widest">Pípnutia z neoverených zariadení</h2>
        {(unverified.data ?? []).length === 0 && <p className="text-sm text-muted-foreground">Žiadne na potvrdenie.</p>}
        <ul className="space-y-1.5">
          {(unverified.data ?? []).map((p) => (
            <li key={p.id} className="flex flex-wrap items-center gap-3 border-b border-border pb-1.5 text-sm">
              <span className="font-bold">{p.name}</span>
              <span>{labelOf(p.code, p.direction)} · <span className="num">{new Date(p.client_time).toLocaleString("sk-SK")}</span></span>
              <Button size="sm" variant="outline" className="ml-auto" onClick={() => act(supabase.rpc("confirm_unverified_punch", { _punch_id: p.id }))}>Potvrdiť</Button>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
