import { useEffect, useState } from "react";
import {
  DEFAULT_IDLE_LIMIT_HOURS,
  IDLE_LIMIT_OPTIONS_HOURS,
  idleLimitLabel,
  readIdleLimitHours,
  writeIdleLimitHours,
} from "@/lib/idle-timeout";

const box = "rounded-sm border-2 border-foreground bg-card p-4";

/**
 * Odhlásenie pri nečinnosti pre toto zariadenie. Hodnota sa ukladá v prehliadači (localStorage), nie v databáze:
 * platí len tu, kde ju správca nastaví. Fronta razení v zariadení sa odhlásením nemaže.
 */
export function IdleTimeoutSetting() {
  const [hours, setHours] = useState(DEFAULT_IDLE_LIMIT_HOURS);
  const [saved, setSaved] = useState(false);

  // localStorage existuje len v prehliadači, preto sa hodnota číta až po načítaní stránky.
  useEffect(() => {
    setHours(readIdleLimitHours());
  }, []);

  const change = (value: string) => {
    const next = Number(value);
    if (writeIdleLimitHours(next)) {
      setHours(next);
      setSaved(true);
    }
  };

  return (
    <section className={box}>
      <h2 className="mb-3 text-sm font-bold uppercase tracking-widest">Odhlásenie pri nečinnosti</h2>
      <label className="flex flex-wrap items-center gap-3 text-sm">
        <span>Odhlásiť po nečinnosti dlhšej ako</span>
        <select
          className="h-9 rounded-sm border-2 border-foreground bg-background px-2 text-sm"
          value={hours}
          onChange={(e) => change(e.target.value)}
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
        {saved ? "Uložené. " : ""}
        Nastavenie platí len pre toto zariadenie (prehliadač), iné zariadenia majú vlastné. Za nečinnosť sa počíta čas bez
        klávesu, kliknutia alebo dotyku. Po odhlásení ostávajú razenia čakajúce vo fronte v zariadení a odošlú sa po
        ďalšom prihlásení.
      </p>
    </section>
  );
}
