import { z } from "zod";
import { normalizeCode } from "./credentials";
import { personnelNumberSchema } from "./personnel";

// Vstupy verejných a správcovských funkcií pre registráciu firmy a zamestnancov.

export const strongPasswordSchema = z
  .string()
  .min(12, "Heslo musí mať aspoň 12 znakov.")
  .max(128, "Heslo je príliš dlhé.");

/** Kód organizácie z prihlasovacej obrazovky (8 hexadecimálnych znakov, pomlčka a veľkosť písmen nehrá rolu). */
export const orgCodeSchema = z
  .string()
  .min(8)
  .max(16)
  .transform(normalizeCode)
  .pipe(z.string().regex(/^[0-9A-F]{8}$/, "Neplatný kód organizácie."));

export const registerSchema = z.object({
  code: z.string().min(8).max(64),
  name: z.string().trim().min(2, "Zadajte názov organizácie.").max(160),
  number: personnelNumberSchema,
  password: strongPasswordSchema,
  accepted: z.literal(true, {
    errorMap: () => ({ message: "Je potrebný súhlas so zodpovednosťou." }),
  }),
});

export const loginSchema = z.object({
  orgCode: orgCodeSchema,
  number: personnelNumberSchema,
  password: z.string().min(1).max(128),
});

export const enrollSchema = z.object({
  orgCode: orgCodeSchema,
  number: personnelNumberSchema,
  pin: z.string().min(8).max(32),
  password: strongPasswordSchema,
});

export const recoverSchema = z.object({
  orgCode: orgCodeSchema,
  number: personnelNumberSchema,
  recoveryCode: z.string().min(12).max(40),
  password: strongPasswordSchema,
});

export const provisionSchema = z.object({
  numbers: z.array(personnelNumberSchema).min(1).max(25),
  reset: z.boolean(),
});
