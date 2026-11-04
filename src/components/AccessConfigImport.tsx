import { useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { supabase } from "@/integrations/supabase/client";
import {
  checkAccessConfig,
  countEmployees,
  countMonths,
  describeImportResult,
  formatConfigVersion,
  formatMonth,
  MAX_FILE_BYTES,
  parseConfigText,
  parseImportResult,
  type ConfigCheck,
  type ImportResult,
} from "@/lib/access-config";

// Import konfigurácie a výpočtového plánu z Accessu (kontrakt 1.2.0, docs/KONFIGURACIA-Z-ACCESSU.md).
// Správca nahrá súbor dochs_config.json; aplikácia ho skontroluje, databáza ho skontroluje znova a zapíše ho celý alebo vôbec.
// Všetko beží pod prihlásením správcu, bez service role: o oprávnení rozhoduje databáza.

type LooseRpc = {
  rpc(
    fn: string,
    args: Record<string, unknown>,
  ): PromiseLike<{ data: unknown; error: { message: string } | null }>;
};
// Typy klienta vznikajú automaticky z databázy a novú funkciu ešte nepoznajú.
const db = supabase as unknown as LooseRpc;

const SHOWN_ISSUES = 30;

type Loaded = { name: string; doc: unknown; check: ConfigCheck };

function friendly(message: string): string {
  if (/schema cache|Could not find the function|does not exist/i.test(message)) {
    return "Databáza ešte nemá import konfigurácie. Najprv treba spustiť migráciu 0008 (súkromný SQL balík).";
  }
  if (/statement timeout|canceling statement/i.test(message)) {
    return "Spracovanie trvalo príliš dlho a databáza ho prerušila. Nič sa nezapísalo; súbor je pravdepodobne príliš veľký, napíšte nám.";
  }
  return message;
}

export function AccessConfigImport() {
  const fileRef = useRef<HTMLInputElement>(null);
  const seq = useRef(0); // číta sa len naposledy vybraný súbor
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [preview, setPreview] = useState<ImportResult | null>(null);
  const [done, setDone] = useState<ImportResult | null>(null);
  const [busy, setBusy] = useState<"read" | "preview" | "import" | null>(null);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);

  function reset(keepDone = false) {
    setLoaded(null);
    setLoadError(null);
    setPreview(null);
    setMessage(null);
    if (!keepDone) setDone(null);
  }

  async function onFile(file: File | undefined) {
    const mine = ++seq.current;
    reset();
    if (!file) return;
    if (file.size > MAX_FILE_BYTES) {
      setLoadError(
        `Súbor má ${Math.round(file.size / 1e6)} MB, najviac je ${MAX_FILE_BYTES / 1e6} MB.`,
      );
      return;
    }
    setBusy("read");
    try {
      const parsed = parseConfigText(await file.text());
      if (mine !== seq.current) return;
      if ("error" in parsed) {
        setLoadError(parsed.error);
        return;
      }
      setLoaded({ name: file.name, doc: parsed.doc, check: checkAccessConfig(parsed.doc) });
    } catch {
      if (mine === seq.current) setLoadError("Súbor sa nepodarilo prečítať.");
    } finally {
      if (mine === seq.current) setBusy(null);
    }
  }

  async function run(dryRun: boolean) {
    if (!loaded || loaded.check.errors.length > 0) return;
    setBusy(dryRun ? "preview" : "import");
    setMessage(null);
    try {
      const { data, error } = await db.rpc("import_access_config", {
        _payload: loaded.doc,
        _dry_run: dryRun,
      });
      if (error) {
        setMessage({ ok: false, text: friendly(error.message) });
        return;
      }
      const result = parseImportResult(data);
      if (!result) {
        setMessage({
          ok: false,
          text: "Neočakávaná odpoveď databázy, nič sa nepovažuje za zapísané.",
        });
        return;
      }
      if (dryRun) {
        setPreview(result);
        return;
      }
      setDone(result);
      reset(true);
      if (fileRef.current) fileRef.current.value = "";
    } catch (error) {
      setMessage({
        ok: false,
        text: friendly(error instanceof Error ? error.message : "Spojenie s databázou zlyhalo."),
      });
    } finally {
      setBusy(null);
    }
  }

  const check = loaded?.check;
  const canPreview = !!loaded && !!check && check.errors.length === 0 && busy === null;
  const canImport = canPreview && preview !== null && preview.status === "preview";

  return (
    <section className="rounded-sm border-2 border-foreground bg-card p-4">
      <h2 className="mb-3 text-sm font-bold uppercase tracking-widest">Konfigurácia z Accessu</h2>
      <p className="text-xs text-muted-foreground">
        Nahrajte súbor <span className="num">dochs_config.json</span> vytvorený v Accesse (karta
        Exporty, tlačidlo „Vytvoriť verziu konfigurácie prerušení pre terminál“). Najprv sa ukáže
        náhľad a nič sa nezapíše. Súbor sa zapíše celý alebo vôbec; staršia verzia, než je prijatá,
        sa neprijme. Súbor nesmie obsahovať mená ani iné osobné údaje, zamestnanec je v ňom len
        osobné číslo.
      </p>

      <div className="mt-3 flex flex-wrap items-center gap-3">
        <input
          ref={fileRef}
          type="file"
          accept=".json,application/json"
          aria-label="Súbor konfigurácie z Accessu (.json)"
          disabled={busy === "preview" || busy === "import"}
          onChange={(e) => void onFile(e.target.files?.[0])}
        />
        <Button variant="outline" onClick={() => void run(true)} disabled={!canPreview}>
          {busy === "preview" ? "Pripravujem náhľad…" : "Náhľad (nič sa nezapíše)"}
        </Button>
        <Button onClick={() => void run(false)} disabled={!canImport}>
          {busy === "import" ? "Zapisujem…" : "Prijať konfiguráciu"}
        </Button>
      </div>

      {loadError && (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {loadError}
        </p>
      )}

      {loaded && check && (
        <div className="mt-3 space-y-2 text-sm">
          {check.errors.length > 0 ? (
            <>
              <p role="alert" className="font-bold text-destructive">
                Súbor „{loaded.name}“ má {check.errors.length} chýb, nedá sa prijať. Opravte ich v
                Accesse a export zopakujte.
              </p>
              <ul className="list-disc pl-5 text-xs text-destructive">
                {check.errors.slice(0, SHOWN_ISSUES).map((e, i) => (
                  <li key={i}>{e}</li>
                ))}
                {check.errors.length > SHOWN_ISSUES && (
                  <li>… a ďalších {check.errors.length - SHOWN_ISSUES} chýb.</li>
                )}
              </ul>
            </>
          ) : (
            check.summary && (
              <p role="status">
                Súbor „{loaded.name}“ je v poriadku: verzia{" "}
                <span className="num">{formatConfigVersion(check.summary.configVersion)}</span>,{" "}
                {countEmployees(check.summary.employees)},{" "}
                {countMonths(check.summary.employeeMonths)}, okno{" "}
                {formatMonth(check.summary.periodFrom)} až {formatMonth(check.summary.periodTo)}.
              </p>
            )
          )}
          {check.warnings.length > 0 && (
            <ul className="list-disc pl-5 text-xs">
              {check.warnings.slice(0, SHOWN_ISSUES).map((w, i) => (
                <li key={i}>Upozornenie: {w}</li>
              ))}
              {check.warnings.length > SHOWN_ISSUES && (
                <li>… a ďalších {check.warnings.length - SHOWN_ISSUES} upozornení.</li>
              )}
            </ul>
          )}
        </div>
      )}

      {preview && (
        <div className="mt-3 space-y-2 border-t-2 border-foreground pt-3 text-sm" role="status">
          <p className="font-bold">Náhľad z databázy</p>
          <p>{describeImportResult(preview)}</p>
          {preview.previousVersion && (
            <p className="text-xs text-muted-foreground">
              Teraz platí verzia{" "}
              <span className="num">{formatConfigVersion(preview.previousVersion)}</span>.
            </p>
          )}
          <WithoutAccount result={preview} />
          {preview.status === "unchanged" && (
            <p className="text-xs text-muted-foreground">Nie je čo prijímať.</p>
          )}
        </div>
      )}

      {done && (
        <div className="mt-3 space-y-2 border-t-2 border-foreground pt-3 text-sm" role="status">
          <p className="font-bold">{describeImportResult(done)}</p>
          <WithoutAccount result={done} />
        </div>
      )}

      {message && (
        <p
          role={message.ok ? "status" : "alert"}
          className={`mt-3 text-sm ${message.ok ? "" : "text-destructive"}`}
        >
          {message.text}
        </p>
      )}
    </section>
  );
}

// Osobné čísla, ktoré súbor obsahuje, ale nemajú účet v termináli. Plán sa pre ne uloží, v prehľadoch sa nezobrazujú.
function WithoutAccount({ result }: { result: ImportResult }) {
  if (result.withoutAccountCount === 0) return null;
  const rest = result.withoutAccountCount - result.withoutAccount.length;
  return (
    <p className="text-xs">
      Bez účtu v termináli: {result.withoutAccountCount} (plán sa uloží, v prehľadoch sa nezobrazia)
      {result.withoutAccount.length > 0 && (
        <>
          : <span className="num">{result.withoutAccount.join(", ")}</span>
          {rest > 0 && ` a ďalších ${rest}`}
        </>
      )}
      .
    </p>
  );
}
