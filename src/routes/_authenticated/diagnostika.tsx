import { createFileRoute } from "@tanstack/react-router";
import { ConnectionDiagnostics } from "@/components/ConnectionDiagnostics";

export const Route = createFileRoute("/_authenticated/diagnostika")({
  head: () => ({
    meta: [
      { title: "Diagnostika spojenia – Dochádzka" },
      { name: "description", content: "Test spojenia s databázou a záznam zlyhaných dopytov." },
    ],
  }),
  component: Diagnostika,
});

// Skrytá stránka pre každého prihláseného (nie je v ponuke). Otvára sa odkazom „Diagnostika“, ktorý sa ukáže len pri probléme
// s odoslaním razení alebo načítaním údajov o účte, alebo adresou /diagnostika. Správca ju má aj v karte Servis v Správe.
function Diagnostika() {
  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-black uppercase">Diagnostika spojenia</h1>
      <p className="max-w-3xl text-sm">
        Pomôcka na zistenie, prečo zlyháva odoslanie razení alebo načítanie údajov. Nič nemení.
        Spustite test spojenia, potom „Kopírovať pre SOC“ a text pošlite správcovi. Neobsahuje
        osobné údaje ani tokeny.
      </p>
      <ConnectionDiagnostics />
    </div>
  );
}
