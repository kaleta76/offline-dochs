// Nová adresa aplikácie a správa pre zariadenia pri prenose organizácie (migrácie 0019 a 0020, docs/PRENOS-ORGANIZACIE.md). Správca ich
// môže uložiť k rozpracovanému prenosu; terminály, v ktorých ostali razenia, ich potom ukážu ľuďom (počas prenosu aj po presťahovaní).
// Obe hodnoty sú nepovinné.
import { z } from "zod";
import { call, TransferError, type TransferClient } from "./org-transfer";
import { LATE_MISSING_MESSAGE } from "./late-punches";
import { MAX_MESSAGE_LENGTH, safeDestination, safeMessage } from "./server-move";

// „message“ chýba v odpovedi servera bez migrácie 0020 (len 0019): vtedy sa pole so správou neukazuje.
const schema = z.object({
  transfer_id: z.string().nullable(),
  url: z.string().nullable(),
  message: z.string().nullable().optional(),
});

function parseRaw(value: unknown) {
  const parsed = schema.safeParse(value);
  if (!parsed.success) throw new TransferError("invalid", "Server vrátil neočakávanú odpoveď.");
  return parsed.data;
}

export const LATE_NOTICE_MISSING_MESSAGE =
  "Správu pre zariadenia server ešte neumožňuje. Najprv treba spustiť migráciu 0020 (docs/migracie/0020_sprava_a_ukoncenie_organizacie.sql).";

export interface TransferNotice {
  url: string | null;
  message: string | null;
  /** false = server má len migráciu 0019 (správu neuloží); pole so správou sa neukáže. */
  supportsMessage: boolean;
}

function toNotice(value: unknown): TransferNotice {
  const raw = parseRaw(value);
  return { url: raw.url, message: raw.message ?? null, supportsMessage: raw.message !== undefined };
}

/** Text problému s adresou, alebo null. Rovnaké pravidlo ako org_transfer.valid_destination v databáze (tá rozhoduje). */
export function destinationProblem(input: string): string | null {
  const value = input.trim().replace(/\/+$/, "");
  if (value === "") return null;
  return safeDestination(value)
    ? null
    : "Adresu zadajte v tvare https://nazov.servera (bez mena, hesla a otáznika).";
}

/** Text problému so správou, alebo null. Rovnaké pravidlo ako org_transfer.valid_message v databáze (tá rozhoduje). */
export function messageProblem(input: string): string | null {
  const value = input.trim();
  if (value === "") return null;
  return safeMessage(value)
    ? null
    : `Správa môže mať najviac ${MAX_MESSAGE_LENGTH} znakov, jeden riadok a len bežný text.`;
}

export async function getNotice(client: TransferClient): Promise<TransferNotice> {
  return toNotice(
    await call(
      client,
      "org_transfer_get_destination",
      {},
      { retries: 2, missingMessage: LATE_MISSING_MESSAGE },
    ),
  );
}

export async function getDestination(client: TransferClient): Promise<string | null> {
  return (await getNotice(client)).url;
}

/** Uloží novú adresu (správa na serveri ostane); prázdny text adresu zmaže. */
export async function setDestination(client: TransferClient, url: string): Promise<string | null> {
  return parseRaw(
    await call(
      client,
      "org_transfer_set_destination",
      { _url: url.trim() },
      { missingMessage: LATE_MISSING_MESSAGE },
    ),
  ).url;
}

/** Uloží adresu aj správu naraz (prázdny text zmaže). Vyžaduje migráciu 0020. */
export async function setNotice(
  client: TransferClient,
  url: string,
  message: string,
): Promise<TransferNotice> {
  return toNotice(
    await call(
      client,
      "org_transfer_set_notice",
      { _url: url.trim(), _message: message.trim() },
      { missingMessage: LATE_NOTICE_MISSING_MESSAGE },
    ),
  );
}
