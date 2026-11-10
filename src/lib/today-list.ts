// Zoznam „Dnešné záznamy“ na termináli: razenia zo servera a razenia čakajúce vo fronte zariadenia.
// Zneplatnené razenie (voided_at) ostáva v zozname, aby bolo vidieť, že existuje (v Môj mesiac je prečiarknuté), ale nepočíta sa:
// nesmie určovať, či je zamestnanec „Na pracovisku“.
import { notHappenedYet } from "./presence";

export interface TodayRow {
  client_uuid: string;
  code: string;
  direction: string;
  client_time: string;
  voided_at: string | null;
}

export interface QueuedRow {
  client_uuid: string;
  code: string;
  direction: string;
  client_time: string;
  error?: string | undefined;
}

export interface TodayEntry {
  id: string;
  code: string;
  dir: string;
  time: Date;
  /** razenie je zatiaľ len vo fronte zariadenia */
  pending: boolean;
  /** razenie je zneplatnené a nepočíta sa */
  voided: boolean;
  error: string | undefined;
}

/**
 * Spojí razenia zo servera s frontou zariadenia (len dnešné a len tie, ktoré server ešte nevrátil), vylúči plánované razenia
 * z budúcnosti a zoradí podľa času. `isToday` určuje, či čas patrí do dnešného dňa v miestnom čase.
 */
export function buildTodayList(
  rows: readonly TodayRow[],
  queue: readonly QueuedRow[],
  isToday: (time: Date) => boolean,
  now: Date,
): TodayEntry[] {
  const fromServer: TodayEntry[] = rows.map((p) => ({
    id: p.client_uuid,
    code: p.code,
    dir: p.direction,
    time: new Date(p.client_time),
    pending: false,
    voided: p.voided_at != null,
    error: undefined,
  }));
  const known = new Set(rows.map((p) => p.client_uuid));
  const fromQueue: TodayEntry[] = queue
    .filter((i) => isToday(new Date(i.client_time)) && !known.has(i.client_uuid))
    .map((i) => ({
      id: i.client_uuid,
      code: i.code,
      dir: i.direction,
      time: new Date(i.client_time),
      pending: true,
      voided: false,
      error: i.error,
    }));
  return [...fromServer, ...fromQueue]
    .filter((p) => !notHappenedYet(p.time, now))
    .sort((a, b) => a.time.getTime() - b.time.getTime());
}

/** Posledné platné (nezneplatnené) razenie: podľa neho je zamestnanec „Na pracovisku“ alebo „Mimo“. */
export function lastActiveEntry(list: readonly TodayEntry[]): TodayEntry | undefined {
  for (let i = list.length - 1; i >= 0; i--) {
    const e = list[i];
    if (e && !e.voided) return e;
  }
  return undefined;
}
