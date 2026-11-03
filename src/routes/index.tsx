import { createFileRoute, Link } from "@tanstack/react-router";
import { Clock, WifiOff, ShieldCheck, FileSpreadsheet, UserRound, ExternalLink } from "lucide-react";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Dochádzka – terminál a dochádzkový systém" },
      { name: "description", content: "Terminál dochádzky v prehliadači: funguje aj offline, eviduje len osobné čísla SAP (bez mien), razenia sa prenášajú do lokálneho dochádzkového systému." },
      { property: "og:title", content: "Dochádzka – terminál a dochádzkový systém" },
      { property: "og:description", content: "Terminál dochádzky v prehliadači: funguje aj offline, eviduje len osobné čísla SAP (bez mien), razenia sa prenášajú do lokálneho dochádzkového systému." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: Index,
});

const GITHUB_URL = "https://github.com/kaleta76/offline-dochs";
const ISSUES_URL = `${GITHUB_URL}/issues`;
const PAYPAL_URL = "https://www.paypal.me/kaleta7";

const F = [
  { icon: WifiOff, t: "Aj bez siete", d: "Záznam sa uloží v zariadení a odošle sa po pripojení." },
  { icon: UserRound, t: "Bez osobných údajov", d: "Terminál pozná len osobné číslo SAP. Mená, fondy a pravidlá ostávajú v lokálnom dochádzkovom systéme." },
  { icon: ShieldCheck, t: "Overiteľný audit", d: "Každý záznam dostane serverový čas a reťazový SHA-256 odtlačok. Razenie sa nemaže, duplicitu zneplatní vedúci." },
  { icon: FileSpreadsheet, t: "Prenos do dochádzky", d: "Razenia ako CSV pre dochádzkový systém v Accesse, mesačný výkaz A4 na podpis a .xlsx pre mzdy." },
];

function Index() {
  return (
    <div className="min-h-screen bg-secondary text-secondary-foreground">
      <div className="mx-auto flex min-h-screen max-w-5xl flex-col justify-center px-6 py-16">
        <div className="mb-3 flex items-center gap-2 text-primary"><Clock className="h-6 w-6" /><span className="text-sm font-bold uppercase tracking-[0.3em]">v1.1 · prototyp</span></div>
        <h1 className="text-5xl font-black uppercase leading-none tracking-tight sm:text-7xl">Dochádzka</h1>
        <p className="mt-4 max-w-xl text-lg text-secondary-foreground/75">Terminál dochádzky pre Windows 11 a mobil. Bez inštalácie – stačí prehliadač. Spolupracuje s lokálnym dochádzkovým systémom (Access), ktorému odovzdáva razenia súborom.</p>
        <div className="mt-8"><Link to="/terminal" className="inline-block rounded-sm bg-primary px-8 py-4 text-lg font-black uppercase text-primary-foreground shadow-[5px_5px_0_0_var(--secondary-foreground)]">Otvoriť terminál</Link></div>
        <div className="mt-16 grid gap-6 sm:grid-cols-2 lg:grid-cols-4">
          {F.map((f) => (
            <div key={f.t} className="border-t-4 border-primary pt-3">
              <f.icon className="mb-2 h-6 w-6 text-primary" />
              <div className="font-bold uppercase">{f.t}</div>
              <div className="text-sm text-secondary-foreground/70">{f.d}</div>
            </div>
          ))}
        </div>
        <p className="mt-12 text-sm text-secondary-foreground/70">
          Zdrojový kód, dokumentácia a inštalátor dochádzkového systému:{" "}
          <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 font-bold text-primary underline underline-offset-4">
            GitHub <ExternalLink className="h-4 w-4" aria-hidden="true" />
            <span className="sr-only">(otvorí sa v novom okne)</span>
          </a>
        </p>
        <p className="mt-3 max-w-2xl text-sm text-secondary-foreground/70">
          Projekt vzniká bez dotácie. Ak ho chcete podporiť, môžete poslať dar cez{" "}
          <a href={PAYPAL_URL} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 font-bold text-primary underline underline-offset-4">
            PayPal <ExternalLink className="h-4 w-4" aria-hidden="true" />
            <span className="sr-only">(otvorí sa v novom okne)</span>
          </a>
          . Na sponzoring, spoluprácu alebo chyby napíšte cez{" "}
          <a href={ISSUES_URL} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 font-bold text-primary underline underline-offset-4">
            Issues na GitHube <ExternalLink className="h-4 w-4" aria-hidden="true" />
            <span className="sr-only">(otvorí sa v novom okne)</span>
          </a>
          . Zápis je verejný, neuvádzajte v ňom osobné údaje.
        </p>
      </div>
    </div>
  );
}
