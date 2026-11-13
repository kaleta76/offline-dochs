// Nová adresa aplikácie pri prenose organizácie (migrácia 0019, docs/PRENOS-ORGANIZACIE.md). Správca ju môže uložiť k rozpracovanému
// prenosu; terminály, v ktorých ostali razenia, ju potom ukážu ľuďom (počas prenosu aj po presťahovaní). Je nepovinná.
import { z } from "zod";
import { call, TransferError, type TransferClient } from "./org-transfer";
import { LATE_MISSING_MESSAGE } from "./late-punches";
import { safeDestination } from "./server-move";

const schema = z.object({ transfer_id: z.string().nullable(), url: z.string().nullable() });

function parse(value: unknown): string | null {
  const parsed = schema.safeParse(value);
  if (!parsed.success) throw new TransferError("invalid", "Server vrátil neočakávanú odpoveď.");
  return parsed.data.url;
}

/** Text problému s adresou, alebo null. Rovnaké pravidlo ako org_transfer.valid_destination v databáze (tá rozhoduje). */
export function destinationProblem(input: string): string | null {
  const value = input.trim().replace(/\/+$/, "");
  if (value === "") return null;
  return safeDestination(value)
    ? null
    : "Adresu zadajte v tvare https://nazov.servera (bez mena, hesla a otáznika).";
}

export async function getDestination(client: TransferClient): Promise<string | null> {
  return parse(
    await call(
      client,
      "org_transfer_get_destination",
      {},
      { retries: 2, missingMessage: LATE_MISSING_MESSAGE },
    ),
  );
}

/** Uloží novú adresu; prázdny text ju zmaže. */
export async function setDestination(client: TransferClient, url: string): Promise<string | null> {
  return parse(
    await call(
      client,
      "org_transfer_set_destination",
      { _url: url.trim() },
      { missingMessage: LATE_MISSING_MESSAGE },
    ),
  );
}
