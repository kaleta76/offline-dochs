import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { beginActiveSession, IDLE_MESSAGE, isIdleSignOutPending } from "@/lib/idle-timeout";
import {
  isConnectionFailure,
  OFFLINE_ACTION_MESSAGE,
  OFFLINE_LOGIN_MESSAGE,
  setSessionWithRetry,
} from "@/lib/login-connection";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  employeeLogin,
  enrollEmployee,
  recoverAdmin,
  registerOrganization,
} from "@/lib/accounts.functions";
import {
  browserStorage,
  forgetNumber,
  readRememberedNumber,
  rememberNumber,
} from "@/lib/remembered-number";

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

type Mode = "employee" | "pin" | "in" | "register" | "recover";

const TITLES: Record<Mode, string> = {
  employee: "Prihlásenie",
  pin: "Prvé prihlásenie s PIN-om",
  in: "Prihlásenie e-mailom (správca)",
  register: "Registrácia organizácie / firmy",
  recover: "Obnova hesla správcu",
};

const ORG_KEY = "org-code";

function readOrgCode(): string {
  try {
    const fromLink = new URLSearchParams(window.location.search).get("o");
    if (fromLink) return fromLink.slice(0, 16);
    return window.localStorage.getItem(ORG_KEY) ?? "";
  } catch {
    return "";
  }
}

function rememberOrgCode(code: string) {
  try {
    window.localStorage.setItem(ORG_KEY, code);
  } catch {
    // bez úložiska prihlásenie funguje ďalej, kód sa len nepredvyplní
  }
}

type Issued = { kind: "register" | "recover"; orgCode: string | null; recoveryCode: string };

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-screen items-center justify-center bg-secondary px-4">
      <div className="w-full max-w-sm space-y-4 rounded-sm border-t-8 border-primary bg-card p-6 shadow-[6px_6px_0_0_var(--primary)]">
        {children}
      </div>
    </div>
  );
}

