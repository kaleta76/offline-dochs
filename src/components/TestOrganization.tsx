import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { confirmationMatches, describeContents, parseDeleteResult, parseSummary } from "@/lib/organization-delete";

// Testovacia organizácia (migrácia 0007): správca ju najprv označí ako testovaciu a potom ju natrvalo zruší aj s razeniami a účtami.
// Ostrú organizáciu zrušiť nejde: databáza to odmietne, kým nie je označená, a pôvodnú organizáciu odmietne vždy.
export function TestOrganization() {
  const { organization, session } = useAuth();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const [typed, setTyped] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  const key = ["test-organization", organization?.id, session?.user.id];

  const summary = useQuery({
    queryKey: key,
    enabled: !!session,
    retry: false,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("test_organization_summary");
      if (error) throw error;
      const parsed = parseSummary(data);
      if (!parsed) throw new Error("Neočakávaná odpoveď databázy.");
      return parsed;
    },
  });
  const s = summary.data;
  const missing = summary.error instanceof Error && /schema cache|Could not find the function/i.test(summary.error.message);

  async function mark(value: boolean) {
    setBusy(true);
    setMessage(null);
    const { error } = await supabase.rpc("set_organization_test", { _is_test: value });
    setBusy(false);
    if (error) {
      setMessage({ ok: false, text: error.message });
      return;
    }
    setTyped("");
    await qc.invalidateQueries({ queryKey: key });
    await qc.invalidateQueries({ queryKey: ["me"] });
    setMessage({ ok: true, text: value ? "Organizácia je označená ako testovacia." : "Organizácia už nie je označená ako testovacia." });
  }

  async function remove() {
    if (!s || !confirmationMatches(s.name, typed)) return;
    setBusy(true);
    setMessage(null);
    const { data, error } = await supabase.rpc("delete_test_organization", { _confirm_name: typed });
    if (error) {
      setBusy(false);
      setMessage({ ok: false, text: error.message });
      return;
    }
    const done = parseDeleteResult(data);
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
    window.alert(`Organizácia „${s.name}“ bola zrušená: ${describeContents(done)}.`);
    navigate({ to: "/auth", replace: true });
  }

  return (
    <section className="space-y-3 rounded-sm border-2 border-destructive bg-card p-4">
      <h2 className="text-sm font-bold uppercase tracking-widest">Testovacia organizácia</h2>
      {summary.isPending && <p className="text-sm text-muted-foreground">Načítavam…</p>}
      {missing && (
        <p role="alert" className="text-sm">
          Táto funkcia ešte nie je v databáze. Najprv treba spustiť migráciu 0007 (docs/migracie/0007_zrusenie_testovacej_organizacie.sql).
        </p>
      )}
      {summary.error && !missing && (
        <p role="alert" className="text-sm text-destructive">
          Údaje sa nepodarilo načítať{summary.error instanceof Error ? `: ${summary.error.message}` : "."}
        </p>
      )}

      {s?.protectedOrganization && (
        <p className="text-sm">Toto je pôvodná organizácia s prevzatými údajmi. Nedá sa označiť ako testovacia ani zrušiť.</p>
      )}

      {s && !s.protectedOrganization && !s.isTest && (
        <>
          <p className="text-sm">
            Ak ide o skúšobnú firmu, označte ju ako testovaciu. Až potom ju bude možné natrvalo zrušiť. Označenie môžete kedykoľvek vrátiť.
            Ostrú prevádzku neoznačujte.
          </p>
          <Button variant="outline" disabled={busy} onClick={() => mark(true)}>
            Označiť „{s.name}“ ako testovaciu
          </Button>
        </>
      )}

      {s && !s.protectedOrganization && s.isTest && (
        <>
          <p className="text-sm font-semibold">Organizácia „{s.name}“ je označená ako testovacia.</p>
          <p className="text-sm">
            Zrušením sa natrvalo zmaže: <strong>{describeContents(s)}</strong>, nastavenia organizácie a všetky prihlasovacie účty vrátane vášho. Nedá sa to vrátiť.
            Ak chcete údaje zachovať, najprv urobte zálohu (docs/ZALOHA-DATABAZY.md).
          </p>
          <form
            className="space-y-2"
            onSubmit={(e) => {
              e.preventDefault();
              void remove();
            }}
          >
            <label className="block text-sm font-semibold" htmlFor="test-organization-confirm">
              Na potvrdenie napíšte názov organizácie presne tak, ako je zapísaný
            </label>
            <Input
              id="test-organization-confirm"
              autoComplete="off"
              value={typed}
              onChange={(e) => setTyped(e.target.value)}
              placeholder={s.name}
            />
            <div className="flex flex-wrap gap-2">
              <Button type="submit" variant="destructive" disabled={busy || !confirmationMatches(s.name, typed)}>
                {busy ? "Ruším…" : "Zrušiť organizáciu natrvalo"}
              </Button>
              <Button type="button" variant="outline" disabled={busy} onClick={() => mark(false)}>
                Vrátiť: nie je testovacia
              </Button>
            </div>
          </form>
        </>
      )}

      {message && (
        <p role={message.ok ? "status" : "alert"} className={`text-sm ${message.ok ? "" : "text-destructive"}`}>
          {message.text}
        </p>
      )}
    </section>
  );
}
