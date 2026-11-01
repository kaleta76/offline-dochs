import { useCallback, useEffect, useState } from "react";
import { ShieldCheck, ShieldAlert, KeyRound } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { getOrCreateDeviceKey, newDeviceKey, saveDeviceKey, type DeviceKey } from "@/lib/device";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

type Dev = { id: string; status: string; pairing_code: string | null; pairing_expires_at: string | null };

export function DeviceRegistration({ userId, online }: { userId: string; online: boolean }) {
  const [key, setKey] = useState<DeviceKey | null>(null);
  const [persisted, setPersisted] = useState(true);
  const [dev, setDev] = useState<Dev | null>(null);
  const [recovery, setRecovery] = useState<string | null>(null);
  const [mode, setMode] = useState<"none" | "recover">("none");
  const [code, setCode] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const [left, setLeft] = useState(0);

  const load = useCallback(async (k: DeviceKey) => {
    const { data, error } = await supabase.rpc("register_device", { _token_hash: k.hash, _ua_hint: navigator.userAgent });
    if (error) { setMsg(error.message); return; }
    const d = data?.[0] ?? null;
    if (d) setDev({ id: d.device_id, status: d.status, pairing_code: d.pairing_code, pairing_expires_at: d.pairing_expires_at });
    if (d && (d.status === "active" || d.status === "backup")) {
      const r = await supabase.rpc("claim_recovery_code", { _token_hash: k.hash });
      if (r.data) setRecovery(r.data);
    }
  }, []);

  useEffect(() => {
    let off = false;
    void getOrCreateDeviceKey(userId).then(({ key, persisted }) => { if (!off) { setKey(key); setPersisted(persisted); } });
    return () => { off = true; };
  }, [userId]);
  useEffect(() => { if (key && online) void load(key); }, [key, online, load]);
  // Poll while waiting for approval.
  useEffect(() => {
    if (!key || !online || dev?.status !== "pending") return;
    const iv = setInterval(() => void load(key), 15_000);
    return () => clearInterval(iv);
  }, [key, online, dev?.status, load]);
  useEffect(() => {
    if (!dev?.pairing_expires_at) return;
    const tick = () => setLeft(Math.max(0, Math.round((new Date(dev.pairing_expires_at!).getTime() - Date.now()) / 1000)));
    tick(); const iv = setInterval(tick, 1000); return () => clearInterval(iv);
  }, [dev?.pairing_expires_at]);
  useEffect(() => { if (key && dev?.status === "pending" && left === 0 && online) void load(key); }, [left]); // eslint-disable-line react-hooks/exhaustive-deps

  async function recover() {
    setMsg(null);
    const k = await newDeviceKey(userId);
    const { data, error } = await supabase.rpc("recover_device", { _recovery_code: code, _new_token_hash: k.hash, _ua_hint: navigator.userAgent });
    if (error) { setMsg(error.message); return; }
    if (!data) { setMsg("Záchranný kód nie je platný."); return; }
    await saveDeviceKey(k); setKey(k); setRecovery(data); setMode("none"); setCode("");
  }
  async function replace() {
    setMsg(null);
    if (dev && dev.status === "pending") await supabase.rpc("revoke_device", { _id: dev.id, _reason: "Nahradené žiadosťou o náhradu" });
    const k = await newDeviceKey(userId);
    const { error } = await supabase.rpc("register_device", { _token_hash: k.hash, _ua_hint: navigator.userAgent, _replace: true });
    if (error) { setMsg(error.message); return; }
    await saveDeviceKey(k); setKey(k);
  }

  if (recovery) {
    return (
      <div className="mb-6 rounded-sm border-2 border-foreground bg-card p-4">
        <div className="flex items-center gap-2 font-bold"><KeyRound className="h-5 w-5" /> Záchranný kód tohto zariadenia</div>
        <p className="mt-1 text-sm text-muted-foreground">Zobrazí sa iba raz. Uložte si ho – použijete ho po vymazaní prehliadača alebo na novom počítači.</p>
        <div className="num my-3 text-3xl font-black tracking-widest">{recovery}</div>
        <Button onClick={() => setRecovery(null)}>Uložil som si kód</Button>
      </div>
    );
  }
  if (!dev) return !online ? null : msg ? <p role="alert" className="mb-4 text-sm text-destructive">{msg}</p> : null;
  if (dev.status === "active" || dev.status === "backup") {
    return (
      <div className="mb-4 flex items-center gap-2 text-sm text-muted-foreground">
        <ShieldCheck className="h-4 w-4 text-success" /> Overené zariadenie{dev.status === "backup" ? " (záložné)" : ""}
        {!persisted && <span className="text-warning">· prehliadač nepotvrdil trvalé uloženie kľúča</span>}
      </div>
    );
  }
  return (
    <div className="mb-6 rounded-sm border-2 border-warning bg-card p-4">
      <div className="flex items-center gap-2 font-bold"><ShieldAlert className="h-5 w-5 text-warning" />
        {dev.status === "revoked" ? "Toto zariadenie bolo zrušené" : "Zariadenie čaká na schválenie"}</div>
      <p className="mt-1 text-sm text-muted-foreground">Pípať môžete aj teraz, záznamy sa však označia ako neoverené, kým ich vedúci nepotvrdí.</p>
      {dev.status === "pending" && (
        <div className="my-3 flex items-end gap-4">
          <div className="num text-5xl font-black tracking-[0.3em]">{dev.pairing_code}</div>
          <div className="num text-sm text-muted-foreground">platí ešte {Math.floor(left / 60)}:{String(left % 60).padStart(2, "0")}</div>
        </div>
      )}
      <p className="text-sm">Povedzte tento kód vedúcemu alebo správcovi.</p>
      {mode === "recover" ? (
        <div className="mt-3 flex flex-wrap gap-2">
          <Input className="max-w-56" placeholder="XXXX-XXXX-XXXX" value={code} onChange={(e) => setCode(e.target.value)} aria-label="Záchranný kód" />
          <Button onClick={recover} disabled={code.replace(/[^A-Za-z0-9]/g, "").length !== 12}>Obnoviť</Button>
          <Button variant="ghost" onClick={() => setMode("none")}>Zrušiť</Button>
        </div>
      ) : (
        <div className="mt-3 flex flex-wrap gap-2">
          <Button variant="outline" size="sm" onClick={() => setMode("recover")}>Mám záchranný kód</Button>
          <Button variant="outline" size="sm" onClick={replace}>Nahradiť pôvodné zariadenie</Button>
        </div>
      )}
      {msg && <p role="alert" className="mt-2 text-sm text-destructive">{msg}</p>}
    </div>
  );
}
