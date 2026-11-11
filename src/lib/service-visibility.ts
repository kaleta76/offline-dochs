// Kedy sa v Správe zobrazí skrytá karta „Servis a testovanie“ a čo je v nej.
// Bežná prevádzka (sekretárka HR) má len kartu „Prevádzka“ (export razení pre Access, výkazy na tlač, import konfigurácie z Accessu, prístup zamestnancov). Servisné a testovacie voľby
// (zamestnanci s vedúcimi a rolami, pravidlá výpočtu, číselník prerušení, sviatky, odhlásenie pri nečinnosti, testovací import, skúšobný export pre SAP,
// testovacia organizácia, diagnostika spojenia; to, čo má prísť z Accessu) sú v druhej karte, ktorá sa v ostrej organizácii neukáže, kým majiteľ nepridá k adrese Správy ?servis=1.
// Skrytie nie je ochrana: ide len o poriadok na obrazovke. Skutočne chráni databáza (oprávnenia, ochrana pôvodnej organizácie).
// Staršie ?diagnostika=1 (pre IT) funguje ďalej: odkryje kartu, ale len s diagnostikou spojenia.

import { DIAGNOSTICS_PARAM } from "@/lib/diagnostics-visibility";

export const SERVICE_PARAM = "servis";

export type ServiceVisibility = {
  /** Ukáže sa karta „Servis a testovanie“ (záložka). */
  tab: boolean;
  /** V karte sú servisné a testovacie nástroje (okrem diagnostiky). */
  tools: boolean;
  /** V karte je diagnostika spojenia. */
  diagnostics: boolean;
  /** Karta sa otvorí hneď po načítaní (adresa obsahuje ?servis=1 alebo ?diagnostika=1). */
  openByDefault: boolean;
};

const flag = (search: string, name: string) => new URLSearchParams(search).get(name) === "1";

export function serviceVisibility(input: {
  isTestOrganization: boolean;
  search: string;
}): ServiceVisibility {
  const service = flag(input.search, SERVICE_PARAM);
  const diagnostics = flag(input.search, DIAGNOSTICS_PARAM);
  const tools = input.isTestOrganization || service;
  const withDiagnostics = tools || diagnostics;
  return {
    tab: withDiagnostics,
    tools,
    diagnostics: withDiagnostics,
    openByDefault: service || diagnostics,
  };
}
