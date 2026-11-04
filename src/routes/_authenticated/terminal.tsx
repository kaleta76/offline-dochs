import { personnelLabel } from "@/lib/personnel";
import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { LogIn, LogOut, Stethoscope, Briefcase, Coffee, Users, CheckCircle2, CloudOff } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { enqueue, useQueue } from "@/lib/offline-queue";
import { Button } from "@/components/ui/button";
import { DeviceRegistration } from "@/components/DeviceRegistration";
import { dayKey, hm, labelOf } from "@/lib/month";
import { notHappenedYet } from "@/lib/presence";

export const Route = createFileRoute("/_authenticated/terminal")({
  head: () => ({ meta: [{ title: "Terminál – Dochádzka" }, { name: "description", content: "Záznam príchodu, odchodu a prerušení." }, { property: "og:title", content: "Terminál – Dochádzka" }, { property: "og:description", content: "Záznam príchodu, odchodu a prerušení." }, { property: "og:type", content: "website" }, { name: "twitter:card", content: "summary" }] }),
  component: Terminal,
});

const ACTIONS = [
  { code: "WORK", dir: "IN", label: "Príchod", icon: LogIn, cls: "bg-success text-success-foreground" },
  { code: "WORK", dir: "OUT", label: "Odchod", icon: LogOut, cls: "bg-secondary text-secondary-foreground" },
  { code: "DOCTOR", dir: "OUT", label: "Lekár", icon: Stethoscope, cls: "bg-card text-foreground border-2 border-foreground" },
  { code: "FAMILY", dir: "OUT", label: "Sprievod", icon: Users, cls: "bg-card text-foreground border-2 border-foreground" },
  { code: "TRIP", dir: "OUT", label: "Službka", icon: Briefcase, cls: "bg-card text-foreground border-2 border-foreground" },
  { code: "PRIV", dir: "OUT", label: "Súkromne", icon: Coffee, cls: "bg-card text-foreground border-2 border-foreground" },
] as const;

