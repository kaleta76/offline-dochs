import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { buildPunchExportCsv } from "./punch-export";
import {
  EXPORT_PAGE_SIZE,
  exportFileName,
  monthRangeUtc,
  toExportRows,
  type ProfileLite,
  type PunchDbShape,
} from "./punch-export-range";

const exportInput = z.object({
  year: z.number().int().min(2020).max(2100),
  month: z.number().int().min(1).max(12),
  sinceId: z.number().int().min(0).optional(),
});

const PUNCH_COLUMNS =
  "id, client_uuid, code, direction, client_time, server_time, drift_minutes, source, device_verification, device_id, user_id, prev_hash, record_hash";

/**
 * Export razení pre dochádzkový systém (Access), kontrakt v1 (`contract/README.md`).
 * Smie ho spustiť len správca. Dáta sa čítajú s právami prihláseného používateľa (RLS), nie cez service role;
 * service role sa používa iba na zápis do audit_log.
 * Bez `sinceId` vráti celý mesiac (Europe/Bratislava), so `sinceId` všetky razenia s `id > sinceId`.
 */
export const exportPunches = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((v: unknown) => exportInput.parse(v))
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

    const range = monthRangeUtc(data.year, data.month);
    const punches: PunchDbShape[] = [];
    for (let from = 0; ; from += EXPORT_PAGE_SIZE) {
      const base = supabase.from("punches").select(PUNCH_COLUMNS).order("id", { ascending: true });
      const filtered =
        data.sinceId !== undefined
          ? base.gt("id", data.sinceId)
          : base
              .gte("client_time", range.from.toISOString())
              .lt("client_time", range.to.toISOString());
      const { data: page, error } = await filtered.range(from, from + EXPORT_PAGE_SIZE - 1);
      if (error) throw new Error("Razenia sa nepodarilo načítať.");
      punches.push(...(page ?? []));
      if ((page?.length ?? 0) < EXPORT_PAGE_SIZE) break;
    }

    const rows = toExportRows(punches, profiles, organization);
    const csv = await buildPunchExportCsv(rows);
    const maxPunchId = rows.reduce((max, r) => Math.max(max, r.id), data.sinceId ?? 0);

    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { error: auditError } = await supabaseAdmin.from("audit_log").insert({
      actor: userId,
      action: "export.access",
      details: {
        year: data.year,
        month: data.month,
        since_id: data.sinceId ?? null,
        rows: rows.length,
        max_punch_id: maxPunchId,
      },
    });
    if (auditError) throw new Error("Export sa nepodarilo zapísať do auditu, preto sa nevydal.");

    return {
      filename: exportFileName({ year: data.year, month: data.month, sinceId: data.sinceId }),
      csv,
      rows: rows.length,
      maxPunchId,
    };
  });
