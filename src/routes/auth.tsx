import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { organizationSignupMetadata } from "@/lib/organization-registration";

export const Route = createFileRoute("/auth")({
  head: () => ({
    meta: [
      { title: "Prihlásenie – Dochádzka" },
      { name: "description", content: "Prihlásenie do dochádzkového systému." },
      { property: "og:title", content: "Prihlásenie – Dochádzka" },
      { property: "og:description", content: "Prihlásenie do dochádzkového systému." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: AuthPage,
});

function AuthPage() {
  const navigate = useNavigate();
  const [mode, setMode] = useState<"in" | "up" | "organization">("in");
  const [f, setF] = useState({ email: "", password: "", name: "", organization: "", invite: "" });
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { if (data.session) navigate({ to: "/terminal" }); });
  }, [navigate]);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setMsg(null);
    if (mode === "in") {
      const { error } = await supabase.auth.signInWithPassword({ email: f.email, password: f.password });
      if (error) setMsg("Nesprávny e-mail alebo heslo.");
      else navigate({ to: "/terminal" });
    } else {
      try {
      const metadata = organizationSignupMetadata(mode === 'organization' ? { kind: 'organization', name: f.organization } : { kind: 'employee', invite: f.invite });
      const { data, error } = await supabase.auth.signUp({
        email: f.email, password: f.password,
        options: { emailRedirectTo: window.location.origin, data: { full_name: f.name.trim(), ...metadata } },
      });
      if (data.session) navigate({ to: '/terminal' });
      setMsg(error ? (error.message.includes('Database error') ? 'Registrácia sa nepodarila. Skontrolujte pozývací kód a údaje organizácie.' : error.message) : "Skontrolujte e-mail a potvrďte registráciu.");
      } catch { setMsg('Skontrolujte názov firmy alebo pozývací kód od správcu.'); }
    }
    setBusy(false);
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-secondary px-4">
      <form onSubmit={submit} className="w-full max-w-sm space-y-4 rounded-sm border-t-8 border-primary bg-card p-6 shadow-[6px_6px_0_0_var(--primary)]">
        <div>
          <div className="text-2xl font-black uppercase">Dochádzka</div>
          <div className="text-sm text-muted-foreground">{mode === "in" ? "Prihlásenie" : mode === 'organization' ? "Registrácia organizácie / firmy" : "Registrácia zamestnanca"}</div>
        </div>
        {mode !== "in" && <Input required maxLength={160} aria-label="Meno a priezvisko" placeholder="Meno a priezvisko" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />}
        {mode === 'organization' && <Input required minLength={2} maxLength={160} aria-label="Názov organizácie / firmy" placeholder="Názov organizácie / firmy" value={f.organization} onChange={e => setF({ ...f, organization: e.target.value })} />}
        {mode === 'up' && <Input required maxLength={48} aria-label="Pozývací kód organizácie" placeholder="Pozývací kód organizácie" value={f.invite} onChange={e => setF({ ...f, invite: e.target.value.trim() })} />}
        <Input required type="email" placeholder="Pracovný e-mail" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} />
        <Input required type="password" minLength={8} placeholder="Heslo" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} />
        <Button type="submit" className="w-full" disabled={busy}>{mode === "in" ? "Prihlásiť" : mode === 'organization' ? "Zaregistrovať firmu" : "Zaregistrovať"}</Button>
        {msg && <p className="text-sm">{msg}</p>}
        <div className="flex flex-wrap justify-center gap-1">
          {mode !== 'organization' && <Button type="button" variant="link" onClick={() => { setMode('organization'); setMsg(null); }}>Registrovať organizáciu / firmu</Button>}
          {mode !== 'up' && <Button type="button" variant="link" onClick={() => { setMode('up'); setMsg(null); }}>Mám pozývací kód</Button>}
          {mode !== 'in' && <Button type="button" variant="link" onClick={() => { setMode('in'); setMsg(null); }}>Máte účet? Prihlásenie</Button>}
        </div>
      </form>
    </div>
  );
}
