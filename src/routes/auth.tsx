import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

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
  const [mode, setMode] = useState<"in" | "up">("in");
  const [f, setF] = useState({ email: "", password: "", name: "" });
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
      const { error } = await supabase.auth.signUp({
        email: f.email, password: f.password,
        options: { emailRedirectTo: window.location.origin, data: { full_name: f.name } },
      });
      setMsg(error ? error.message : "Skontrolujte e-mail a potvrďte registráciu.");
    }
    setBusy(false);
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-secondary px-4">
      <form onSubmit={submit} className="w-full max-w-sm space-y-4 rounded-sm border-t-8 border-primary bg-card p-6 shadow-[6px_6px_0_0_var(--primary)]">
        <div>
          <div className="text-2xl font-black uppercase">Dochádzka</div>
          <div className="text-sm text-muted-foreground">{mode === "in" ? "Prihlásenie" : "Registrácia zamestnanca"}</div>
        </div>
        {mode === "up" && <Input required placeholder="Meno a priezvisko" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />}
        <Input required type="email" placeholder="Pracovný e-mail" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} />
        <Input required type="password" minLength={8} placeholder="Heslo" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} />
        <Button type="submit" className="w-full" disabled={busy}>{mode === "in" ? "Prihlásiť" : "Zaregistrovať"}</Button>
        {msg && <p className="text-sm">{msg}</p>}
        <button type="button" className="w-full text-center text-sm underline" onClick={() => { setMode(mode === "in" ? "up" : "in"); setMsg(null); }}>
          {mode === "in" ? "Nemáte účet? Registrácia" : "Máte účet? Prihlásenie"}
        </button>
        <p className="text-xs text-muted-foreground">Prihlásenie cez Microsoft 365 bude doplnené po dodaní údajov od IT.</p>
      </form>
    </div>
  );
}
