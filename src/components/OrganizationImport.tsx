import { useEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { confirmationMatches } from "@/lib/organization-delete";
import { TransferError, type TransferClient } from "@/lib/org-transfer";
import {
  cancelImport,
  commitImport,
  getImportStatus,
  uploadImport,
  type CheckedImport,
  type ImportDone,
  type ImportProgress,
} from "@/lib/org-transfer-import";

// Import organizácie z iného servera (migrácia 0017, docs/PRENOS-ORGANIZACIE.md). Správca čerstvej prázdnej organizácie vyberie súbor
// z exportu a zadá heslo; súbor sa dešifruje v prehliadači, nahrá a skontroluje. Až po výslovnom potvrdení databáza čerstvú organizáciu
// (aj s účtom správcu) nahradí organizáciou zo súboru a vypíše kód potvrdenia prenosu pre pôvodný server.

const client: TransferClient = {
  rpc: (fn, args) => (supabase as unknown as TransferClient).rpc(fn, args),
};

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

function progressText(p: ImportProgress | null): string {
  if (!p) return "Pripravujem…";
  switch (p.phase) {
    case "decrypt":
      return "Dešifrujem súbor…";
    case "begin":
      return "Začínam import na serveri…";
    case "upload":
      return `Nahrávam údaje: ${p.rows} z ${p.total} riadkov`;
    case "check":
      return "Server kontroluje súbor…";
  }
}

const COUNT_LABELS: [string, string][] = [
  ["public.profiles", "účty"],
  ["public.punches", "razenia"],
  ["public.devices", "zariadenia"],
  ["public.corrections", "žiadosti o opravu"],
  ["public.month_closures", "uzávierky mesiaca"],
];

function describeCounts(counts: Record<string, number>): string {
  return COUNT_LABELS.map(([rel, label]) => `${label}: ${counts[rel] ?? 0}`).join(", ");
}

export function OrganizationImport() {
  const { organization, session } = useAuth();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const statusKey = ["org-import", organization?.id, session?.user.id];

  const [file, setFile] = useState<File | null>(null);
  const [password, setPassword] = useState("");
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<ImportProgress | null>(null);
  const [checked, setChecked] = useState<CheckedImport | null>(null);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [typedName, setTypedName] = useState("");
  const [understood, setUnderstood] = useState(false);
  const [busy, setBusy] = useState(false);
  const [dialogError, setDialogError] = useState<string | null>(null);
  const [done, setDone] = useState<ImportDone | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const statusQuery = useQuery({
    queryKey: statusKey,
    enabled: !!session && !done,
    retry: false,
    queryFn: () => getImportStatus(client),
  });
  const status = statusQuery.data;
  const missing =
    statusQuery.error instanceof TransferError && statusQuery.error.kind === "missing";

  useEffect(() => {
    if (!running && !busy) return;
    const warn = (e: BeforeUnloadEvent) => {
      e.preventDefault();
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [running, busy]);

  const refresh = () => qc.invalidateQueries({ queryKey: statusKey });

  async function upload() {
    if (!file || password === "") return;
    const controller = new AbortController();
    abortRef.current = controller;
    setRunning(true);
    setProgress(null);
    setMessage(null);
    setChecked(null);
    try {
      const res = await uploadImport(client, {
        file,
        password,
        signal: controller.signal,
        onProgress: setProgress,
      });
      setChecked(res);
      setPassword("");
    } catch (e) {
      let text = errorText(e);
      if (e instanceof TransferError && e.transferId) {
        try {
          await cancelImport(client);
          text += " Nahrané údaje boli zahodené, v aplikácii sa nič nezmenilo.";
        } catch {
          text += " Nahrané údaje sa nepodarilo zahodiť: zahoďte ich tlačidlom nižšie.";
        }
      }
      setMessage({ ok: false, text });
    } finally {
      abortRef.current = null;
      setRunning(false);
      await refresh();
    }
  }

  async function discard() {
    setBusy(true);
    setMessage(null);
    try {
      const had = await cancelImport(client);
      setChecked(null);
      setMessage({
        ok: true,
        text: had
          ? "Rozpracovaný import je zahodený, v aplikácii sa nič nezmenilo."
          : "Nebol žiadny rozpracovaný import.",
      });
      await refresh();
    } catch (e) {
      setMessage({ ok: false, text: errorText(e) });
    } finally {
      setBusy(false);
    }
  }

  async function commit() {
    if (!checked) return;
    setBusy(true);
    setDialogError(null);
    try {
      const res = await commitImport(client, {
        importId: checked.importId,
        confirmName: typedName,
      });
      const uid = session?.user.id;
      setDone(res);
      setDialogOpen(false);
      setChecked(null);
      await qc.cancelQueries();
      try {
        localStorage.removeItem("me-cache");
        if (uid) localStorage.removeItem(`me-cache:${uid}`);
      } catch {
        /* úložisko nie je dostupné */
      }
    } catch (e) {
      setDialogError(errorText(e));
    } finally {
      setBusy(false);
    }
  }

  async function signOut() {
    qc.clear();
    // Účet čerstvej organizácie už neexistuje, preto len lokálne odhlásenie (bez volania servera).
    await supabase.auth.signOut({ scope: "local" });
    navigate({ to: "/auth", replace: true });
  }

  const nameOk = !!checked && confirmationMatches(checked.replacesName, typedName);

  if (done) {
    return (
      <section className="space-y-3 rounded-sm border-2 border-destructive bg-card p-4">
        <h2 className="text-sm font-bold uppercase tracking-widest">
          Import organizácie z iného servera
        </h2>
        <div role="status" className="space-y-2 text-sm">
          <p>
            Organizácia „{done.organizationName}“ (kód {done.organizationCode}) je importovaná a
            overená: {done.rows} riadkov.
            {done.renumbered &&
              " Čísla razení sa prečíslovali v rovnakom poradí (na tomto serveri už razenia s rovnakými číslami boli)."}
          </p>
          <p className="font-semibold">Kód potvrdenia prenosu (zadajte ho na pôvodnom serveri):</p>
          <p className="font-mono text-2xl font-bold tracking-widest" data-testid="import-receipt">
            {done.receipt}
          </p>
          <p>
            Kód si opíšte. Nájdete ho aj neskôr v tejto karte po prihlásení správcom prenesenej
            organizácie. Účet, ktorým ste import robili, už neexistuje: odhláste sa a prihláste sa
            kódom organizácie {done.organizationCode} a údajmi z pôvodného servera (osobné číslo a
            heslo ostali rovnaké).
          </p>
          {done.warnings.map((w) => (
            <p key={w}>Upozornenie: {w}</p>
          ))}
        </div>
        <Button type="button" onClick={() => void signOut()}>
          Odhlásiť sa
        </Button>
      </section>
    );
  }

  return (
    <section className="space-y-3 rounded-sm border-2 border-destructive bg-card p-4">
      <h2 className="text-sm font-bold uppercase tracking-widest">
        Import organizácie z iného servera
      </h2>

      {statusQuery.isPending && <p className="text-sm text-muted-foreground">Načítavam…</p>}
      {missing && (
        <p role="alert" className="text-sm">
          Import ešte nie je v databáze. Najprv treba spustiť migráciu 0017
          (docs/migracie/0017_prenos_organizacie_import.sql).
        </p>
      )}
      {statusQuery.error && !missing && (
        <p role="alert" className="text-sm text-destructive">
          {errorText(statusQuery.error)}
        </p>
      )}

      {status?.lastImport && (
        <div className="space-y-1 text-sm" role="status">
          <p>
            Táto organizácia bola na tento server importovaná ({status.lastImport.rows} riadkov).
            Kód potvrdenia prenosu pre pôvodný server:
          </p>
          <p className="font-mono text-xl font-bold tracking-widest">{status.lastImport.receipt}</p>
        </div>
      )}

      {status && !status.eligible && !status.lastImport && (
        <div className="space-y-1 text-sm">
          <p>
            Import nahrádza len čerstvú prázdnu organizáciu. Do tejto organizácie sa importovať
            nedá:
          </p>
          <ul className="list-disc pl-5">
            {status.reasons.map((r) => (
              <li key={r}>{r}</li>
            ))}
          </ul>
          <p>
            Zaregistrujte na tomto serveri novú organizáciu a import spustite z nej, kým je prázdna.
          </p>
        </div>
      )}

      {status?.eligible && !checked && (
        <form
          className="space-y-2 text-sm"
          onSubmit={(e) => {
            e.preventDefault();
            void upload();
          }}
        >
          <p>
            Vyberte súbor z exportu na pôvodnom serveri (<code>.dochs-enc</code>) a zadajte jeho
            heslo. Súbor sa dešifruje v tomto prehliadači (heslo sa nikam neposiela), nahrá sa a
            server ho skontroluje. Do potvrdenia sa v aplikácii nič nemení.
          </p>
          <label className="block font-semibold" htmlFor="import-file">
            Súbor prenosu
          </label>
          <input
            id="import-file"
            type="file"
            accept=".dochs-enc"
            disabled={running}
            onChange={(e) => {
              setFile(e.target.files?.[0] ?? null);
              setMessage(null);
            }}
          />
          <label className="block font-semibold" htmlFor="import-password">
            Heslo súboru
          </label>
          <Input
            id="import-password"
            type="password"
            autoComplete="off"
            disabled={running}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
          {running ? (
            <div className="flex flex-wrap items-center gap-3">
              <span role="status">{progressText(progress)}</span>
              <Button type="button" variant="outline" onClick={() => abortRef.current?.abort()}>
                Prerušiť
              </Button>
            </div>
          ) : (
            <Button type="submit" disabled={!file || password === ""}>
              Nahrať a skontrolovať
            </Button>
          )}
        </form>
      )}

      {status?.active && !checked && !running && (
        <div className="space-y-2 text-sm">
          <p>
            Na serveri čaká rozpracovaný import organizácie „{status.active.organizationName}“ (
            {status.active.received} z {status.active.rows} riadkov). Nahrajte súbor znova (nahradí
            ho) alebo ho zahoďte.
          </p>
          <Button type="button" variant="outline" disabled={busy} onClick={() => void discard()}>
            Zahodiť rozpracovaný import
          </Button>
        </div>
      )}

      {checked && (
        <div className="space-y-2 text-sm">
          <p role="status">
            Súbor je v poriadku: organizácia „{checked.organizationName}“ (kód{" "}
            {checked.organizationCode}), {checked.rows} riadkov ({describeCounts(checked.counts)}
            ).
            {checked.exportedAt &&
              ` Exportované ${new Date(checked.exportedAt).toLocaleString("sk-SK")}.`}
          </p>
          {checked.warnings.map((w) => (
            <p key={w}>Upozornenie: {w}</p>
          ))}
          <p>
            Importom <strong>zanikne</strong> táto prázdna organizácia „{checked.replacesName}“ aj
            účet, ktorým ste prihlásený, a nahradí ju organizácia zo súboru s pôvodným kódom, účtami
            a heslami.
          </p>
          <div className="flex flex-wrap gap-3">
            <Button
              type="button"
              variant="destructive"
              disabled={busy}
              onClick={() => {
                setTypedName("");
                setUnderstood(false);
                setDialogError(null);
                setDialogOpen(true);
              }}
            >
              Importovať a nahradiť túto organizáciu
            </Button>
            <Button type="button" variant="outline" disabled={busy} onClick={() => void discard()}>
              Zahodiť
            </Button>
          </div>
        </div>
      )}

      {message && (
        <p
          role={message.ok ? "status" : "alert"}
          className={`whitespace-pre-line text-sm ${message.ok ? "" : "text-destructive"}`}
        >
          {message.text}
        </p>
      )}

      <AlertDialog
        open={dialogOpen}
        onOpenChange={(open) => {
          if (!busy) setDialogOpen(open);
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Nahradiť túto organizáciu importovanou?</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div className="space-y-2 text-sm">
                <p>
                  Prázdna organizácia „{checked?.replacesName}“ (kód {checked?.replacesCode}) a váš
                  terajší účet <strong>natrvalo zaniknú</strong>. Na ich miesto príde organizácia „
                  {checked?.organizationName}“ (kód {checked?.organizationCode}) so všetkými účtami,
                  razeniami a nastaveniami zo súboru.
                </p>
                <p>
                  Po importe vás aplikácia odhlási. Prihlásite sa kódom organizácie{" "}
                  {checked?.organizationCode} a údajmi z pôvodného servera.
                </p>
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <form
            className="space-y-2 text-sm"
            onSubmit={(e) => {
              e.preventDefault();
              if (nameOk && understood && !busy) void commit();
            }}
          >
            <label className="flex items-start gap-2" htmlFor="import-understood">
              <input
                id="import-understood"
                type="checkbox"
                className="mt-1"
                checked={understood}
                disabled={busy}
                onChange={(e) => setUnderstood(e.target.checked)}
              />
              <span>Rozumiem, že táto prázdna organizácia a môj terajší účet zaniknú.</span>
            </label>
            <label className="block font-semibold" htmlFor="import-confirm-name">
              Na potvrdenie opíšte názov organizácie, ktorá zanikne: {checked?.replacesName}
            </label>
            <Input
              id="import-confirm-name"
              autoComplete="off"
              disabled={busy}
              value={typedName}
              onChange={(e) => setTypedName(e.target.value)}
            />
            {dialogError && (
              <p role="alert" className="whitespace-pre-line text-destructive">
                {dialogError}
              </p>
            )}
            <AlertDialogFooter>
              <Button
                type="button"
                variant="outline"
                disabled={busy}
                onClick={() => setDialogOpen(false)}
              >
                Späť
              </Button>
              <Button type="submit" variant="destructive" disabled={busy || !nameOk || !understood}>
                {busy ? "Importujem…" : "Importovať"}
              </Button>
            </AlertDialogFooter>
          </form>
        </AlertDialogContent>
      </AlertDialog>
    </section>
  );
}
