import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  describeVersion,
  diffSettings,
  EDITABLE_RULES,
  loadSettingsForMonth,
  loadSettingsTimeline,
  loadVersionConfig,
  monthLabel,
  saveTerminalSettings,
  unpairSettings,
  validFromOptions,
  withHoliday,
  withRule,
  type EditableRule,
  type SettingsModel,
  type UnpairChoice,
} from "@/lib/settings-model";

// Správa → Servis: pravidlá výpočtu a sviatky ako VERZIE s platnosťou od mesiaca (migrácia 0022, docs/VERZIE-NASTAVENI.md).
// Mesiac, ktorý patrí Accessu: všetko len na čítanie s údajom „verzia a dátum importu“ a tlačidlo odpárovania.
// Mesiac, ktorý patrí terminálu: úprava vždy vytvorí novú terminálovú verziu platnú od zvoleného mesiaca.
// Obrazovka nič nevynucuje: či úprava alebo odpárovanie prejde, rozhoduje databáza (zamknutie verzie z Accessu, najstarší neuzavretý mesiac).

/** Kľúč dopytov tejto karty; po zmene verzie sa obnovia aj tlačidlá terminálu a mesačné prehľady. */
export const SETTINGS_QUERY_KEY = "settings-versions";

const box = "rounded-sm border-2 border-foreground bg-card p-4";
const H = ({ children }: { children: React.ReactNode }) => (
  <h2 className="mb-3 text-sm font-bold uppercase tracking-widest">{children}</h2>
);

