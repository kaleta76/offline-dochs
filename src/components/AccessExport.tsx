import { useState } from "react";
import { MonthPicker } from "@/components/MonthTable";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { exportPunches } from "@/lib/punch-export.functions";
import { exportVoids } from "@/lib/void-export.functions";

// Export razení pre dochádzkový systém (Access), kontrakt v1 (contract/README.md).
export function AccessExport() {
  const now = new Date();
  const [ym, setYm] = useState({ y: now.getFullYear(), m: now.getMonth() + 1 });
  const [incremental, setIncremental] = useState(false);
  const [sinceId, setSinceId] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);

  async function download() {
    setBusy(true);
    setMessage(null);
    try {
      const since = incremental ? Number(sinceId) : undefined;
      if (since !== undefined && (!Number.isInteger(since) || since < 0)) {
        throw new Error("Zadajte ID razenia ako celé číslo (0 alebo viac).");
      }
      const result = await exportPunches({
        data: { year: ym.y, month: ym.m, ...(since !== undefined ? { sinceId: since } : {}) },
      });
      if (result.rows === 0) {
        setMessage({
          ok: true,
          text: "Za zvolené obdobie nie sú žiadne razenia, súbor sa nevytvoril.",
        });
        return;
      }
      const url = URL.createObjectURL(new Blob([result.csv], { type: "text/csv;charset=utf-8" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = result.filename;
      link.click();
      URL.revokeObjectURL(url);
      setMessage({
        ok: true,
        text: `Stiahnutý súbor ${result.filename}: ${result.rows} riadkov, najvyššie ID razenia ${result.maxPunchId}. Toto ID použite pri ďalšom prírastkovom exporte.`,
      });
    } catch (error) {
      setMessage({
        ok: false,
        text: error instanceof Error ? error.message : "Export sa nepodaril.",
      });
    } finally {
      setBusy(false);
    }
  }

  async function downloadVoids() {
    setBusy(true);
    setMessage(null);
    try {
      const result = await exportVoids({ data: { year: ym.y, month: ym.m } });
      if (result.rows === 0) {
        setMessage({ ok: true, text: "Za zvolený mesiac nie sú žiadne zneplatnené razenia, súbor sa nevytvoril." });
        return;
      }
      const url = URL.createObjectURL(new Blob([result.csv], { type: "text/csv;charset=utf-8" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = result.filename;
      link.click();
      URL.revokeObjectURL(url);
      setMessage({
        ok: true,
        text: `Stiahnutý súbor ${result.filename}: ${result.rows} zneplatnených razení. Importujte ho v Accesse až po súbore s razeniami za ten istý mesiac.`,
      });
    } catch (error) {
      setMessage({ ok: false, text: error instanceof Error ? error.message : "Export sa nepodaril." });
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="rounded-sm border-2 border-foreground bg-card p-4">
      <h2 className="mb-3 text-sm font-bold uppercase tracking-widest">
        Export pre dochádzkový systém (Access)
      </h2>
      <div className="flex flex-wrap items-center gap-3">
        <MonthPicker ym={ym} onChange={setYm} />
        <label className="inline-flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={incremental}
            onChange={(e) => setIncremental(e.target.checked)}
          />
          Iba prírastok od ID
        </label>
        {incremental && (
          <Input
            aria-label="Exportovať razenia s ID vyšším ako"
            inputMode="numeric"
            placeholder="napr. 1500"
            value={sinceId}
            onChange={(e) => setSinceId(e.target.value.replace(/\D/g, ""))}
            className="num w-32"
          />
        )}
        <Button onClick={download} disabled={busy || (incremental && sinceId === "")}>
          {busy ? "Pripravujem…" : "Stiahnuť .csv"}
        </Button>
        <Button variant="outline" onClick={downloadVoids} disabled={busy}>
          Zneplatnené razenia (.csv)
        </Button>
      </div>
      <p className="mt-2 text-xs text-muted-foreground">
        Súbor obsahuje len osobné čísla SAP a časy razení (bez mien). Pri prírastku sa mesiac
        ignoruje a exportujú sa všetky razenia s vyšším ID; Access duplicity vyradí sám. Zneplatnené razenia
        zostávajú v súbore razení (kvôli reťazi hashov), preto ich Access dostane v samostatnom súbore za zvolený mesiac.
      </p>
      {message && (
        <p
          role={message.ok ? "status" : "alert"}
          className={`mt-2 text-sm ${message.ok ? "" : "text-destructive"}`}
        >
          {message.text}
        </p>
      )}
    </section>
  );
}
