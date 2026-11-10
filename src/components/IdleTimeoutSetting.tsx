import { useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import {
  DEFAULT_IDLE_LIMIT_HOURS,
  IDLE_LIMIT_OPTIONS_HOURS,
  idleLimitLabel,
  mirrorOrganizationIdleLimit,
  parseIdleLimitHours,
} from "@/lib/idle-timeout";

const box = "rounded-sm border-2 border-foreground bg-card p-4";

/**
 * Odhlásenie pri nečinnosti pre celú organizáciu. Hodnotu nastavuje správca; ukladá sa v databáze
 * (organizations.idle_timeout_hours, funkcia set_idle_timeout) a platí na všetkých zariadeniach organizácie.
 * Fronta razení v zariadení sa odhlásením nemaže.
 */
export function IdleTimeoutSetting() {
  const { organization, refetchMe } = useAuth();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  // Bez migrácie 0012 databáza hodnotu nevracia: karta ostane vypnutá a limit je 12 hodín.
  const known = organization?.idle_timeout_hours !== undefined;
  const hours = parseIdleLimitHours(organization?.idle_timeout_hours) ?? DEFAULT_IDLE_LIMIT_HOURS;

  const change = async (value: string) => {
    const next = parseIdleLimitHours(value);
    if (next == null) return;
    setBusy(true);
    setMessage(null);
    const { error } = await supabase.rpc("set_idle_timeout", { _hours: next });
    if (error) {
      setMessage("Limit sa nepodarilo uložiť. Skúste to znova.");
    } else {
      mirrorOrganizationIdleLimit(next);
      refetchMe();
      setMessage("Uložené.");
    }
    setBusy(false);
  };

  return (
    <section className={box}>
      <h2 className="mb-3 text-sm font-bold uppercase tracking-widest">Odhlásenie pri nečinnosti</h2>
      <label className="flex flex-wrap items-center gap-3 text-sm">
        <span>Odhlásiť po nečinnosti dlhšej ako</span>
        <select
          className="h-9 rounded-sm border-2 border-foreground bg-background px-2 text-sm disabled:opacity-60"
          value={hours}
          disabled={!known || busy}
          onChange={(e) => void change(e.target.value)}
          aria-label="Doba nečinnosti do odhlásenia"
        >
          {IDLE_LIMIT_OPTIONS_HOURS.map((h) => (
            <option key={h} value={h}>
              {idleLimitLabel(h)}
              {h === DEFAULT_IDLE_LIMIT_HOURS ? " (predvolené)" : ""}
            </option>
          ))}
        </select>
      </label>
      <p className="mt-2 text-xs text-muted-foreground" role="status">
        {known
          ? "Platí pre všetky zariadenia a všetkých zamestnancov organizácie. Na ostatných zariadeniach sa prejaví pri ďalšom načítaní údajov o účte (návrat do okna alebo obnovenie stránky); zariadenie bez spojenia použije poslednú známu hodnotu. "
          : "Nastavenie sa sprístupní po aktualizácii databázy. Dovtedy platí 12 hodín. "}
        Za nečinnosť sa počíta čas bez klávesu, kliknutia alebo dotyku. Po odhlásení ostávajú razenia čakajúce vo fronte v zariadení a odošlú sa po ďalšom prihlásení.
        {message ? ` ${message}` : ""}
      </p>
    </section>
  );
}
