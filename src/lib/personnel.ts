import { z } from "zod";

export const personnelNumberSchema = z.string().regex(/^[0-9]{7,8}$/, "Osobné číslo zo SAP musí mať 7 alebo 8 číslic.");

export function personnelLabel(profile: { id: string; sap_id: string | null } | null | undefined): string {
  if (!profile) return "…";
  const number = personnelNumberSchema.safeParse(profile.sap_id);
  return number.success ? number.data : `Bez osobného čísla · ${profile.id.slice(0, 8)}`;
}

const cachedProfileSchema = z.object({
  roles: z.array(z.enum(["employee", "manager", "admin"])),
  profile: z.object({
    id: z.string(), sap_id: z.string().nullable().optional().transform(v => personnelNumberSchema.safeParse(v).success ? v ?? null : null),
    department: z.string().nullable(), daily_fund: z.number(), organization_id: z.string().nullable(),
  }).nullable(),
  organization: z.object({ id: z.string(), name: z.string(), is_test: z.boolean().optional() }).nullable(),
});

// Strip old identity fields without deleting offline punches, device keys or the sign-in session.
export function sanitizeProfileCache(value: unknown) {
  const parsed = cachedProfileSchema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

export function migrateProfileCaches(storage: Storage) {
  for (const key of Object.keys(storage).filter(k => k === "me-cache" || k.startsWith("me-cache:"))) {
    try {
      const safe = sanitizeProfileCache(JSON.parse(storage.getItem(key) ?? "null"));
      if (safe && key !== "me-cache") storage.setItem(key, JSON.stringify(safe));
      else storage.removeItem(key);
    } catch { storage.removeItem(key); }
  }
}