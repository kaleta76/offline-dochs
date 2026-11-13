import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { labelOf } from "@/lib/month";
import { type TransferClient } from "@/lib/org-transfer";
import {
  importLatePunches,
  MAX_LATE_FILE_BYTES,
  readLateFile,
  type LateFile,
  razeniaText,
  type LateReport,
} from "@/lib/late-punches";

// Neskoré razenia (migrácia 0019, docs/PRENOS-ORGANIZACIE.md): razenia, ktoré ostali v zariadení po presťahovaní organizácie, prídu
// správcovi ako šifrovaný súbor. Tu ho nahrá na novom serveri. Súbor sa dešifruje v prehliadači (heslo sa neposiela), server ho najprv
// len skontroluje a až po potvrdení zapíše to, čo je v poriadku. Súboru sa neverí: všetko rozhoduje databáza.

const client: TransferClient = {
  rpc: (fn, args) => (supabase as unknown as TransferClient).rpc(fn, args),
};

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

function when(value: string | null): string {
  if (!value) return "";
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? value : d.toLocaleString("sk-SK");
}

function Report({ report }: { report: LateReport }) {
  return (
    <div className="space-y-2 text-sm">
      <p>
        {report.dryRun ? (
          <>
            Kontrola: zapísať sa dá <strong className="num">{report.acceptable}</strong> z{" "}
            <span className="num">{report.total}</span> razení
          </>
        ) : (
          <>
            Zapísaných <strong className="num">{report.inserted}</strong> z{" "}
            <span className="num">{report.total}</span> razení
          </>
        )}
        {report.already > 0 && (
          <>
            , <span className="num">{report.already}</span> už na serveri je (nezapíšu sa druhý raz)
          </>
        )}
        {report.rejected > 0 && (
          <>
            , <span className="num">{report.rejected}</span> server odmietol
          </>
        )}
        . Účtov: <span className="num">{report.accounts}</span>.
      </p>
      {report.byAccount && report.byAccount.length > 0 && (
        <div className="space-y-1 text-xs">
          <p className="font-semibold">
            {report.dryRun
              ? "Razenia po účtoch (osobné číslo)"
              : "Razenia po účtoch (osobné číslo), ktoré sa dali zapísať"}
          </p>
          <ul className="list-disc pl-5">
            {report.byAccount.map((a) => (
              <li key={a.sapId ?? "bez-cisla"}>
                {a.sapId ? <span className="num">{a.sapId}</span> : "bez osobného čísla"}:{" "}
                {razeniaText(a.count)}
                {a.from && a.to ? (
                  <>
                    {" "}
                    (<span className="num">{when(a.from)}</span> až{" "}
                    <span className="num">{when(a.to)}</span>)
                  </>
                ) : null}
              </li>
            ))}
          </ul>
          {report.byAccount.length > 1 && (
            <p role="alert" className="text-destructive">
              Súbor z jedného zariadenia zvyčajne patrí jednému človeku, tu je účtov{" "}
              <span className="num">{report.byAccount.length}</span>. Skontrolujte, či je to
              správne, kým razenia zapíšete.
            </p>
          )}
        </div>
      )}
      {report.reasons.length > 0 && (
        <ul className="list-disc pl-5 text-xs">
          {report.reasons.map((r) => (
            <li key={r.reason}>
              {r.text}: <span className="num">{r.count}</span>
            </li>
          ))}
        </ul>
      )}
      {report.items.length > 0 && (
        <details className="text-xs">
          <summary className="cursor-pointer font-semibold">
            Odmietnuté razenia ({report.items.length})
          </summary>
          <ul className="mt-1 max-h-48 space-y-0.5 overflow-y-auto">
            {report.items.map((i) => (
              <li key={`${i.n}-${i.reason}`}>
                <span className="num">{i.n}.</span>{" "}
                {i.code && (i.direction === "IN" || i.direction === "OUT")
                  ? labelOf(i.code, i.direction)
                  : (i.code ?? "?")}{" "}
                <span className="num">{when(i.clientTime)}</span> · {i.text}
                {i.message ? ` (${i.message})` : ""}
              </li>
            ))}
          </ul>
        </details>
      )}
    </div>
  );
}

