import { createFileRoute, Link } from "@tanstack/react-router";
import { Clock, WifiOff, ShieldCheck, FileSpreadsheet } from "lucide-react";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Dochádzka – podnikový dochádzkový systém" },
      { name: "description", content: "Evidencia dochádzky v prehliadači: funguje aj offline, schvaľovanie manažérom a export do SAP." },
      { property: "og:title", content: "Dochádzka – podnikový dochádzkový systém" },
      { property: "og:description", content: "Evidencia dochádzky v prehliadači: funguje aj offline, schvaľovanie manažérom a export do SAP." },
    ],
  }),
  component: Index,
});

const F = [
  { icon: WifiOff, t: "Aj bez siete", d: "Záznam sa uloží v zariadení a odošle sa po pripojení." },
  { icon: ShieldCheck, t: "Overiteľný audit", d: "Každý záznam dostane serverový čas a reťazový SHA-256 odtlačok." },
  { icon: FileSpreadsheet, t: "Export do SAP", d: "Mesačná uzávierka, výkaz A4 na podpis a .xlsx pre mzdy." },
];

function Index() {
  return (
    <div className="min-h-screen bg-secondary text-secondary-foreground">
      <div className="mx-auto flex min-h-screen max-w-5xl flex-col justify-center px-6 py-16">
        <div className="mb-3 flex items-center gap-2 text-primary"><Clock className="h-6 w-6" /><span className="text-sm font-bold uppercase tracking-[0.3em]">v1.1 · prototyp</span></div>
        <h1 className="text-5xl font-black uppercase leading-none tracking-tight sm:text-7xl">Dochádzka</h1>
        <p className="mt-4 max-w-xl text-lg text-secondary-foreground/75">Virtuálny terminál pre Windows 11 a mobil. Bez inštalácie – stačí prehliadač Edge.</p>
        <div className="mt-8"><Link to="/terminal" className="inline-block rounded-sm bg-primary px-8 py-4 text-lg font-black uppercase text-primary-foreground shadow-[5px_5px_0_0_var(--secondary-foreground)]">Otvoriť terminál</Link></div>
        <div className="mt-16 grid gap-6 sm:grid-cols-3">
          {F.map((f) => (
            <div key={f.t} className="border-t-4 border-primary pt-3">
              <f.icon className="mb-2 h-6 w-6 text-primary" />
              <div className="font-bold uppercase">{f.t}</div>
              <div className="text-sm text-secondary-foreground/70">{f.d}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
