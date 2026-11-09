import { useCallback, useEffect, useRef, useState } from "react";
import { ShieldCheck, ShieldAlert } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { ensurePersistent, getOrCreateDeviceKey, newDeviceKey, saveDeviceKey, type DeviceKey } from "@/lib/device";
import { deviceLabel } from "@/lib/device-trace";
import { Button } from "@/components/ui/button";

type Dev = { id: string; status: string; pairing_code: string | null; pairing_expires_at: string | null };

// Záchranný kód zariadenia sa zámerne nezobrazuje (docs/OVERENIE-ZARIADENI.md): kto ho pozná, získa bez vedúceho overené
// zariadenie na inom počítači alebo mobile. Po vymazaní údajov prehliadača alebo na novom zariadení sa zariadenie
// zaregistruje znova („Nahradiť pôvodné zariadenie“) a schváli ho vedúci. Pípať sa dá aj dovtedy, razenia sú označené „neoverené“.
export function DeviceRegistration({ userId, online }: { userId: string; online: boolean }) {
  const [key, setKey] = useState<DeviceKey | null>(null);
  const [persisted, setPersisted] = useState(true);
  const [asking, setAsking] = useState(false);
  const [retried, setRetried] = useState(false);
  const prevStatus = useRef<string | null>(null);
  const [dev, setDev] = useState<Dev | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [left, setLeft] = useState(0);

  const load = useCallback(async (k: DeviceKey) => {
    const { data, error } = await supabase.rpc("register_device", { _token_hash: k.hash, _ua_hint: navigator.userAgent });
    if (error) { setMsg(error.message); return; }
    const d = data?.[0] ?? null;
    if (d) setDev({ id: d.device_id, status: d.status, pairing_code: d.pairing_code, pairing_expires_at: d.pairing_expires_at });
    if (d && (d.status === "active" || d.status === "backup")) {
      // Vyzdvihnutie len vymaže kód uložený na serveri po schválení. Výsledok zámerne zahadzujeme a nikde sa nezobrazí.
      // Kým migrácia nevypne obnovu záchranným kódom, je to najmenší zásah bez zmeny databázy.
      await supabase.rpc("claim_recovery_code", { _token_hash: k.hash });
    }
  }, []);

  useEffect(() => {
    let off = false;
    void getOrCreateDeviceKey(userId).then(({ key, persisted }) => { if (!off) { setKey(key); setPersisted(persisted); } });
    return () => { off = true; };
  }, [userId]);
  useEffect(() => { if (key && online) void load(key); }, [key, online, load]);
  // Čakanie na schválenie bez pravidelného dopytovania: stav sa overí pri načítaní, pri návrate do aplikácie
  // (karta znova viditeľná / okno získa fokus) alebo tlačidlom „Skontrolovať stav“.
  useEffect(() => {
    if (!key || !online || dev?.status !== "pending") return;
    let last = 0;
    const recheck = () => {
      if (document.visibilityState !== "visible") return;
      const now = Date.now();
      if (now - last < 2_000) return; // focus a visibilitychange prichádzajú spolu – stačí jeden dopyt
      last = now;
      void load(key);
    };
    document.addEventListener("visibilitychange", recheck);
    window.addEventListener("focus", recheck);
    return () => {
      document.removeEventListener("visibilitychange", recheck);
      window.removeEventListener("focus", recheck);
    };
  }, [key, online, dev?.status, load]);
  const [checking, setChecking] = useState(false);
  async function checkNow() {
    if (!key) return;
    setChecking(true);
    try {
      await load(key);
    } finally {
      setChecking(false);
    }
  }
  useEffect(() => {
    if (!dev?.pairing_expires_at) return;
    const tick = () => setLeft(Math.max(0, Math.round((new Date(dev.pairing_expires_at!).getTime() - Date.now()) / 1000)));
    tick(); const iv = setInterval(tick, 1000); return () => clearInterval(iv);
  }, [dev?.pairing_expires_at]);
  useEffect(() => { if (key && dev?.status === "pending" && left === 0 && online) void load(key); }, [left]); // eslint-disable-line react-hooks/exhaustive-deps

  // Chrome rozhoduje o trvalom uložení potichu a odpoveď sa mení (záložka, inštalácia, návštevnosť), preto sa po schválení
  // zariadenia a na požiadanie opýtame znova. Pri načítaní sa pýta už getOrCreateDeviceKey.
  useEffect(() => {
    const s = dev?.status ?? null;
    if (prevStatus.current === "pending" && (s === "active" || s === "backup")) void ensurePersistent().then(setPersisted);
    prevStatus.current = s;
  }, [dev?.status]);

  async function retryPersist() {
    setAsking(true);
    try { setPersisted(await ensurePersistent()); setRetried(true); } finally { setAsking(false); }
  }

  async function replace() {
    setMsg(null);
    if (dev && dev.status === "pending") await supabase.rpc("revoke_device", { _id: dev.id, _reason: "Nahradené žiadosťou o náhradu" });
    const k = await newDeviceKey(userId);
    const { error } = await supabase.rpc("register_device", { _token_hash: k.hash, _ua_hint: navigator.userAgent, _replace: true });
    if (error) { setMsg(error.message); return; }
    setPersisted(await saveDeviceKey(k)); setKey(k);
  }

  if (!dev) return !online ? null : msg ? <p role="alert" className="mb-4 text-sm text-destructive">{msg}</p> : null;
  const label = deviceLabel(dev.id);
  if (dev.status === "active" || dev.status === "backup") {
    return (
      <div className="mb-4 text-sm text-muted-foreground">
        <div className="flex items-center gap-2">
          <ShieldCheck className="h-4 w-4 text-success" /> Overené zariadenie{dev.status === "backup" ? " (záložné)" : ""}
          {label && <span className="num font-bold" title="Označenie tohto zariadenia. Vedúci ho vidí v zozname zariadení.">· {label}</span>}
        </div>
        {!persisted && (
          <p className="mt-1" role="status">
            <span className="font-bold text-warning">Kľúč zariadenia je uložený, prehliadač však zatiaľ nezaručil, že ho nezmaže.</span>{" "}
            Pridajte túto stránku medzi záložky (Ctrl+D) alebo ju nainštalujte ako aplikáciu a stlačte{" "}
            <Button variant="link" size="sm" className="h-auto p-0 align-baseline" onClick={retryPersist} disabled={asking}>Skúsiť znova</Button>.
            {retried && !asking && " Prehliadač to stále odmieta."}{" "}
            Ak by sa kľúč stratil, zariadenie sa zaregistruje znova a schváli ho vedúci. Pípať sa dá aj dovtedy.
          </p>
        )}
      </div>
    );
  }
  return (
    <div className="mb-6 rounded-sm border-2 border-warning bg-card p-4">
      <div className="flex items-center gap-2 font-bold"><ShieldAlert className="h-5 w-5 text-warning" />
        {dev.status === "revoked" ? "Toto zariadenie bolo zrušené" : "Zariadenie čaká na schválenie"}
        {label && <span className="num text-sm font-bold text-muted-foreground">· {label}</span>}</div>
      <p className="mt-1 text-sm text-muted-foreground">Pípať môžete aj teraz, záznamy sa však označia ako neoverené, kým ich vedúci nepotvrdí.</p>
      {dev.status === "pending" && (
        <div className="my-3 flex items-end gap-4">
          <div className="num text-5xl font-black tracking-[0.3em]">{dev.pairing_code}</div>
          <div className="num text-sm text-muted-foreground">platí ešte {Math.floor(left / 60)}:{String(left % 60).padStart(2, "0")}</div>
        </div>
      )}
      <p className="text-sm">Povedzte tento kód{label ? ` a označenie ${label}` : ""} vedúcemu alebo správcovi.</p>
      <p className="mt-2 text-sm text-muted-foreground">Po vymazaní údajov prehliadača alebo pri novom zariadení použite „Nahradiť pôvodné zariadenie“. Nové zariadenie schváli vedúci.</p>
      <div className="mt-3 flex flex-wrap gap-2">
        {dev.status === "pending" && online && (
          <Button variant="outline" size="sm" onClick={checkNow} disabled={checking}>
            Skontrolovať stav
          </Button>
        )}
        <Button variant="outline" size="sm" onClick={replace}>Nahradiť pôvodné zariadenie</Button>
      </div>
      {msg && <p role="alert" className="mt-2 text-sm text-destructive">{msg}</p>}
    </div>
  );
}
