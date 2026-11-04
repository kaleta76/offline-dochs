// Chyby spojenia s databázou (Lovable Cloud) zrozumiteľne: prehliadač pri zlyhaní siete hlási len "Failed to fetch".
// Typická príčina na pracovných počítačoch: firewall alebo proxy blokuje adresu databázy (inú než adresu aplikácie).

/** Chyba prehliadača pri neúspešnom sieťovom volaní (Chrome/Edge: Failed to fetch, Firefox: NetworkError, Safari: Load failed). */
export function isNetworkError(message: string | null | undefined): boolean {
  return /failed to fetch|networkerror|load failed|network request failed/i.test(message ?? "");
}

/** Názov hostiteľa databázy na zobrazenie (napr. pre IT oddelenie), alebo prázdny reťazec, ak adresa nie je platná. */
export function backendHost(url: string | undefined): string {
  try {
    return url ? new URL(url).host : "";
  } catch {
    return "";
  }
}
