// Klasifikácia chýb spojenia (certifikát / prenos / ostatné). Samostatný súbor bez závislostí, aby ju vedel použiť aj záznam
// zlyhaných dopytov (net-log.ts); offline-queue.ts ju naďalej exportuje pod pôvodným menom.

export type SyncErrorKind = "certificate" | "transport" | "other";

interface ErrorLike {
  message?: string | null;
  code?: string | null;
  status?: number | null;
}

const CERTIFICATE_PATTERNS: RegExp[] = [
  /ERR_CERT_/i,
  /ERR_SSL_/i,
  /SEC_ERROR_/i,
  /SSL_ERROR_/i,
  /certificate/i,
  /self[- ]signed/i,
  /unable to verify the first certificate/i,
  /UNABLE_TO_GET_ISSUER_CERT/i,
  /DEPTH_ZERO_SELF_SIGNED_CERT/i,
];

const TRANSPORT_PATTERNS: RegExp[] = [
  /failed to fetch/i, // Chrome / Edge
  /networkerror when attempting to fetch/i, // Firefox
  /load failed/i, // Safari
  /network request failed/i,
  /fetch failed/i,
  /unexpected token '<'/i, // HTML page parsed as JSON
  /<!doctype html/i, // proxy / captive-portal page returned as error body
  /<html[\s>]/i,
  /connection (was )?(closed|reset|aborted)/i,
  /ERR_CONNECTION_(CLOSED|RESET|ABORTED)/i,
  /ERR_EMPTY_RESPONSE/i,
  /ECONNRESET/i,
  /socket hang up/i,
];

const TRANSPORT_STATUSES = new Set([502, 504]);

/** Classifies a failed request. Certificate errors are never treated as an ordinary outage. */
export function classifySyncError(error: unknown, status?: number | null): SyncErrorKind {
  const e = (error ?? {}) as ErrorLike;
  const message =
    typeof error === "string"
      ? error
      : String(e.message ?? (error instanceof Error ? error.message : ""));
  const code = e.code ?? "";
  const httpStatus = status ?? e.status ?? null;
  if (CERTIFICATE_PATTERNS.some((p) => p.test(message) || (code ? p.test(code) : false)))
    return "certificate";
  if (TRANSPORT_PATTERNS.some((p) => p.test(message) || (code ? p.test(code) : false)))
    return "transport";
  if (httpStatus != null && TRANSPORT_STATUSES.has(httpStatus)) return "transport";
  // A 403 without a database error code comes from a proxy / gateway, not from RLS or grants.
  if (httpStatus === 403 && !code) return "transport";
  return "other";
}

/**
 * Databáza razenie jednoznačne odmietla (napr. „Mesiac je uzavretý“, porušené obmedzenie, neplatná hodnota).
 * Opakovanie nepomôže, preto sa takéto razenie zaparkuje namiesto opakovania každých 60 s.
 * Zámerne úzky zoznam: SQLSTATE triedy 22 (neplatné dáta), 23 (obmedzenia) a P0 (výnimka z funkcie alebo triggera) s HTTP
 * stavom pod 500. Všetko ostatné (5xx, nedostatok zdrojov 53, vypnutie alebo časový limit 57, uviaznutie 40, chyby spojenia 08,
 * PGRST0xx, neznáme kódy, 42501 a chyby tokenu) ostáva na opakovaní s odstupom, aby sa krátky výpadok databázy nezmenil na ručnú prácu.
 */
export function isDefiniteRejection(error: unknown, status?: number | null): boolean {
  if (classifySyncError(error, status) !== "other") return false;
  const e = (error ?? {}) as ErrorLike;
  const httpStatus = status ?? e.status ?? null;
  if (httpStatus != null && httpStatus >= 500) return false;
  const code = String(e.code ?? "");
  return /^(22|23|P0)/.test(code);
}

/** Funkcia v databáze chýba (nespustená migrácia): opakovanie nepomôže, kým sa migrácia nespustí. */
export function isMissingFunction(error: unknown): boolean {
  const e = (error ?? {}) as ErrorLike;
  const code = String(e.code ?? "");
  return code === "PGRST202" || code === "42883";
}
