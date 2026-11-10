// Kedy sa v Správe zobrazí panel „Diagnostika spojenia“.
// Zbierka zlyhaných dopytov (src/lib/net-log.ts) beží stále, nepoužíva sieť ani databázu a len zapisuje do prehliadača.
// Panel, ktorý ju zobrazuje a posiela skúšobné dopyty, je pomôcka pre IT, preto sa v ostrej organizácii štandardne nezobrazuje:
// ukáže sa v testovacej organizácii alebo keď správca k adrese Správy pridá ?diagnostika=1 (napr. na žiadosť SOC).

export const DIAGNOSTICS_PARAM = "diagnostika";

export function showDiagnostics(input: { isTestOrganization: boolean; search: string }): boolean {
  if (input.isTestOrganization) return true;
  return new URLSearchParams(input.search).get(DIAGNOSTICS_PARAM) === "1";
}