export function SettingsVersions({ organizationId }: { organizationId: string | undefined }) {
  const qc = useQueryClient();
  const current = useQuery({
    queryKey: [SETTINGS_QUERY_KEY, "current", organizationId],
    enabled: !!organizationId,
    queryFn: () => loadSettingsForMonth(),
  });
  const timeline = useQuery({
    queryKey: [SETTINGS_QUERY_KEY, "timeline", organizationId],
    enabled: !!organizationId,
    queryFn: loadSettingsTimeline,
  });
  const [draft, setDraft] = useState<Partial<Record<EditableRule, string>>>({});
  const [validFrom, setValidFrom] = useState<string | null>(null);
  const [newHol, setNewHol] = useState({ day: "", name: "" });
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const [unpairOpen, setUnpairOpen] = useState(false);

  const refresh = () => {
    void qc.invalidateQueries({ queryKey: [SETTINGS_QUERY_KEY] });
    void qc.invalidateQueries({ queryKey: ["terminal-buttons"] });
    void qc.invalidateQueries({ queryKey: ["team"] });
  };

  if (current.error || timeline.error) {
    const e = current.error ?? timeline.error;
    return (
      <section className={box}>
        <H>Pravidlá výpočtu</H>
        <p role="alert" className="text-sm text-destructive">
          {e instanceof Error ? e.message : "Nastavenia výpočtu sa nepodarilo načítať."}
        </p>
      </section>
    );
  }
  if (!current.data || !timeline.data) {
    return (
      <section className={box}>
        <H>Pravidlá výpočtu</H>
        <p className="text-sm text-muted-foreground">Načítavam…</p>
      </section>
    );
  }

  const s = current.data;
  const t = timeline.data;
  const locked = s.ownedByAccess;
  const from = validFrom ?? t.month_now;
  const rules = s.config.rules as Record<string, unknown>;

  async function save(next: SettingsModel, done: string) {
    setBusy(true);
    setMessage(null);
    try {
      await saveTerminalSettings(next, from);
      setDraft({});
      setMessage({ ok: true, text: `${done} Platí od ${monthLabel(from)}.` });
      refresh();
    } catch (e) {
      setMessage({ ok: false, text: e instanceof Error ? e.message : "Uloženie zlyhalo." });
    } finally {
      setBusy(false);
    }
  }

  function saveRules() {
    let next = s.config;
    for (const r of EDITABLE_RULES) {
      const raw = draft[r.key];
      if (raw === undefined) continue;
      const v = Number(raw.replace(",", "."));
      if (!Number.isInteger(v) || v < r.min || v > r.max) {
        setMessage({ ok: false, text: `${r.label}: zadajte celé číslo ${r.min} až ${r.max}.` });
        return;
      }
      next = withRule(next, r.key, v);
    }
    void save(next, "Pravidlá sú uložené ako nová verzia.");
  }

  const changed = EDITABLE_RULES.some(
    (r) => draft[r.key] !== undefined && draft[r.key] !== String(rules[r.key] ?? 0),
  );

  return (
    <section className={box}>
      <H>Pravidlá výpočtu</H>
      <p className="text-sm">
        Mesiac {monthLabel(s.month)} patrí {locked ? "Accessu" : "terminálu"}.{" "}
        <span className="text-muted-foreground">{describeVersion(s.version)}.</span>
      </p>
      {locked ? (
        <p className="mt-1 text-xs text-muted-foreground">
          Nastavenia výpočtu sú len na čítanie: riadi ich Access. Zmena je možná novým importom
          (karta Prevádzka) alebo odpárovaním.
        </p>
      ) : (
        <p className="mt-1 text-xs text-muted-foreground">
          Úprava vytvorí novú verziu platnú od zvoleného mesiaca; staršie verzie ostávajú uložené.
          Mesiac, ktorý má zamestnanec uzavretý, sa nezmení.
        </p>
      )}

      <div className="mt-3 space-y-2">
        {EDITABLE_RULES.map((r) => (
          <div key={r.key} className="grid grid-cols-[1fr_110px] items-center gap-2">
            <label htmlFor={`rule-${r.key}`} className="text-xs">
              {r.label}
            </label>
            <Input
              id={`rule-${r.key}`}
              inputMode="numeric"
              readOnly={locked}
              disabled={busy}
              value={draft[r.key] ?? String(rules[r.key] ?? 0)}
              onChange={(e) => setDraft({ ...draft, [r.key]: e.target.value })}
            />
          </div>
        ))}
      </div>

      {!locked && (
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <label htmlFor="settings-valid-from" className="text-xs font-semibold">
            Platí od
          </label>
          <select
            id="settings-valid-from"
            className="h-9 rounded-sm border border-input bg-background px-2 text-sm"
            value={from}
            onChange={(e) => setValidFrom(e.target.value)}
          >
            {validFromOptions(t.oldest_open, t.month_now, 3).map((m) => (
              <option key={m} value={m}>
                {monthLabel(m)}
              </option>
            ))}
          </select>
          <Button onClick={saveRules} disabled={busy || !changed}>
            {busy ? "Ukladám…" : "Uložiť pravidlá"}
          </Button>
          <span className="text-xs text-muted-foreground">
            Najstarší neuzavretý mesiac: {monthLabel(t.oldest_open)}.
          </span>
        </div>
      )}

      <h3 className="mb-2 mt-5 text-xs font-bold uppercase tracking-widest">Sviatky</h3>
      {!locked && (
        <form
          className="mb-3 flex gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            void save(withHoliday(s.config, newHol.day, newHol.name.trim()), "Sviatok je pridaný.");
            setNewHol({ day: "", name: "" });
          }}
        >
          <Input
            type="date"
            required
            aria-label="Deň sviatku"
            value={newHol.day}
            onChange={(e) => setNewHol({ ...newHol, day: e.target.value })}
            className="w-40"
          />
          <Input
            required
            maxLength={200}
            placeholder="Názov"
            aria-label="Názov sviatku"
            value={newHol.name}
            onChange={(e) => setNewHol({ ...newHol, name: e.target.value })}
          />
          <Button type="submit" disabled={busy}>
            Pridať
          </Button>
        </form>
      )}
      <ul className="max-h-64 space-y-1 overflow-y-auto text-sm">
        {s.config.holidays.map((h) => (
          <li key={h.date} className="flex justify-between border-b border-border pb-1">
            <span>
              <span className="num">{new Date(h.date).toLocaleDateString("sk-SK")}</span> {h.name}
            </span>
            {!locked && (
              <Button
                variant="link"
                className="text-xs text-destructive"
                disabled={busy}
                onClick={() =>
                  void save(withHoliday(s.config, h.date, null), "Sviatok je odstránený.")
                }
              >
                odstrániť
              </Button>
            )}
          </li>
        ))}
      </ul>

      {message && (
        <p
          role={message.ok ? "status" : "alert"}
          className={`mt-3 text-sm ${message.ok ? "" : "text-destructive"}`}
        >
          {message.text}
        </p>
      )}

      <h3 className="mb-2 mt-5 text-xs font-bold uppercase tracking-widest">Verzie nastavení</h3>
      <ul className="max-h-48 space-y-1 overflow-y-auto text-xs">
        {t.versions.map((v) => (
          <li key={v.id} className={v.id === t.current.id ? "font-bold" : ""}>
            {describeVersion(v)}
            {v.id === t.current.id ? " (platí teraz)" : ""}
          </li>
        ))}
      </ul>

      {locked && (
        <div className="mt-4 border-t-2 border-foreground pt-3">
          {unpairOpen ? (
            <Unpair
              current={s.config}
              monthNow={t.month_now}
              oldestOpen={t.oldest_open}
              accessId={t.last_access?.id ?? null}
              terminalId={t.last_terminal?.id ?? null}
              onCancel={() => setUnpairOpen(false)}
              onDone={(text) => {
                setUnpairOpen(false);
                setMessage({ ok: true, text });
                refresh();
              }}
            />
          ) : (
            <Button variant="outline" onClick={() => setUnpairOpen(true)}>
              Odpárovať od Accessu…
            </Button>
          )}
        </div>
      )}
    </section>
  );
}