function AuthPage() {
  const navigate = useNavigate();
  const [mode, setMode] = useState<Mode>("employee");
  const [f, setF] = useState({
    email: "",
    password: "",
    password2: "",
    orgCode: "",
    number: "",
    pin: "",
    code: "",
    name: "",
    recovery: "",
    accepted: false,
  });
  const [msg, setMsg] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [issued, setIssued] = useState<Issued | null>(null);
  const [copied, setCopied] = useState(false);
  // Osobné číslo zapamätané v tomto prehliadači (len číslo, nikdy heslo): ďalšie prihlásenie vyžaduje len heslo.
  const [savedNumber, setSavedNumber] = useState("");
  const [remember, setRemember] = useState(true);
  const numberRef = useRef<HTMLInputElement>(null);
  const passwordRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (isIdleSignOutPending()) {
      // Odhlásenie pre nečinnosť: reláciu (ak ešte ostala, napr. offline) skúsime zrušiť znova, nepresmerujeme.
      setNotice(IDLE_MESSAGE);
      void supabase.auth.signOut().catch(() => undefined);
    } else {
      supabase.auth.getSession().then(({ data }) => {
        if (data.session) navigate({ to: "/terminal" });
      });
    }
    const saved = readOrgCode();
    if (saved) setF((prev) => ({ ...prev, orgCode: saved }));
    const number = readRememberedNumber(browserStorage());
    if (number) {
      setSavedNumber(number);
      setF((prev) => ({ ...prev, number }));
      // číslo je predvyplnené, stačí napísať heslo
      setTimeout(() => passwordRef.current?.focus(), 0);
    }
  }, [navigate]);

  function otherNumber() {
    forgetNumber(browserStorage());
    setSavedNumber("");
    setF((prev) => ({ ...prev, number: "", password: "" }));
    setTimeout(() => numberRef.current?.focus(), 0);
  }

  function go(next: Mode) {
    setMode(next);
    setMsg(null);
    setF((prev) => ({ ...prev, password: "", password2: "", pin: "", recovery: "" }));
  }

  async function startSession(tokens: {
    access_token: string | null;
    refresh_token: string | null;
  }) {
    if (!tokens.access_token || !tokens.refresh_token) return { ok: false, connection: false };
    const { access_token, refresh_token } = tokens;
    // Jeden opakovaný pokus pri chybe spojenia; odmietnutie tokenov serverom sa neopakuje.
    const result = await setSessionWithRetry(() =>
      supabase.auth.setSession({ access_token, refresh_token }),
    );
    if (result.ok) beginActiveSession();
    return result;
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    if (
      (mode === "pin" || mode === "register" || mode === "recover") &&
      f.password !== f.password2
    ) {
      setMsg("Heslá sa nezhodujú.");
      return;
    }
    setBusy(true);
    try {
      if (mode === "in") {
        const { error } = await supabase.auth.signInWithPassword({
          email: f.email,
          password: f.password,
        });
        if (error)
          setMsg(
            isConnectionFailure(error) ? OFFLINE_LOGIN_MESSAGE : "Nesprávny e-mail alebo heslo.",
          );
        else {
          beginActiveSession();
          navigate({ to: "/terminal" });
        }
      } else if (mode === "employee") {
        const r = await employeeLogin({
          data: { orgCode: f.orgCode, number: f.number, password: f.password },
        });
        if (!r.ok) setMsg(r.error);
        else {
          const started = await startSession(r);
          if (started.ok) {
            rememberOrgCode(f.orgCode);
            rememberNumber(browserStorage(), f.number, remember);
            navigate({ to: "/terminal" });
          } else {
            setMsg(
              started.connection
                ? OFFLINE_LOGIN_MESSAGE
                : "Prihlásenie sa nepodarilo. Skúste to znova.",
            );
          }
        }
      } else if (mode === "pin") {
        const r = await enrollEmployee({
          data: { orgCode: f.orgCode, number: f.number, pin: f.pin, password: f.password },
        });
        if (!r.ok) setMsg(r.error);
        else {
          // heslo je nastavené (aj keď sa reláciu nepodarilo začať), číslo si prehliadač zapamätá
          rememberOrgCode(f.orgCode);
          rememberNumber(browserStorage(), f.number, remember);
          if ((await startSession(r)).ok) navigate({ to: "/terminal" });
          else {
            go("employee");
            setMsg("Heslo je nastavené. Prihláste sa osobným číslom a novým heslom.");
          }
        }
      } else if (mode === "register") {
        const r = await registerOrganization({
          data: {
            code: f.code,
            name: f.name,
            number: f.number,
            password: f.password,
            accepted: f.accepted,
          },
        });
        if (!r.ok) setMsg(r.error);
        else {
          rememberOrgCode(r.organizationCode);
          rememberNumber(browserStorage(), f.number, remember);
          setF((prev) => ({ ...prev, orgCode: r.organizationCode, password: "", password2: "" }));
          setIssued({
            kind: "register",
            orgCode: r.organizationCode,
            recoveryCode: r.recoveryCode,
          });
        }
      } else {
        const r = await recoverAdmin({
          data: {
            orgCode: f.orgCode,
            number: f.number,
            recoveryCode: f.recovery,
            password: f.password,
          },
        });
        if (!r.ok) setMsg(r.error);
        else setIssued({ kind: "recover", orgCode: null, recoveryCode: r.recoveryCode });
      }
    } catch (e) {
      // Zlyhanie spojenia nie je chyba zadaných údajov: zamestnanec nemá hľadať preklep, keď nefunguje sieť.
      if (isConnectionFailure(e)) {
        setMsg(
          mode === "register" || mode === "recover"
            ? OFFLINE_ACTION_MESSAGE
            : OFFLINE_LOGIN_MESSAGE,
        );
      } else {
        setMsg(
          "Skontrolujte zadané údaje: osobné číslo má 7 alebo 8 číslic, kód organizácie 8 znakov a nové heslo aspoň 12 znakov.",
        );
      }
    }
    setBusy(false);
  }

  async function copy(text: string) {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  }

  if (issued) {
    return (
      <Shell>
        <div>
          <div className="text-2xl font-black uppercase">Dochádzka</div>
          <div className="text-sm text-muted-foreground">
            {issued.kind === "register" ? "Organizácia je zaregistrovaná" : "Heslo je obnovené"}
          </div>
        </div>
        {issued.orgCode && (
          <div>
            <div className="text-xs font-bold uppercase">Kód organizácie (pre zamestnancov)</div>
            <div className="num text-2xl tracking-widest">{issued.orgCode}</div>
          </div>
        )}
        <div>
          <div className="text-xs font-bold uppercase">Obnovovací kód správcu</div>
          <div className="num break-all text-lg tracking-widest">{issued.recoveryCode}</div>
        </div>
        <p className="text-sm">
          Obnovovací kód sa zobrazí len teraz. Uložte si ho na bezpečné miesto (správca hesiel,
          vytlačený papier v trezore). Pomocou neho obnovíte heslo, ak ho stratíte a nebudete mať
          druhého správcu. Po každom použití sa vydá nový. Odporúčame určiť aspoň dvoch správcov.
        </p>
        <Button
          type="button"
          variant="outline"
          className="w-full"
          onClick={() => copy(issued.recoveryCode)}
        >
          {copied ? "Skopírované" : "Skopírovať obnovovací kód"}
        </Button>
        <Button
          type="button"
          className="w-full"
          onClick={() => {
            setIssued(null);
            go("employee");
          }}
        >
          Pokračovať na prihlásenie
        </Button>
      </Shell>
    );
  }

  const needsOrg = mode === "employee" || mode === "pin" || mode === "recover";
  const needsNumber = mode !== "in";
  const newPassword = mode === "pin" || mode === "register" || mode === "recover";

  return (
    <Shell>
      <form onSubmit={submit} className="space-y-4">
        <div>
          <div className="text-2xl font-black uppercase">Dochádzka</div>
          <div className="text-sm text-muted-foreground">{TITLES[mode]}</div>
        </div>

        {mode === "register" && (
          <>
            <Input
              required
              maxLength={64}
              autoComplete="off"
              aria-label="Registračný kód"
              placeholder="Registračný kód (dostali ste e-mailom)"
              value={f.code}
              onChange={(e) => setF({ ...f, code: e.target.value })}
            />
            <Input
              required
              minLength={2}
              maxLength={160}
              aria-label="Názov organizácie / firmy"
              placeholder="Názov organizácie / firmy"
              value={f.name}
              onChange={(e) => setF({ ...f, name: e.target.value })}
            />
          </>
        )}

        {needsOrg && (
          <Input
            required
            maxLength={16}
            autoComplete="off"
            aria-label="Kód organizácie"
            placeholder="Kód organizácie (8 znakov)"
            value={f.orgCode}
            onChange={(e) => setF({ ...f, orgCode: e.target.value })}
          />
        )}

        {needsNumber && (
          <Input
            ref={numberRef}
            required
            inputMode="numeric"
            pattern="[0-9]{7,8}"
            autoComplete="username"
            aria-label="Osobné číslo"
            placeholder={mode === "register" ? "Vaše osobné číslo (správca)" : "Osobné číslo"}
            value={f.number}
            onChange={(e) => setF({ ...f, number: e.target.value.trim() })}
          />
        )}
        {mode === "employee" && savedNumber !== "" && f.number === savedNumber && (
          <p className="text-xs text-muted-foreground">
            Osobné číslo máte zapamätané v tomto prehliadači, stačí heslo.{" "}
            <button type="button" className="underline" onClick={otherNumber}>
              Nie ste to vy? Zadať iné číslo
            </button>
          </p>
        )}

        {mode === "in" && (
          <Input
            required
            type="email"
            autoComplete="username"
            placeholder="E-mail"
            value={f.email}
            onChange={(e) => setF({ ...f, email: e.target.value })}
          />
        )}

        {mode === "pin" && (
          <Input
            required
            autoComplete="one-time-code"
            aria-label="PIN od správcu"
            placeholder="PIN od správcu (XXXX-XXXX-XXXX)"
            value={f.pin}
            onChange={(e) => setF({ ...f, pin: e.target.value })}
          />
        )}

        {mode === "recover" && (
          <Input
            required
            autoComplete="off"
            aria-label="Obnovovací kód"
            placeholder="Obnovovací kód správcu"
            value={f.recovery}
            onChange={(e) => setF({ ...f, recovery: e.target.value })}
          />
        )}

        <Input
          ref={passwordRef}
          required
          type="password"
          minLength={newPassword ? 12 : 1}
          autoComplete={newPassword ? "new-password" : "current-password"}
          aria-label={newPassword ? "Nové heslo" : "Heslo"}
          placeholder={newPassword ? "Nové heslo (aspoň 12 znakov)" : "Heslo"}
          value={f.password}
          onChange={(e) => setF({ ...f, password: e.target.value })}
        />
        {newPassword && (
          <Input
            required
            type="password"
            minLength={12}
            autoComplete="new-password"
            aria-label="Nové heslo znova"
            placeholder="Nové heslo znova"
            value={f.password2}
            onChange={(e) => setF({ ...f, password2: e.target.value })}
          />
        )}

        {(mode === "employee" || mode === "pin" || mode === "register") && (
          <label className="flex items-start gap-2 text-sm">
            <input
              type="checkbox"
              className="mt-1"
              checked={remember}
              onChange={(e) => setRemember(e.target.checked)}
            />
            <span>
              Zapamätať si osobné číslo v tomto prehliadači (heslo sa neukladá). Na spoločnom
              počítači túto voľbu vypnite.
            </span>
          </label>
        )}

        {mode === "register" && (
          <label className="flex items-start gap-2 text-sm">
            <input
              type="checkbox"
              required
              className="mt-1"
              checked={f.accepted}
              onChange={(e) => setF({ ...f, accepted: e.target.checked })}
            />
            <span>
              Som oprávnený zaregistrovať túto organizáciu a zodpovedám za jej správcov, osobné
              čísla zamestnancov a údaje v nej.
            </span>
          </label>
        )}

        <Button type="submit" className="w-full" disabled={busy}>
          {mode === "register"
            ? "Zaregistrovať organizáciu"
            : mode === "pin"
              ? "Nastaviť heslo a prihlásiť"
              : mode === "recover"
                ? "Obnoviť heslo"
                : "Prihlásiť"}
        </Button>
        {notice && !msg && (
          <p role="status" className="text-sm text-muted-foreground">
            {notice}
          </p>
        )}
        {msg && (
          <p role="alert" className="text-sm">
            {msg}
          </p>
        )}

        {mode === "employee" && (
          <p className="text-xs text-muted-foreground">
            Zabudnuté heslo: požiadajte správcu organizácie o nový PIN.
          </p>
        )}

        <div className="flex flex-wrap justify-center gap-1">
          {mode !== "employee" && (
            <Button type="button" variant="link" onClick={() => go("employee")}>
              Prihlásenie osobným číslom
            </Button>
          )}
          {mode !== "pin" && (
            <Button type="button" variant="link" onClick={() => go("pin")}>
              Mám PIN od správcu
            </Button>
          )}
          {mode !== "in" && (
            <Button type="button" variant="link" onClick={() => go("in")}>
              Prihlásenie e-mailom
            </Button>
          )}
          {mode !== "register" && (
            <Button type="button" variant="link" onClick={() => go("register")}>
              Registrovať organizáciu / firmu
            </Button>
          )}
          {mode !== "recover" && (
            <Button type="button" variant="link" onClick={() => go("recover")}>
              Obnova hesla správcu
            </Button>
          )}
        </div>
      </form>
    </Shell>
  );
}