export function LatePunchesImport() {
  const qc = useQueryClient();
  const [file, setFile] = useState<File | null>(null);
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState<"check" | "write" | null>(null);
  const [opened, setOpened] = useState<LateFile | null>(null);
  const [checked, setChecked] = useState<LateReport | null>(null);
  const [done, setDone] = useState<LateReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [inputKey, setInputKey] = useState(0);

  function reset() {
    setFile(null);
    setPassword("");
    setOpened(null);
    setChecked(null);
    setError(null);
    setInputKey((k) => k + 1);
  }

  async function check() {
    if (!file || password === "") return;
    setBusy("check");
    setError(null);
    setDone(null);
    setChecked(null);
    setOpened(null);
    try {
      const content = await readLateFile(file, password);
      setOpened(content);
      setPassword("");
      setChecked(await importLatePunches(client, content, true));
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(null);
    }
  }

  async function write() {
    if (!opened) return;
    setBusy("write");
    setError(null);
    try {
      const report = await importLatePunches(client, opened, false);
      setDone(report);
      reset();
      await qc.invalidateQueries();
    } catch (e) {
      setError(
        `${errorText(e)} Či sa razenia zapísali, zistíte opakovanou kontrolou toho istého súboru: zapísané razenia server ukáže ako „už na serveri“.`,
      );
    } finally {
      setBusy(null);
    }
  }

  return (
    <section className="space-y-3 rounded-sm border-2 border-foreground bg-card p-4">
      <h2 className="text-sm font-bold uppercase tracking-widest">Neskoré razenia zo zariadenia</h2>
      <p className="text-sm text-muted-foreground">
        Po presťahovaní organizácie môžu v niektorých zariadeniach ostať razenia, ktoré sa na
        pôvodný server už nedali odoslať. Zariadenie ich uloží do šifrovaného súboru (
        <span className="num">razenia-zo-zariadenia-….dochs-enc</span>). Tu ho nahráte: razenia sa
        zapíšu ako neoverené (čas pochádza zo zariadenia) a potvrdí ich vedúci. Opakované nahratie
        toho istého súboru nič nezdvojí.
      </p>

      <div className="flex flex-wrap items-end gap-2">
        <label className="flex flex-col gap-1 text-xs">
          Súbor
          <Input
            key={inputKey}
            type="file"
            accept=".dochs-enc"
            aria-label="Súbor s razeniami zo zariadenia"
            onChange={(e) => {
              setFile(e.target.files?.[0] ?? null);
              setOpened(null);
              setChecked(null);
              setError(null);
            }}
          />
        </label>
        <label className="flex flex-col gap-1 text-xs">
          Heslo súboru
          <Input
            type="password"
            autoComplete="off"
            aria-label="Heslo súboru s razeniami"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </label>
        <Button
          type="button"
          disabled={!file || password === "" || !!busy}
          onClick={() => void check()}
        >
          {busy === "check" ? "Kontrolujem…" : "Skontrolovať súbor"}
        </Button>
      </div>
      {file && file.size > MAX_LATE_FILE_BYTES && (
        <p role="alert" className="text-sm text-destructive">
          Tento súbor je príliš veľký na súbor s razeniami zo zariadenia. Súbor s prenosom celej
          organizácie patrí do karty Import organizácie.
        </p>
      )}

      {opened && checked && (
        <div className="space-y-2 border-2 border-border p-3">
          <p className="text-sm">
            Súbor z <span className="num">{when(opened.createdAt)}</span>
            {opened.origin ? (
              <>
                , zo servera <span className="num">{opened.origin}</span>
              </>
            ) : null}
            : <span className="num">{opened.punches.length}</span> razení od{" "}
            <span className="num">{when(opened.from)}</span> do{" "}
            <span className="num">{when(opened.to)}</span>.
          </p>
          <Report report={checked} />
          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              disabled={!!busy || checked.acceptable === 0}
              onClick={() => void write()}
            >
              {busy === "write" ? "Zapisujem…" : `Zapísať ${checked.acceptable} razení`}
            </Button>
            <Button type="button" variant="outline" disabled={!!busy} onClick={reset}>
              Zahodiť
            </Button>
          </div>
          {checked.acceptable === 0 && (
            <p className="text-xs text-muted-foreground">
              V súbore nie je nič, čo by sa dalo zapísať.
            </p>
          )}
        </div>
      )}

      {done && (
        <div role="status" className="space-y-1 border-2 border-primary p-3">
          <p className="text-sm font-semibold">Hotovo.</p>
          <Report report={done} />
          <p className="text-xs text-muted-foreground">
            Zapísané razenia sú neoverené: vedúci ich potvrdí v karte Môj tím. Súbor uschovajte, kým
            nie sú potvrdené.
          </p>
        </div>
      )}

      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
    </section>
  );
}