function Unpair(props: {
  current: SettingsModel;
  monthNow: string;
  oldestOpen: string;
  accessId: string | null;
  terminalId: string | null;
  onCancel: () => void;
  onDone: (text: string) => void;
}) {
  const [choice, setChoice] = useState<UnpairChoice>("access");
  const [from, setFrom] = useState(props.monthNow);
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const id = choice === "access" ? props.accessId : props.terminalId;
  // Rozdiel sa počíta z obsahu verzie, ktorú databáza skopíruje (tá istá voľba ako v settings_unpair), voči tomu, čo platí teraz.
  const target = useQuery({
    queryKey: [SETTINGS_QUERY_KEY, "config", id],
    enabled: !!id,
    queryFn: () => loadVersionConfig(id!),
  });
  const diff = target.data ? diffSettings(props.current, target.data) : null;

  async function run() {
    setBusy(true);
    setError(null);
    try {
      await unpairSettings(from, choice);
      props.onDone(
        `Organizácia je odpárovaná od Accessu. Od ${monthLabel(from)} platia nastavenia terminálu a dajú sa upravovať.`,
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : "Odpárovanie zlyhalo.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-3 text-sm">
      <p className="font-bold">Odpárovanie od Accessu</p>
      <p className="text-xs">
        Od zvoleného mesiaca prestanú platiť nastavenia z Accessu a výpočet sa bude riadiť
        nastaveniami terminálu. Verzie z Accessu ostanú v histórii, razenia sa nemenia a uzavreté
        mesiace sa nezmenia. Kto používa Access na záväzný výpočet, nemá odpárovať: nastavenia by sa
        rozišli. Opätovné spárovanie je možné novým importom.
      </p>
      <fieldset className="space-y-1">
        <legend className="text-xs font-semibold">S čím terminál pokračuje</legend>
        <label className="flex items-start gap-2">
          <input
            type="radio"
            name="unpair-choice"
            className="mt-1"
            checked={choice === "access"}
            onChange={() => setChoice("access")}
          />
          <span>
            Kópia posledných nastavení z Accessu (pravidlá sa nezmenia, dajú sa potom upraviť)
          </span>
        </label>
        <label className="flex items-start gap-2">
          <input
            type="radio"
            name="unpair-choice"
            className="mt-1"
            checked={choice === "terminal"}
            onChange={() => setChoice("terminal")}
          />
          <span>Posledné nastavenia terminálu spred spárovania</span>
        </label>
      </fieldset>
      <div aria-live="polite">
        <p className="text-xs font-semibold">Čo sa oproti dnešku zmení</p>
        {target.isPending && <p className="text-xs text-muted-foreground">Porovnávam…</p>}
        {target.error && <p className="text-xs text-destructive">Rozdiel sa nepodarilo načítať.</p>}
        {diff && diff.length === 0 && (
          <p className="text-xs">Nič: hodnoty ostanú rovnaké, len sa dajú upravovať.</p>
        )}
        {diff && diff.length > 0 && (
          <ul className="list-disc pl-5 text-xs">
            {diff.map((d, i) => (
              <li key={i}>
                {d.label}: {d.from} → {d.to}
              </li>
            ))}
          </ul>
        )}
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <label htmlFor="unpair-from" className="text-xs font-semibold">
          Platí od
        </label>
        <select
          id="unpair-from"
          className="h-9 rounded-sm border border-input bg-background px-2 text-sm"
          value={from}
          onChange={(e) => setFrom(e.target.value)}
        >
          {validFromOptions(props.oldestOpen, props.monthNow, 3).map((m) => (
            <option key={m} value={m}>
              {monthLabel(m)}
            </option>
          ))}
        </select>
        {from < props.monthNow && (
          <span className="text-xs">
            Skoršia platnosť prepočíta len neuzavreté mesiace zamestnancov.
          </span>
        )}
      </div>
      <label className="flex items-start gap-2">
        <input
          type="checkbox"
          className="mt-1"
          checked={confirmed}
          onChange={(e) => setConfirmed(e.target.checked)}
        />
        <span>Rozumiem: od {monthLabel(from)} sa výpočet neriadi Accessom.</span>
      </label>
      {error && (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      )}
      <div className="flex gap-2">
        <Button
          variant="destructive"
          disabled={!confirmed || busy || !id}
          onClick={() => void run()}
        >
          {busy ? "Odpárujem…" : "Odpárovať"}
        </Button>
        <Button variant="outline" disabled={busy} onClick={props.onCancel}>
          Zrušiť
        </Button>
      </div>
    </div>
  );
}
