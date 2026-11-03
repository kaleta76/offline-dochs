import { useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { MonthPicker } from "@/components/MonthTable";
import { Button } from "@/components/ui/button";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { loadMonth } from "@/lib/month";
import { importTestPunches, setTestMode, type TestImportResult } from "@/lib/test-import.functions";
import { buildBalanceCsv, TEST_MODE_KEY, type BalanceDay } from "@/lib/test-import";

function download(name: string, content: string) {
  const url = URL.createObjectURL(new Blob([content], { type: "text/csv;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  URL.revokeObjectURL(url);
}

// Testovacia prevádzka: import razení z CSV (len keď je zapnutá) a saldá za mesiac na porovnanie s Accessom.
export function TestImport() {
  const { organization, session } = useAuth();
  const qc = useQueryClient();
  const fileRef = useRef<HTMLInputElement>(null);
  const [csv, setCsv] = useState<{ name: string; text: string } | null>(null);
  const [busy, setBusy] = useState<"mode" | "check" | "import" | "balance" | null>(null);
  const [result, setResult] = useState<TestImportResult | null>(null);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const now = new Date();
  const [ym, setYm] = useState({ y: now.getFullYear(), m: now.getMonth() + 1 });

  const mode = useQuery({
    queryKey: ["test-mode", organization?.id, session?.user.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("organization_settings")
        .select("value")
        .eq("key", TEST_MODE_KEY)
        .maybeSingle();
      if (error) throw error;
      return data?.value === "1";
    },
  });
  const enabled = mode.data === true;

  async function toggle() {
    setBusy("mode");
    setMessage(null);
    try {
      await setTestMode({ data: { enabled: !enabled } });
      await qc.invalidateQueries({ queryKey: ["test-mode"] });
      setResult(null);
    } catch (error) {
      setMessage({ ok: false, text: error instanceof Error ? error.message : "Prepnutie sa nepodarilo." });
    } finally {
      setBusy(null);
    }
  }

  async function run(dryRun: boolean) {
    if (!csv) return;
    setBusy(dryRun ? "check" : "import");
    setMessage(null);
    try {
      const r = await importTestPunches({ data: { csv: csv.text, dryRun } });
      setResult(r);
      if (r.issues.length > 0) {
        setMessage({ ok: false, text: `Súbor má ${r.issues.length} chýb, nič sa nezapísalo.` });
      } else if (dryRun) {
        setMessage({
          ok: true,
          text: `Kontrola prešla: ${r.total} razení, z toho ${r.total - r.skippedExisting} nových. Nič sa nezapísalo.`,
        });
      } else {
        setMessage({
          ok: r.chain.ok,
          text: `Zapísaných ${r.inserted} razení, ${r.skippedExisting} už existovalo. Reťaz ${r.chain.ok ? "je v poriadku" : `NIE JE v poriadku (${r.chain.message})`}.`,
        });
      }
    } catch (error) {
      setMessage({ ok: false, text: error instanceof Error ? error.message : "Import sa nepodaril." });
    } finally {
      setBusy(null);
    }
  }

  async function balances() {
    setBusy("balance");
    setMessage(null);
    try {
      const { data, error } = await supabase.from("profiles").select("id, sap_id").order("sap_id");
      if (error) throw error;
      const days: BalanceDay[] = [];
      for (const p of data ?? []) {
        if (!p.sap_id || !/^[0-9]{7,8}$/.test(p.sap_id)) continue;
        const month = await loadMonth(p.id, ym.y, ym.m);
        for (const d of month.days) {
          days.push({
            sap: p.sap_id,
            key: d.key,
            weekend: d.weekend,
            holiday: d.holiday !== null,
            expectedMin: d.expectedMin,
            totalMin: d.totalMin,
            balanceMin: d.balanceMin,
            workMin: d.workMin,
            creditMin: d.creditMin,
            breakMin: d.breakMin,
            open: d.open,
            byCode: d.byCode,
          });
        }
      }
      if (days.length === 0) throw new Error("Nie sú zamestnanci s platným osobným číslom SAP.");
      const name = `terminal_saldo_${ym.y}${String(ym.m).padStart(2, "0")}.csv`;
      download(name, buildBalanceCsv(days));
      setMessage({
        ok: true,
        text: `Stiahnutý súbor ${name}: ${days.length} riadkov. Budúce dni sa počítajú s nulovým saldom.`,
      });
    } catch (error) {
      setMessage({ ok: false, text: error instanceof Error ? error.message : "Saldá sa nepodarilo pripraviť." });
    } finally {
      setBusy(null);
    }
  }

  return (
    <section className="rounded-sm border-2 border-foreground bg-card p-4">
      <h2 className="mb-3 text-sm font-bold uppercase tracking-widest">
        Testovacia prevádzka a porovnanie s Accessom
      </h2>

      <div className="flex flex-wrap items-center gap-3">
        <Button onClick={toggle} disabled={busy !== null || mode.isLoading} variant={enabled ? "destructive" : "default"}>
          {enabled ? "Vypnúť testovaciu prevádzku" : "Zapnúť testovaciu prevádzku"}
        </Button>
        <span className="text-sm" role="status">
          {mode.isLoading ? "Zisťujem stav…" : enabled ? "Testovacia prevádzka je ZAPNUTÁ." : "Testovacia prevádzka je vypnutá."}
        </span>
      </div>
      <p className="mt-2 text-xs text-muted-foreground">
        Zapnite ju iba v testovacej organizácii. Umožní zapísať razenia z CSV za zamestnancov (zdroj „oprava“,
        zariadenie „testovací import“). Zápis ide cez bežnú hash reťaz a každý import sa zapíše do auditu.
        Razenia sa nemažú; chybné razenie sa dá vyradiť žiadosťou o zneplatnenie.
      </p>

      {enabled && (
        <div className="mt-4 space-y-3 border-t-2 border-foreground pt-4">
          <p className="text-sm font-bold">Import razení z CSV</p>
          <p className="text-xs text-muted-foreground">
            Stĺpce: <span className="num">osobne_cislo;datum;cas;kod;smer</span> (dátum RRRR-MM-DD, čas miestny
            HH:MM:SS, smer IN / OUT, kód z číselníka). Zamestnanci musia byť už pridaní v časti Zamestnanci.
            Najprv spustite kontrolu: pri chybe sa nezapíše nič.
          </p>
          <div className="flex flex-wrap items-center gap-3">
            <input
              ref={fileRef}
              type="file"
              accept=".csv,text/csv,text/plain"
              aria-label="Súbor s razeniami (.csv)"
              onChange={async (e) => {
                const file = e.target.files?.[0];
                setResult(null);
                setMessage(null);
                setCsv(file ? { name: file.name, text: await file.text() } : null);
              }}
            />
            <Button variant="outline" onClick={() => run(true)} disabled={!csv || busy !== null}>
              {busy === "check" ? "Kontrolujem…" : "Skontrolovať"}
            </Button>
            <Button onClick={() => run(false)} disabled={!csv || busy !== null}>
              {busy === "import" ? "Zapisujem…" : "Importovať"}
            </Button>
          </div>
          {result && (
            <div className="text-sm">
              {result.persons.length > 0 && (
                <table className="num mb-2 border-collapse text-xs">
                  <thead>
                    <tr>
                      <th className="border px-2 py-1 text-left">Osobné číslo</th>
                      <th className="border px-2 py-1 text-right">Razení</th>
                      <th className="border px-2 py-1 text-left">Od</th>
                      <th className="border px-2 py-1 text-left">Do</th>
                    </tr>
                  </thead>
                  <tbody>
                    {result.persons.map((p) => (
                      <tr key={p.sap}>
                        <td className="border px-2 py-1">{p.sap}</td>
                        <td className="border px-2 py-1 text-right">{p.count}</td>
                        <td className="border px-2 py-1">{p.first}</td>
                        <td className="border px-2 py-1">{p.last}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
              {result.duplicatesInFile > 0 && (
                <p className="text-xs">Opakujúce sa riadky v súbore (vynechané): {result.duplicatesInFile}.</p>
              )}
              {result.issues.length > 0 && (
                <ul role="alert" className="list-disc pl-5 text-xs text-destructive">
                  {result.issues.slice(0, 30).map((i, n) => (
                    <li key={n}>
                      {i.line > 0 ? `Riadok ${i.line}: ` : ""}
                      {i.text}
                    </li>
                  ))}
                  {result.issues.length > 30 && <li>… a ďalších {result.issues.length - 30} chýb.</li>}
                </ul>
              )}
            </div>
          )}
        </div>
      )}

      <div className="mt-4 space-y-2 border-t-2 border-foreground pt-4">
        <p className="text-sm font-bold">Saldá za mesiac pre porovnanie s Accessom</p>
        <div className="flex flex-wrap items-center gap-3">
          <MonthPicker ym={ym} onChange={setYm} />
          <Button variant="outline" onClick={balances} disabled={busy !== null}>
            {busy === "balance" ? "Počítam…" : "Stiahnuť saldá (.csv)"}
          </Button>
        </div>
        <p className="text-xs text-muted-foreground">
          Súbor obsahuje za každý deň a zamestnanca fond, odpracované minúty a saldo tak, ako ich vidí
          zamestnanec v termináli. Porovnáte ho so súborom <span className="num">terminal_test_access_vysledky.csv</span>{" "}
          z Accessu skriptom <span className="num">porovnaj.py</span>.
        </p>
      </div>

      {message && (
        <p role={message.ok ? "status" : "alert"} className={`mt-3 text-sm ${message.ok ? "" : "text-destructive"}`}>
          {message.text}
        </p>
      )}
    </section>
  );
}