function Terminal() {
  const { session, profile } = useAuth();
  const { items, online } = useQueue(session?.user.id);
  const [busy, setBusy] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [now, setNow] = useState<Date | null>(null);
  const [confirm, setConfirm] = useState<{ label: string; time: Date; queued: boolean } | null>(null);
  const uid = session?.user.id;

  useEffect(() => {
    setNow(new Date());
    const iv = setInterval(() => setNow(new Date()), 1000);
    return () => clearInterval(iv);
  }, []);
  useEffect(() => {
    if (!confirm) return;
    const t = setTimeout(() => setConfirm(null), 3000);
    return () => clearTimeout(t);
  }, [confirm]);

  const today = useQuery({
    queryKey: ["today", uid, items.length],
    enabled: !!uid && online,
    queryFn: async () => {
      if (!uid) return [];
      const start = new Date(); start.setHours(0, 0, 0, 0);
      const { data, error } = await supabase.from("punches").select("client_uuid, code, direction, client_time, drift_minutes")
        .eq("user_id", uid).gte("client_time", start.toISOString()).order("client_time");
      if (error) throw error;
      return data;
    },
  });

  async function punch(a: (typeof ACTIONS)[number]) {
    if (!uid || busy) return;
    setBusy(true); setSaveError(null);
    try {
      const item = await enqueue({ user_id: uid, code: a.code, direction: a.dir });
      setConfirm({ label: a.label, time: new Date(item.client_time), queued: true });
    } catch { setSaveError('Záznam sa nepodarilo uložiť. Skúste znova; nezatvárajte aplikáciu.'); }
    finally { setBusy(false); }
  }

  const todayKey = dayKey(new Date());
  const list = [
    ...(today.data ?? []).map((p) => ({ id: p.client_uuid, code: p.code, dir: p.direction, time: new Date(p.client_time), pending: false, error: undefined as string | undefined })),
    ...items.filter((i) => dayKey(new Date(i.client_time)) === todayKey && !(today.data ?? []).some(p => p.client_uuid === i.client_uuid)).map((i) => ({ id: i.client_uuid, code: i.code, dir: i.direction, time: new Date(i.client_time), pending: true, error: i.error })),
  ]
    // schválené plánované razenie (napr. služobná cesta na zajtra) sa ukáže, až keď nastane
    .filter((p) => !notHappenedYet(p.time, now ?? new Date()))
    .sort((a, b) => a.time.getTime() - b.time.getTime());
  const last = list[list.length - 1];
  const atWork = last ? last.dir === "IN" : false;

  if (confirm) {
    return (
      <div className="flex min-h-[60vh] flex-col items-center justify-center gap-4 text-center">
        {confirm.queued ? <CloudOff className="h-20 w-20 text-warning" /> : <CheckCircle2 className="h-20 w-20 text-success" />}
        <div className="text-4xl font-black uppercase">{confirm.label}</div>
        <div className="num text-6xl font-bold">{hm(confirm.time)}</div>
        <div className="text-muted-foreground">{confirm.queued ? (online ? "Uložené v zariadení – čaká na potvrdenie serverom." : "Uložené v zariadení – odošle sa po pripojení.") : "Zaznamenané."}</div>
      </div>
    );
  }

  return (
    <div className="grid gap-8 lg:grid-cols-[1fr_320px]">
      <section>
        {uid && <DeviceRegistration userId={uid} online={online} />}
        <div className="mb-6 flex flex-wrap items-end justify-between gap-4 border-b-2 border-foreground pb-4">
          <div>
            <div className="text-sm font-semibold uppercase tracking-widest text-muted-foreground">Prihlásený</div>
            <div className="text-2xl font-black">{personnelLabel(profile)}</div>
            <div className={`mt-1 inline-block rounded-sm px-2 py-0.5 text-xs font-bold uppercase ${atWork ? "bg-success text-success-foreground" : "bg-muted text-muted-foreground"}`}>
              {atWork ? "Na pracovisku" : last ? `Mimo – ${labelOf(last.code, last.dir)}` : "Dnes bez záznamu"}
            </div>
          </div>
          <div className="text-right">
            <div className="num text-5xl font-bold leading-none sm:text-6xl">{now ? now.toLocaleTimeString("sk-SK") : "--:--:--"}</div>
            <div className="text-sm text-muted-foreground">{now?.toLocaleDateString("sk-SK", { weekday: "long", day: "numeric", month: "long" })}</div>
          </div>
        </div>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          {ACTIONS.map((a, i) => (
            <Button
              key={a.label}
              disabled={busy || !uid}
              onClick={() => punch(a)}
              className={`h-auto flex flex-col items-center justify-center gap-2 rounded-sm px-4 py-8 text-xl font-black uppercase tracking-wide shadow-[4px_4px_0_0_var(--foreground)] transition active:translate-x-1 active:translate-y-1 active:shadow-none ${a.cls} ${i < 2 ? "sm:py-12" : ""}`}
            >
              <a.icon className="h-9 w-9" />
              {a.label}
            </Button>
          ))}
        </div>
        {saveError && <p role="alert" className="mt-3 text-destructive">{saveError}</p>}
      </section>
      <aside className="rounded-sm border-2 border-foreground bg-card p-4">
        <h2 className="mb-3 text-sm font-bold uppercase tracking-widest">Dnešné záznamy</h2>
        {list.length === 0 && <p className="text-sm text-muted-foreground">Zatiaľ nič.</p>}
        <ul className="space-y-1.5">
          {list.map((p) => (
            <li key={p.id} className="flex items-center justify-between gap-2 border-b border-border pb-1.5 text-sm">
              <span className="font-semibold">{labelOf(p.code, p.dir)}</span>
              <span className="flex items-center gap-2">
                {p.pending && <span className="rounded-sm bg-warning px-1.5 text-[10px] font-bold uppercase text-warning-foreground">čaká</span>}
                <span className="num">{hm(p.time)}</span>
              </span>
              {p.error && (
                <span className="w-full text-xs text-destructive">
                  {p.error}
                </span>
              )}
            </li>
          ))}
        </ul>
      </aside>
    </div>
  );
}
