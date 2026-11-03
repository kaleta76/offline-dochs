import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { personnelNumberSchema } from "./personnel";
import { EXPORT_PAGE_SIZE, monthRangeUtc, type ProfileLite } from "./punch-export-range";
import { buildVoidExportCsv, toVoidRows, voidFileName, type VoidDbShape } from "./void-export";

const voidInput = z.object({
  year: z.number().int().min(2020).max(2100),
  month: z.number().int().min(1).max(12),
});

/**
 * Zoznam zneplatnených razení za mesiac pre dochádzkový systém (Access), kontrakt v1.1 (`contract/README.md`).
 * Mesiac sa určuje podľa času zneplatneného razenia (client_time), nie podľa času schválenia: Access tak dostane
 * zoznam rovnakého mesiaca, aký importoval. Smie ho spustiť len správca; dáta sa čítajú s právami používateľa (RLS),
 * service role sa používa iba na zápis do audit_log. Export razení (v1) sa nemení a zneplatnené razenia obsahuje ďalej.
 */
export const exportVoids = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((v: unknown) => voidInput.parse(v))
  .handler(async ({ data, context }) => {
    const { supabase, userId } = context;
    const { data: isAdmin, error: roleError } = await supabase.rpc("has_role", {
      _user_id: userId,
      _role: "admin",
    });
    if (roleError || !isAdmin) throw new Error("Export môže spustiť iba správca.");
    const { data: organization, error: organizationError } = await supabase.rpc("my_organization");
    if (organizationError || !organization) throw new Error("Organizácia nie je dostupná.");

    const profiles: ProfileLite[] = [];
    for (let from = 0; ; from += EXPORT_PAGE_SIZE) {
      const { data: page, error } = await supabase
        .from("profiles")
        .select("id, sap_id")
        .eq("organization_id", organization)
        .order("id")
        .range(from, from + EXPORT_PAGE_SIZE - 1);
      if (error) throw new Error("Zoznam zamestnancov sa nepodarilo načítať.");
      profiles.push(...(page ?? []));
      if ((page?.length ?? 0) < EXPORT_PAGE_SIZE) break;
    }
    const sapByUser = new Map<string, string>();
    for (const p of profiles) {
      const parsed = personnelNumberSchema.safeParse(p.sap_id);
      if (parsed.success) sapByUser.set(p.id, parsed.data);
    }

    const range = monthRangeUtc(data.year, data.month);
    const punches: VoidDbShape[] = [];
    for (let from = 0; ; from += EXPORT_PAGE_SIZE) {
      const { data: page, error } = await supabase
        .from("punches")
        .select("id, client_uuid, user_id, voided_at, record_hash")
        .not("voided_at", "is", null)
        .gte("client_time", range.from.toISOString())
        .lt("client_time", range.to.toISOString())
        .order("id", { ascending: true })
        .range(from, from + EXPORT_PAGE_SIZE - 1);
      if (error) throw new Error("Zneplatnené razenia sa nepodarilo načítať.");
      punches.push(...(page ?? []));
      if ((page?.length ?? 0) < EXPORT_PAGE_SIZE) break;
    }

    const rows = toVoidRows(punches, sapByUser, organization);
    const csv = await buildVoidExportCsv(rows);

    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { error: auditError } = await supabaseAdmin.from("audit_log").insert({
      actor: userId,
      action: "export.voids",
      details: { year: data.year, month: data.month, rows: rows.length },
    });
    if (auditError) throw new Error("Export sa nepodarilo zapísať do auditu, preto sa nevydal.");

    return { filename: voidFileName(data.year, data.month), csv, rows: rows.length };
  });
