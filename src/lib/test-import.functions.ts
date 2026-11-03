import { createServerFn } from "@tanstack/react-start";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { Database } from "@/integrations/supabase/types";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { localTime, TIME_ZONE } from "./punch-export";
import {
  MAX_TEST_CSV_CHARS,
  TEST_DEVICE,
  TEST_MODE_KEY,
  parseTestCsv,
  testPunchUuid,
  verifyChain,
  type ChainRow,
  type TestIssue,
} from "./test-import";

// Testovacia prevádzka organizácie: zapnutie a import razení z CSV. Všetko smie len správca a import len vtedy,
// keď je v organization_settings kľúč TESTOVACIA_PREVADZKA = "1". Importované razenia majú zdroj `correction`
// (zariadenie „testovací import“), idú cez ten istý trigger s hash reťazou ako bežné razenia a nič sa nemaže.

const PAGE = 1000;
const INSERT_CHUNK = 100;

async function requireAdmin(supabase: SupabaseClient<Database>, userId: string) {
  const { data: isAdmin, error } = await supabase.rpc("has_role", { _user_id: userId, _role: "admin" });
  if (error || !isAdmin) throw new Error("Túto akciu môže spustiť iba správca.");
  const { data: organization, error: orgError } = await supabase.rpc("my_organization");
  if (orgError || !organization) throw new Error("Organizácia nie je dostupná.");
  return organization as string;
}

async function adminClient() {
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  return supabaseAdmin;
}

/** Zapne alebo vypne testovaciu prevádzku organizácie. */
export const setTestMode = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((v: unknown) => z.object({ enabled: z.boolean() }).parse(v))
  .handler(async ({ data, context }) => {
    const organization = await requireAdmin(context.supabase, context.userId);
    const admin = await adminClient();
    const { error } = await admin.from("organization_settings").upsert(
      {
        organization_id: organization,
        key: TEST_MODE_KEY,
        value: data.enabled ? "1" : "0",
        description: "Testovacia prevádzka: povolí import razení z CSV v administrácii",
      },
      { onConflict: "organization_id,key" },
    );
    if (error) throw new Error("Testovaciu prevádzku sa nepodarilo prepnúť.");
    const { error: auditError } = await admin.from("audit_log").insert({
      actor: context.userId,
      action: data.enabled ? "test_mode.on" : "test_mode.off",
      details: { organization },
    });
    if (auditError) throw new Error("Zmena sa nepodarila zapísať do auditu.");
    return { enabled: data.enabled };
  });

const importInput = z.object({
  csv: z.string().max(MAX_TEST_CSV_CHARS),
  dryRun: z.boolean(),
});

export interface TestImportResult {
  dryRun: boolean;
  total: number;
  inserted: number;
  skippedExisting: number;
  duplicatesInFile: number;
  issues: TestIssue[];
  persons: { sap: string; count: number; first: string; last: string }[];
  chain: { checked: number; ok: boolean; message: string | null };
}

/**
 * Import testovacích razení z CSV (osobne_cislo;datum;cas;kod;smer). Buď sa zapíše všetko, alebo nič:
 * pri chybe vo vstupe (neznáme číslo, kód, uzavretý mesiac ...) sa nezapíše žiadny riadok.
 * Opakovaný import toho istého súboru nič nezduplikuje (stále UUID razenia). Po zápise sa overí hash reťaz.
 */
