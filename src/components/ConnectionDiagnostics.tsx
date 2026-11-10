import { useCallback, useEffect, useRef, useState } from "react";
import { useAuth } from "@/lib/auth";
import { Button } from "@/components/ui/button";
import { buildProbes } from "@/lib/connection-probes";
import {
  backendHostOf,
  buildReport,
  emptyState,
  formatTime,
  getNetLog,
  OUTCOME_LABEL,
  probeHistoryLines,
  runProbes,
  summarize,
  type NetLogState,
  type ProbeResult,
} from "@/lib/net-log";

const MAX_RUNS = 30;
const WATCH_INTERVAL_MS = 60_000;

const box = "rounded-sm border-2 border-foreground bg-card p-4";

/**
 * Diagnostika spojenia pre správcu: test známych dopytov a záznam zlyhaných dopytov (čas, tvar dopytu bez hodnôt, druh chyby).
 * Text „Kopírovať pre SOC“ neobsahuje osobné údaje ani tokeny. Podrobnosti: src/lib/net-log.ts.
 */
export function ConnectionDiagnostics() {
  const { session } = useAuth();
  const userId = session?.user.id;
  const [state, setState] = useState<NetLogState>(emptyState);
  const [runs, setRuns] = useState<ProbeResult[][]>([]);
  const [report, setReport] = useState("");
  const [busy, setBusy] = useState(false);
  const [watching, setWatching] = useState(false);
  const [message, setMessage] = useState("");
  const runsRef = useRef<ProbeResult[][]>([]);
  const busyRef = useRef(false);

  // Výpis a text správy sa skladajú len v prehliadači (na serveri nie je localStorage ani navigator).
  const refresh = useCallback(() => {
    const current = getNetLog().read();
    setState(current);
    setReport(
      buildReport(current, runsRef.current, {
        now: Date.now(),
        userAgent: navigator.userAgent,
        appHost: window.location.host,
        dbHost: backendHostOf(import.meta.env["VITE_SUPABASE_URL"]) ?? "",
        online: navigator.onLine,
      }),
    );
  }, []);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 10_000);
    return () => clearInterval(id);
  }, [refresh]);

  const runOnce = useCallback(async () => {
    if (!userId || busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    try {
      const results = await runProbes(buildProbes(userId, new Date()), {
        pauseMs: 400,
        offline: () => navigator.onLine === false,
      });
      runsRef.current = [...runsRef.current, results].slice(-MAX_RUNS);
      setRuns(runsRef.current);
    } finally {
      busyRef.current = false;
      setBusy(false);
      refresh();
    }
  }, [userId, refresh]);

  const runOnceRef = useRef(runOnce);
  useEffect(() => {
    runOnceRef.current = runOnce;
  }, [runOnce]);

  // Sledovanie: prvý beh hneď, potom raz za minútu, najviac MAX_RUNS behov (zachytí zmeny v čase, napr. nové pravidlo proxy).
  useEffect(() => {
    if (!watching) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let count = 0;
    const tick = async () => {
      if (cancelled) return;
      await runOnceRef.current();
      count += 1;
      if (cancelled) return;
      if (count >= MAX_RUNS) {
        setWatching(false);
        return;
      }
      timer = setTimeout(() => void tick(), WATCH_INTERVAL_MS);
    };
    void tick();
    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
  }, [watching]);

  async function copyReport() {
    refresh();
    const text = buildReport(getNetLog().read(), runsRef.current, {
      now: Date.now(),
      userAgent: navigator.userAgent,
      appHost: window.location.host,
      dbHost: backendHostOf(import.meta.env["VITE_SUPABASE_URL"]) ?? "",
      online: navigator.onLine,
    });
    try {
      await navigator.clipboard.writeText(text);
      setMessage("Správa bola skopírovaná. Neobsahuje osobné údaje ani tokeny.");
    } catch {
      setMessage("Kopírovanie sa nepodarilo. Text správy je nižšie, označte ho a skopírujte ručne.");
    }
  }

  function clearLog() {
    if (!window.confirm("Vymazať záznam zlyhaných dopytov v tomto prehliadači?")) return;
    getNetLog().clear();
    runsRef.current = [];
    setRuns([]);
    setMessage("Záznam bol vymazaný.");
    refresh();
  }

  const summary = summarize(state);
  const last = runs[runs.length - 1] ?? [];
  const recent = [...state.failures].sort((a, b) => b.t - a.t).slice(0, 10);

  return (
    <section className={box} aria-labelledby="connection-diagnostics-title">
      <h2 id="connection-diagnostics-title" className="mb-3 text-sm font-bold uppercase tracking-widest">
        Diagnostika spojenia
      </h2>
      <p className="mb-3 text-xs text-muted-foreground">
        Aplikácia si v tomto prehliadači zapisuje, ktoré dopyty na server zlyhali (čas, adresa bez hodnôt, druh chyby). Neukladá osobné čísla,
        mená, tokeny ani obsah odpovedí. Test pošle tie isté čítania, aké aplikácia používa, a nič nemení.
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <Button onClick={() => void runOnce()} disabled={busy || watching || !userId}>
          {busy && !watching ? "Testujem…" : "Spustiť test spojenia"}
        </Button>
        <Button variant="outline" onClick={() => setWatching((w) => !w)} disabled={!userId}>
          {watching ? "Zastaviť sledovanie" : `Sledovať každú minútu (${MAX_RUNS}×)`}
        </Button>
        <Button variant="outline" onClick={() => void copyReport()}>
          Kopírovať pre SOC
        </Button>
        <Button variant="outline" onClick={clearLog}>
          Vymazať záznam
        </Button>
      </div>
      {message && (
        <p role="status" className="mt-2 text-sm">
          {message}
        </p>
      )}

      <p className="mt-4 text-sm">
        <span className="font-semibold">Záznam:</span> dopytov {summary.total}, zlyhalo {summary.failed}, chyby aplikácie alebo databázy (nie siete){" "}
        {summary.app}
        {summary.since ? ` (od ${summary.since.replace("T", " ")}:00)` : ""}.
      </p>

      {last.length > 0 && (
        <div className="mt-3 overflow-x-auto">
          <p className="mb-1 text-xs text-muted-foreground">
            Posledný test: {formatTime(last[0]?.at ?? Date.now())}
            {runs.length > 1 ? `, behov ${runs.length}` : ""}
          </p>
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b-2 border-foreground text-left text-xs uppercase">
                <th className="py-1 pr-2">Dopyt</th>
                <th className="pr-2">Metóda</th>
                <th className="pr-2">HTTP</th>
                <th className="pr-2">ms</th>
                <th>Výsledok</th>
              </tr>
            </thead>
            <tbody>
              {last.map((r) => (
                <tr key={r.id} className="border-b border-border align-top">
                  <td className="py-1 pr-2">
                    <div>{r.label}</div>
                    <div className="num break-all text-xs text-muted-foreground">{r.request}</div>
                  </td>
                  <td className="num pr-2">{r.method}</td>
                  <td className="num pr-2">{r.status ?? "–"}</td>
                  <td className="num pr-2">{r.ms}</td>
                  <td className={r.outcome === "ok" ? "" : "font-semibold text-destructive"}>
                    {OUTCOME_LABEL[r.outcome]}
                    {r.note ? <span className="font-normal text-muted-foreground"> ({r.note})</span> : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {runs.length > 1 && (
        <div className="mt-3">
          <p className="mb-1 text-xs text-muted-foreground">
            Priebeh testu (. v poriadku, X spojenie zatvorené, P proxy, C certifikát, a chyba databázy):
          </p>
          <pre className="num overflow-x-auto text-xs">{probeHistoryLines(runs).join("\n")}</pre>
        </div>
      )}

      <div className="mt-4">
        <p className="mb-1 text-xs font-semibold uppercase">Posledné zlyhania</p>
        {recent.length === 0 ? (
          <p className="text-sm text-muted-foreground">Zatiaľ žiadne.</p>
        ) : (
          <ul className="space-y-1 text-sm">
            {recent.map((f) => (
              <li key={`${f.t}-${f.method}-${f.path}-${f.query}`} className="border-b border-border pb-1">
                <span className="num">{formatTime(f.t)}</span> <span className="num">{f.method}</span>{" "}
                <span className="num break-all">
                  {f.path}
                  {f.query ? `?${f.query}` : ""}
                </span>{" "}
                <span className="font-semibold">{OUTCOME_LABEL[f.kind]}</span>{" "}
                <span className="text-xs text-muted-foreground">
                  ({f.status == null ? "bez odpovede" : `HTTP ${f.status}`}, {f.ms} ms{f.note ? `, ${f.note}` : ""})
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <details className="mt-4">
        <summary className="cursor-pointer text-sm font-semibold">Text správy pre SOC</summary>
        <textarea readOnly value={report} rows={12} className="num mt-2 w-full rounded-sm border border-input bg-background p-2 text-xs" />
      </details>
    </section>
  );
}
