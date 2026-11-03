import { useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import type { ProvisionRow } from "@/lib/accounts-core";
import { provisionEmployees } from "@/lib/accounts.functions";
import { formatCode, orgCodeOf } from "@/lib/credentials";
import { parseNumberList } from "@/lib/onboarding-logic";
import { useAuth } from "@/lib/auth";

const STATUS_LABELS: Record<ProvisionRow["status"], string> = {
  created: "Nový účet",
  reissued: "Nový PIN (účet ešte nebol dokončený)",
  reset: "Obnovené (staré heslo zrušené)",
  exists: "Už má účet, preskočené",
  self: "Vlastný účet, preskočené",
  failed: "Nepodarilo sa",
};

const CHUNK = 25;

function csvOf(rows: ProvisionRow[]): string {
  const lines = rows
    .filter((r) => r.pin)
    .map(
      (r) =>
        `${r.number};${r.pin};${r.expiresAt ? new Date(r.expiresAt).toLocaleString("sk-SK") : ""}`,
    );
  return "\uFEFFosobne_cislo;pin;platne_do\r\n" + lines.join("\r\n") + "\r\n";
}

// Správca pridá osobné čísla (vložením alebo CSV z Accessu) a dostane jednorazové PIN-y.
export function EmployeeAccess() {
  const { organization } = useAuth();
  const [text, setText] = useState("");
  const [reset, setReset] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [rows, setRows] = useState<ProvisionRow[] | null>(null);

  const parsed = useMemo(() => parseNumberList(text), [text]);
  const orgCode = organization ? formatCode(orgCodeOf(organization.id)) : "";
  const loginUrl =
    organization && typeof window !== "undefined"
      ? `${window.location.origin}/auth?o=${orgCodeOf(organization.id)}`
      : "";

  async function loadFile(file: File | undefined) {
    if (!file) return;
    setText(await file.text());
  }

  async function issue() {
    setBusy(true);
    setError(null);
    setRows(null);
    const collected: ProvisionRow[] = [];
    try {
      for (let i = 0; i < parsed.valid.length; i += CHUNK) {
        const r = await provisionEmployees({
          data: { numbers: parsed.valid.slice(i, i + CHUNK), reset },
        });
        if (!r.ok) {
          setError(r.error);
          break;
        }
        collected.push(...r.rows);
        setRows([...collected]);
      }
      setText("");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Vydanie PIN-ov sa nepodarilo.");
      setRows(collected.length > 0 ? [...collected] : null);
    } finally {
      setBusy(false);
    }
  }

  function download() {
    if (!rows) return;
    const url = URL.createObjectURL(new Blob([csvOf(rows)], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = "pin-zamestnanci.csv";
    link.click();
    URL.revokeObjectURL(url);
  }

  return (
    <section className="rounded-sm border-2 border-foreground bg-card p-4">
      <h2 className="mb-3 text-sm font-bold uppercase tracking-widest">
        Prístup zamestnancov (osobné čísla a PIN)
      </h2>
      <p className="mb-2 text-sm">
        Kód organizácie pre zamestnancov: <span className="num font-bold">{orgCode}</span>
        {loginUrl && (
          <>
            {" "}
            · odkaz na prihlásenie: <span className="break-all">{loginUrl}</span>
          </>
        )}
      </p>
      <p className="mb-3 text-xs text-muted-foreground">
        Vložte osobné čísla (každé na nový riadok) alebo nahrajte CSV z Accessu. Stačia čísla, mená
        nie sú potrebné. Zamestnanec sa prvýkrát prihlási kódom organizácie, osobným číslom a PIN-om
        a nastaví si vlastné heslo. PIN platí 24 hodín.
      </p>
      <textarea
        className="mb-2 h-28 w-full rounded-sm border-2 border-foreground bg-background p-2 font-mono text-sm"
        aria-label="Osobné čísla zamestnancov"
        placeholder={"4002012\n4002013"}
        value={text}
        onChange={(e) => setText(e.target.value)}
      />
      <div className="mb-2 flex flex-wrap items-center gap-3">
        <input
          type="file"
          accept=".csv,.txt,text/csv,text/plain"
          aria-label="Nahrať CSV so zoznamom osobných čísel"
          onChange={(e) => loadFile(e.target.files?.[0])}
        />
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={reset} onChange={(e) => setReset(e.target.checked)} />
          Obnoviť aj účty, ktoré už majú heslo (zruší heslo a prihlásenia)
        </label>
      </div>
      <p className="mb-2 text-sm" role="status">
        Platných čísel: <strong>{parsed.valid.length}</strong>
        {parsed.duplicates > 0 && <> · duplicity: {parsed.duplicates}</>}
        {parsed.invalid.length > 0 && (
          <span className="text-destructive">
            {" "}
            · neplatné ({parsed.invalid.length}): {parsed.invalid.slice(0, 5).join(", ")}
            {parsed.invalid.length > 5 ? "…" : ""} (číslo má 7 alebo 8 číslic; v Exceli dajte stĺpec
            ako text, aby sa nestratili počiatočné nuly)
          </span>
        )}
      </p>
      <Button onClick={issue} disabled={busy || parsed.valid.length === 0}>
        {busy ? "Vydávam…" : `Vydať PIN (${parsed.valid.length})`}
      </Button>
      {error && (
        <p role="alert" className="mt-2 text-sm text-destructive">
          {error}
        </p>
      )}
      {rows && (
        <div className="mt-4">
          <p className="mb-2 text-sm font-bold text-destructive">
            PIN-y sa zobrazia len teraz a nikde sa neukladajú v čitateľnej podobe. Odovzdajte ich
            každému zamestnancovi osobne a súbor po použití zmažte.
          </p>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b-2 border-foreground text-left text-xs uppercase">
                  <th className="py-1">Osobné číslo</th>
                  <th>Stav</th>
                  <th>PIN</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.number} className="border-b border-border">
                    <td className="num py-1">{r.number}</td>
                    <td>
                      {STATUS_LABELS[r.status]}
                      {r.warning && <span className="text-destructive"> · {r.warning}</span>}
                    </td>
                    <td className="num font-bold tracking-widest">{r.pin ?? ""}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="mt-3 flex gap-2">
            <Button variant="outline" onClick={download} disabled={!rows.some((r) => r.pin)}>
              Stiahnuť CSV s PIN-mi
            </Button>
            <Button variant="outline" onClick={() => setRows(null)}>
              Skryť PIN-y
            </Button>
          </div>
        </div>
      )}
    </section>
  );
}
