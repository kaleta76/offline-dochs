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
import { TransferDestination } from "@/components/TransferDestination";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { confirmationMatches, describeContents, parseSummary } from "@/lib/organization-delete";
import { MIN_PASSWORD_LENGTH, passwordProblem } from "@/lib/org-transfer-crypto";
import {
  TransferError,
  cancelTransfer,
  confirmTransferAndDelete,
  describeChanges,
  exportOrganization,
  getTransferStatus,
  normalizeReceipt,
  verifyTransferFile,
  type ExportProgress,
  type ExportResult,
  type TransferClient,
  type TransferStatus,
  type VerifiedFile,
} from "@/lib/org-transfer";

// Prenos organizácie na iný server (migrácia 0016, docs/PRENOS-ORGANIZACIE.md). Správca vyexportuje organizáciu do súboru zašifrovaného
// heslom (šifruje sa v prehliadači, heslo sa nikam neposiela), organizácia sa označí ako testovacia a po potvrdení, že sa prenos na cieľovom
// serveri podaril (kód potvrdenia z cieľového servera), ju môže správca natrvalo zrušiť.

const client: TransferClient = {
  rpc: (fn, args) => (supabase as unknown as TransferClient).rpc(fn, args),
};

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

function formatSize(bytes: number): string {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} kB`;
  return `${(bytes / (1024 * 1024)).toFixed(1).replace(".", ",")} MB`;
}

function progressText(p: ExportProgress | null): string {
  if (!p) return "Pripravujem…";
  switch (p.phase) {
    case "key":
      return "Odvodzujem šifrovací kľúč z hesla…";
    case "begin":
      return "Začínam prenos na serveri…";
    case "read":
      return `Čítam údaje: ${p.rows} z ${p.total} riadkov`;
    case "seal":
      return "Šifrujem súbor…";
    case "finish":
      return "Uzatváram prenos na serveri…";
  }
}

function download(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  // Uvoľnenie až po chvíli: niektoré prehliadače začnú sťahovať asynchrónne.
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

type Message = { ok: boolean; text: string } | null;

function Checkbox(props: {
  id: string;
  checked: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
  children: React.ReactNode;
}) {
  return (
    <label htmlFor={props.id} className="flex items-start gap-2 text-sm">
      <input
        id={props.id}
        type="checkbox"
        className="mt-1"
        checked={props.checked}
        disabled={props.disabled ?? false}
        onChange={(e) => props.onChange(e.target.checked)}
      />
      <span>{props.children}</span>
    </label>
  );
}

/** Kontrola súboru uloženého na disku: otvorí ho heslom a overí, že je úplný. Súbor sa nikam neposiela. */
function FileCheck({ status }: { status: TransferStatus }) {
  const [file, setFile] = useState<File | null>(null);
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [verified, setVerified] = useState<VerifiedFile | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function check() {
    if (!file) return;
    setBusy(true);
    setVerified(null);
    setError(null);
    try {
      setVerified(await verifyTransferFile(file, password));
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <details className="space-y-2 text-sm">
      <summary className="cursor-pointer font-semibold">Skontrolovať uložený súbor</summary>
      <p className="mt-2">
        Pred zrušením organizácie sa odporúča overiť, že súbor, ktorý máte uložený, sa dá otvoriť
        heslom a je úplný. Súbor sa nikam neodosiela.
      </p>
      <label className="block font-semibold" htmlFor="transfer-check-file">
        Súbor
      </label>
      <input
        id="transfer-check-file"
        type="file"
        className="block w-full cursor-pointer text-sm file:mr-3 file:cursor-pointer file:rounded-sm file:border-2 file:border-foreground file:bg-background file:px-3 file:py-2 file:font-semibold"
        accept=".dochs-enc"
        onChange={(e) => {
          setFile(e.target.files?.[0] ?? null);
          setVerified(null);
          setError(null);
        }}
      />
      <label className="block font-semibold" htmlFor="transfer-check-password">
        Heslo súboru
      </label>
      <Input
        id="transfer-check-password"
        type="password"
        autoComplete="off"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
      />
      <Button
        type="button"
        variant="outline"
        disabled={busy || !file || password === ""}
        onClick={() => void check()}
      >
        {busy ? "Kontrolujem…" : "Skontrolovať"}
      </Button>
      {verified && (
        <p role="status">
          Súbor je v poriadku: organizácia „{verified.organizationName}“, {verified.rows} riadkov v{" "}
          {Object.keys(verified.counts).length} tabuľkách.
          {verified.organizationName !== status.name && (
            <strong className="block text-destructive">
              Pozor: súbor je z inej organizácie („{verified.organizationName}“), než je táto („
              {status.name}“).
            </strong>
          )}
        </p>
      )}
      {error && (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      )}
    </details>
  );
}

export function OrganizationTransfer() {
  const { organization, session } = useAuth();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const statusKey = ["org-transfer", organization?.id, session?.user.id];

  const [lock, setLock] = useState(true);
  const [password, setPassword] = useState("");
  const [repeat, setRepeat] = useState("");
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<ExportProgress | null>(null);
  const [checking, setChecking] = useState(false);
  const [message, setMessage] = useState<Message>(null);
  const [result, setResult] = useState<ExportResult | null>(null);
  const [verified, setVerified] = useState<VerifiedFile | null>(null);
  const [verifyError, setVerifyError] = useState<string | null>(null);
  const [receipt, setReceipt] = useState("");
  const [typedName, setTypedName] = useState("");
  const [acceptChanges, setAcceptChanges] = useState(false);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [queuesEmpty, setQueuesEmpty] = useState(false);
  const [busy, setBusy] = useState(false);
  const [dialogError, setDialogError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const statusQuery = useQuery({
    queryKey: statusKey,
    enabled: !!session,
    retry: false,
    queryFn: () => getTransferStatus(client),
  });
  const status = statusQuery.data;
  const summaryQuery = useQuery({
    queryKey: ["org-transfer-summary", organization?.id, session?.user.id],
    enabled: !!session && status?.state === "exported",
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("test_organization_summary");
      if (error) throw error;
      return parseSummary(data);
    },
  });
  const contents = summaryQuery.data ?? null;
  const missing =
    statusQuery.error instanceof TransferError && statusQuery.error.kind === "missing";

  // Počas exportu by zatvorenie karty prerušilo prenos so zamknutými razeniami.
  useEffect(() => {
    if (!running) return;
    const warn = (e: BeforeUnloadEvent) => {
      e.preventDefault();
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [running]);

  const refresh = async () => {
    await qc.invalidateQueries({ queryKey: statusKey });
    await qc.invalidateQueries({ queryKey: ["me"] });
  };

  async function start() {
    const problem =
      passwordProblem(password) ?? (password !== repeat ? "Heslá sa nezhodujú." : null);
    if (problem) {
      setMessage({ ok: false, text: problem });
      return;
    }
    const pw = password;
    const controller = new AbortController();
    abortRef.current = controller;
    setRunning(true);
    setProgress(null);
    setMessage(null);
    setResult(null);
    setVerified(null);
    setVerifyError(null);
    setAcceptChanges(false);
    setQueuesEmpty(false);
    try {
      const res = await exportOrganization(client, {
        lock,
        password: pw,
        signal: controller.signal,
        onProgress: setProgress,
      });
      setResult(res);
      setPassword("");
      setRepeat("");
      download(res.blob, res.fileName);
      setChecking(true);
      try {
        setVerified(await verifyTransferFile(res.blob, pw));
      } catch (e) {
        setVerifyError(errorText(e));
      } finally {
        setChecking(false);
      }
    } catch (e) {
      let text = errorText(e);
      if (e instanceof TransferError && e.transferId) {
        try {
          await cancelTransfer(client);
          text += " Prenos bol zrušený a razenia sú odomknuté.";
        } catch {
          text +=
            " Rozpracovaný prenos sa nepodarilo automaticky zrušiť: zrušte ho tlačidlom nižšie, aby sa odomkli razenia.";
        }
      }
      setMessage({ ok: false, text });
    } finally {
      abortRef.current = null;
      setRunning(false);
      await refresh();
    }
  }

  async function cancel() {
    setBusy(true);
    setMessage(null);
    try {
      const r = await cancelTransfer(client);
      setResult(null);
      setVerified(null);
      setVerifyError(null);
      setReceipt("");
      setTypedName("");
      setMessage({
        ok: true,
        text: r.hadTransfer
          ? `Prenos je zrušený${r.unlocked ? ", razenia sú odomknuté" : ""}${r.testFlagReverted ? " a označenie testovacia sa vrátilo" : ""}.`
          : "Nebol žiadny rozpracovaný prenos.",
      });
      await refresh();
    } catch (e) {
      setMessage({ ok: false, text: errorText(e) });
    } finally {
      setBusy(false);
    }
  }

  async function remove() {
    if (!status) return;
    setBusy(true);
    setDialogError(null);
    try {
      const done = await confirmTransferAndDelete(client, {
        receipt,
        name: typedName,
        acceptChanges,
      });
      const uid = session?.user.id;
      await qc.cancelQueries();
      qc.clear();
      try {
        localStorage.removeItem("me-cache");
        if (uid) localStorage.removeItem(`me-cache:${uid}`);
      } catch {
        /* úložisko nie je dostupné */
      }
      // Účet už neexistuje, preto len lokálne odhlásenie (bez volania servera).
      await supabase.auth.signOut({ scope: "local" });
      window.alert(`Organizácia „${status.name}“ bola zrušená: ${describeContents(done)}.`);
      navigate({ to: "/auth", replace: true });
    } catch (e) {
      let text = errorText(e);
      if (e instanceof TransferError && e.kind === "transport") {
        text +=
          " Zrušenie mohlo prebehnúť: obnovte stránku; ak sa už nedá prihlásiť, organizácia je zrušená.";
      }
      setDialogError(text);
      setBusy(false);
    }
  }

  const receiptOk = normalizeReceipt(receipt) !== null;
  const nameOk = !!status && confirmationMatches(status.name, typedName);
  const changesOk = !status?.hasChanges || acceptChanges;
  const canDelete = !!status && !status.protectedOrganization && receiptOk && nameOk && changesOk;

  return (
    <section className="space-y-3 rounded-sm border-2 border-destructive bg-card p-4">
      <h2 className="text-sm font-bold uppercase tracking-widest">
        Prenos organizácie na iný server
      </h2>

      {statusQuery.isPending && <p className="text-sm text-muted-foreground">Načítavam…</p>}
      {missing && (
        <p role="alert" className="text-sm">
          Táto funkcia ešte nie je v databáze. Najprv treba spustiť migráciu 0016
          (docs/migracie/0016_prenos_organizacie_export.sql).
        </p>
      )}
      {statusQuery.error && !missing && (
        <p role="alert" className="text-sm text-destructive">
          Stav prenosu sa nepodarilo načítať: {errorText(statusQuery.error)}
        </p>
      )}

      {running && (
        <div className="space-y-2" aria-live="polite">
          <p className="text-sm font-semibold">{progressText(progress)}</p>
          {progress?.phase === "read" && progress.total > 0 && (
            <progress className="w-full" max={progress.total} value={progress.rows} />
          )}
          <p className="text-sm">Nezatvárajte túto stránku, kým prenos neskončí.</p>
          <Button type="button" variant="outline" onClick={() => abortRef.current?.abort()}>
            Prerušiť
          </Button>
        </div>
      )}

      {status && !running && status.state === "none" && (
        <form
          className="space-y-3"
          onSubmit={(e) => {
            e.preventDefault();
            void start();
          }}
        >
          <p className="text-sm">
            Vyexportuje celú organizáciu „{status.name}“ (účty, razenia, zariadenia, nastavenia,
            audit) do jedného súboru zašifrovaného heslom. Šifruje sa v tomto prehliadači a heslo sa
            nikam neposiela. <strong>Heslo sa nedá obnoviť</strong>: bez neho je súbor nepoužiteľný.
            Po exporte sa organizácia označí ako testovacia a zobrazí sa okno na jej zrušenie po
            potvrdení prenosu. Celý postup je v docs/PRENOS-ORGANIZACIE.md.
          </p>
          {status.protectedOrganization && (
            <p className="text-sm">
              Toto je pôvodná organizácia s prevzatými údajmi. Dá sa exportovať ako kópia, ale nedá
              sa označiť ako testovacia ani zrušiť.
            </p>
          )}
          <Checkbox id="transfer-lock" checked={lock} onChange={setLock}>
            Zamknúť razenia na čas prenosu (odporúčané). Terminály ich ponechajú vo fronte a odošlú
            neskôr; zamknutie platí, kým prenos nezrušíte.
          </Checkbox>
          <label className="block text-sm font-semibold" htmlFor="transfer-password">
            Heslo súboru (aspoň {MIN_PASSWORD_LENGTH} znakov)
          </label>
          <Input
            id="transfer-password"
            type="password"
            autoComplete="new-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
          <label className="block text-sm font-semibold" htmlFor="transfer-password-repeat">
            Heslo ešte raz
          </label>
          <Input
            id="transfer-password-repeat"
            type="password"
            autoComplete="new-password"
            value={repeat}
            onChange={(e) => setRepeat(e.target.value)}
          />
          <Button type="submit" variant="destructive" disabled={password === "" || repeat === ""}>
            Vyexportovať organizáciu
          </Button>
        </form>
      )}

      {status && !running && status.state === "ready" && (
        <div className="space-y-2">
          <p className="text-sm">
            Export tejto organizácie je rozpracovaný (nedokončil sa)
            {status.lockActive ? " a razenia sú zamknuté" : ""}. Zrušte ho a spustite znova.
          </p>
          <Button type="button" variant="outline" disabled={busy} onClick={() => void cancel()}>
            Zrušiť rozpracovaný prenos
          </Button>
        </div>
      )}

      {status && !running && status.state === "exported" && (
        <div className="space-y-3">
          <p className="text-sm font-semibold">
            Export organizácie „{status.name}“ je hotový
            {status.isTest ? ", organizácia je označená ako testovacia" : ""}
            {status.lockActive ? " a razenia sú zamknuté" : ""}.
          </p>

          {result ? (
            <div className="space-y-1 text-sm">
              <p>
                Súbor <strong>{result.fileName}</strong> ({formatSize(result.blob.size)},{" "}
                {result.rows} riadkov) sa stiahol do vášho počítača. Uložte ho na bezpečné miesto a
                heslo si zapíšte zvlášť.
              </p>
              <Button
                type="button"
                variant="outline"
                onClick={() => download(result.blob, result.fileName)}
              >
                Stiahnuť súbor znova
              </Button>
              {checking && <p role="status">Kontrolujem súbor…</p>}
              {verified && (
                <p role="status">
                  Súbor je skontrolovaný: dešifruje sa a všetky tabuľky sú úplné ({verified.rows}{" "}
                  riadkov).
                </p>
              )}
              {verifyError && (
                <p role="alert" className="text-destructive">
                  Súbor sa nepodarilo skontrolovať: {verifyError} Export zopakujte.
                </p>
              )}
            </div>
          ) : (
            <p className="text-sm">
              Šifrovaný súbor tento prehliadač už nemá (stránka sa medzitým načítala znova). Ak ho
              máte uložený, môžete ho skontrolovať nižšie. Ak nie, zrušte prenos a export zopakujte.
            </p>
          )}

          <FileCheck status={status} />

          <TransferDestination transferId={status.transferId} />

          {status.hasChanges && (
            <div role="alert" className="space-y-2 border-2 border-destructive p-2 text-sm">
              <p className="font-semibold">
                Od exportu sa údaje zmenili: {describeChanges(status.changes)}.
              </p>
              <p>
                Cieľový server tieto zmeny nemá. Zopakujte export, alebo výslovne potvrďte, že sa
                môžu stratiť.
              </p>
              <Checkbox
                id="transfer-accept-changes"
                checked={acceptChanges}
                onChange={setAcceptChanges}
              >
                Rozumiem, že tieto zmeny sa stratia.
              </Checkbox>
            </div>
          )}

          {!status.protectedOrganization ? (
            <form
              className="space-y-2"
              onSubmit={(e) => {
                e.preventDefault();
                setQueuesEmpty(false);
                setDialogError(null);
                if (canDelete) setDialogOpen(true);
              }}
            >
              <p className="text-sm">
                Na cieľovom serveri zaregistrujte organizáciu a importujte súbor. Cieľový server po
                úspešnom importe vypíše kód potvrdenia (XXXX-XXXX). Až s ním možno pôvodnú
                organizáciu zrušiť.
              </p>
              <label className="block text-sm font-semibold" htmlFor="transfer-receipt">
                Kód potvrdenia z cieľového servera
              </label>
              <Input
                id="transfer-receipt"
                autoComplete="off"
                className="num"
                placeholder="XXXX-XXXX"
                value={receipt}
                onChange={(e) => setReceipt(e.target.value)}
              />
              <label className="block text-sm font-semibold" htmlFor="transfer-confirm-name">
                Na potvrdenie napíšte názov organizácie presne tak, ako je zapísaný
              </label>
              <Input
                id="transfer-confirm-name"
                autoComplete="off"
                value={typedName}
                onChange={(e) => setTypedName(e.target.value)}
                placeholder={status.name}
              />
              <Button type="submit" variant="destructive" disabled={busy || !canDelete}>
                Zrušiť pôvodnú organizáciu…
              </Button>
            </form>
          ) : (
            <p className="text-sm">
              Pôvodnú organizáciu nemožno zrušiť. Po skončení prenosu ho ukončite, aby sa odomkli
              razenia.
            </p>
          )}

          <Button type="button" variant="outline" disabled={busy} onClick={() => void cancel()}>
            {status.protectedOrganization
              ? "Ukončiť prenos"
              : "Zrušiť prenos (organizácia ostane tu)"}
          </Button>
        </div>
      )}

      {message && (
        <p
          role={message.ok ? "status" : "alert"}
          className={`text-sm ${message.ok ? "" : "text-destructive"}`}
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
            <AlertDialogTitle>
              Zrušiť pôvodnú organizáciu „{status?.name}“ natrvalo?
            </AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div className="space-y-2 text-sm">
                <p>
                  Natrvalo sa zmaže{contents ? `: ${describeContents(contents)}` : " organizácia"},
                  jej nastavenia a všetky prihlasovacie účty vrátane vášho. Nedá sa to vrátiť. Údaje
                  budú už len v súbore a na cieľovom serveri.
                </p>
                <p>
                  Razenia, ktoré ešte čakajú vo fronte na termináloch napojených na tento server, sa
                  zrušením stratia (terminál ich nemá kam odoslať).
                </p>
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <Checkbox
            id="transfer-queues-empty"
            checked={queuesEmpty}
            onChange={setQueuesEmpty}
            disabled={busy}
          >
            Overil som, že na každom termináli je „čaká na odoslanie: 0“.
          </Checkbox>
          {dialogError && (
            <p role="alert" className="text-sm text-destructive">
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
              Nezrušiť
            </Button>
            <Button
              type="button"
              variant="destructive"
              disabled={busy || !queuesEmpty}
              onClick={() => void remove()}
            >
              {busy ? "Ruším…" : "Zrušiť organizáciu natrvalo"}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </section>
  );
}
