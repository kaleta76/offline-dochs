// Prevody medzi miestnym časom v časovom pásme a UTC. Čisté funkcie bez závislostí.

/** Rozdiel (ms) medzi miestnym časom v pásme a UTC v danom okamihu. */
export function zoneOffsetMs(utcMs: number, tz: string): number {
  const sec = Math.floor(utcMs / 1000) * 1000;
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(sec));
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
  const asUtc = Date.UTC(
    get("year"),
    get("month") - 1,
    get("day"),
    get("hour"),
    get("minute"),
    get("second"),
  );
  return asUtc - sec;
}

/**
 * Okamih (UTC) pre miestny dátum a čas v pásme. Vráti null, ak taký čas v pásme neexistuje
 * (preskočená hodina pri prechode na letný čas). Pri opakovanej hodine (prechod na zimný čas)
 * sa vyberie prvý výskyt (letný čas).
 */
export function localToUtc(
  y: number,
  mo: number,
  d: number,
  h: number,
  mi: number,
  s: number,
  tz: string,
): Date | null {
  const naive = Date.UTC(y, mo - 1, d, h, mi, s);
  const guess = naive - zoneOffsetMs(naive, tz);
  const utc = naive - zoneOffsetMs(guess, tz);
  // overenie spätným prevodom: v preskočenej hodine sa miestny čas po prevode zmení
  if (utc + zoneOffsetMs(utc, tz) !== naive) return null;
  // pri opakovanej hodine vyber skorší okamih (letný čas)
  const earlier = utc - 3600_000;
  if (earlier + zoneOffsetMs(earlier, tz) === naive) return new Date(earlier);
  return new Date(utc);
}