export const importTestPunches = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((v: unknown) => importInput.parse(v))
  .handler(async ({ data, context }): Promise<TestImportResult> => {
    const organization = await requireAdmin(context.supabase, context.userId);
    const admin = await adminClient();

    const { data: flag } = await admin
      .from("organization_settings")
      .select("value")
      .eq("organization_id", organization)
      .eq("key", TEST_MODE_KEY)
      .maybeSingle();
    if (flag?.value !== "1") {
      throw new Error("Testovacia prevádzka nie je zapnutá. Zapnite ju v administrácii.");
    }

    const { data: codeRows, error: codeError } = await admin
      .from("organization_codes")
      .select("code")
      .eq("organization_id", organization);
    if (codeError) throw new Error("Číselník kódov sa nepodarilo načítať.");
    const parsed = parseTestCsv(data.csv, new Set((codeRows ?? []).map((c) => c.code)));
    const issues: TestIssue[] = [...parsed.issues];

    const profiles = new Map<string, string>();
    for (let from = 0; ; from += PAGE) {
      const { data: page, error } = await admin
        .from("profiles")
        .select("id, sap_id")
        .eq("organization_id", organization)
        .order("id")
        .range(from, from + PAGE - 1);
      if (error) throw new Error("Zoznam zamestnancov sa nepodarilo načítať.");
      for (const p of page ?? []) if (p.sap_id) profiles.set(p.sap_id, p.id);
      if ((page?.length ?? 0) < PAGE) break;
    }
    const unknown = new Set<string>();
    for (const r of parsed.rows) {
      if (!profiles.has(r.sap) && !unknown.has(r.sap)) {
        unknown.add(r.sap);
        issues.push({
          line: r.line,
          text: `Zamestnanec ${r.sap} nie je v organizácii. Najprv ho pridajte v časti Zamestnanci (import osobných čísel).`,
        });
      }
    }

    // uzavreté mesiace: trigger by razenie odmietol, preto to zistíme vopred a nezapíšeme nič
    const userIds = [...new Set(parsed.rows.map((r) => profiles.get(r.sap)).filter((x): x is string => !!x))];
    if (userIds.length > 0) {
      const { data: closures, error } = await admin
        .from("month_closures")
        .select("user_id, year, month")
        .in("user_id", userIds);
      if (error) throw new Error("Uzávierky mesiacov sa nepodarilo načítať.");
      const closed = new Set((closures ?? []).map((c) => `${c.user_id}|${c.year}|${c.month}`));
      const reported = new Set<string>();
      for (const r of parsed.rows) {
        const user = profiles.get(r.sap);
        if (!user) continue;
        const key = `${user}|${Number(r.local.slice(0, 4))}|${Number(r.local.slice(5, 7))}`;
        if (closed.has(key) && !reported.has(`${r.sap}|${key}`)) {
          reported.add(`${r.sap}|${key}`);
          issues.push({
            line: r.line,
            text: `Mesiac ${r.local.slice(0, 7)} zamestnanca ${r.sap} je uzavretý, razenia sa doň nedajú zapísať.`,
          });
        }
      }
    }

    const rows = await Promise.all(
      parsed.rows.map(async (r) => ({ ...r, uuid: await testPunchUuid(r), user: profiles.get(r.sap) })),
    );
    const existing = new Set<string>();
    for (let i = 0; i < rows.length; i += 100) {
      const chunk = rows.slice(i, i + 100).map((r) => r.uuid);
      const { data: found, error } = await admin.from("punches").select("client_uuid").in("client_uuid", chunk);
      if (error) throw new Error("Existujúce razenia sa nepodarilo skontrolovať.");
      for (const f of found ?? []) existing.add(f.client_uuid);
    }
    const fresh = rows.filter((r) => r.user && !existing.has(r.uuid));

    const perPerson = new Map<string, { sap: string; count: number; first: string; last: string }>();
    for (const r of rows) {
      const p = perPerson.get(r.sap) ?? { sap: r.sap, count: 0, first: r.local, last: r.local };
      p.count += 1;
      if (r.local < p.first) p.first = r.local;
      if (r.local > p.last) p.last = r.local;
      perPerson.set(r.sap, p);
    }
    const persons = [...perPerson.values()].sort((a, b) => a.sap.localeCompare(b.sap));

    const result: TestImportResult = {
      dryRun: data.dryRun,
      total: rows.length,
      inserted: 0,
      skippedExisting: rows.length - fresh.length,
      duplicatesInFile: parsed.duplicatesInFile,
      issues,
      persons,
      chain: { checked: 0, ok: true, message: null },
    };
    if (issues.length > 0 || data.dryRun || fresh.length === 0) return result;

    // zápis v poradí osoba, čas (hash reťaz ide podľa id, takže poradie zápisu je poradie reťaze)
    fresh.sort((a, b) =>
      a.sap === b.sap ? a.utc.getTime() - b.utc.getTime() || a.direction.localeCompare(b.direction) : a.sap.localeCompare(b.sap),
    );
    for (let i = 0; i < fresh.length; i += INSERT_CHUNK) {
      const chunk = fresh.slice(i, i + INSERT_CHUNK);
      const { error } = await admin.from("punches").insert(
        chunk.map((r) => ({
          client_uuid: r.uuid,
          user_id: r.user!,
          code: r.code,
          direction: r.direction,
          client_time: r.utc.toISOString(),
          source: "correction",
          device: TEST_DEVICE,
        })),
      );
      if (error) {
        result.issues.push({
          line: 0,
          text: `Zápis sa zastavil po ${result.inserted} razeniach: ${error.message}. Import zopakujte, už zapísané riadky sa nezdvoja.`,
        });
        break;
      }
      result.inserted += chunk.length;
    }

    // kontrola hash reťaze zapísaných používateľov
    const touched = [...new Set(fresh.map((r) => r.user!))];
    for (const user of touched) {
      const chain: ChainRow[] = [];
      for (let from = 0; ; from += PAGE) {
        const { data: page, error } = await admin
          .from("punches")
          .select("id, user_id, code, direction, client_time, server_time, client_uuid, device_id, prev_hash, record_hash")
          .eq("user_id", user)
          .order("id")
          .range(from, from + PAGE - 1);
        if (error) throw new Error("Reťaz razení sa nepodarilo overiť.");
        chain.push(...((page ?? []) as ChainRow[]));
        if ((page?.length ?? 0) < PAGE) break;
      }
      const check = await verifyChain(chain);
      result.chain.checked += 1;
      if (!check.ok && result.chain.ok) {
        result.chain = { checked: result.chain.checked, ok: false, message: `razenie č. ${check.id}: ${check.reason}` };
      }
    }

    await admin.from("audit_log").insert({
      actor: context.userId,
      action: "test_import",
      details: {
        organization,
        rows: rows.length,
        inserted: result.inserted,
        skipped_existing: result.skippedExisting,
        persons: persons.length,
        first: persons.map((p) => p.first).sort()[0] ?? null,
        last: persons.map((p) => p.last).sort().at(-1) ?? null,
        chain_ok: result.chain.ok,
        zone: TIME_ZONE,
        now_local: localTime(new Date().toISOString()),
      },
    });
    return result;
  });
