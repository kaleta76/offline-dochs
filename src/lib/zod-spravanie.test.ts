// Správanie validácie, na ktorom stojí aplikácia a ktoré sa pri prechode zod 3 → 4 mohlo zmeniť (13. 11. 2026).
// Test nekontroluje knižnicu, ale naše schémy: prijaté a odmietnuté tvary, ktoré sú pre prevádzku podstatné.
import { Blob as NodeBlob } from "node:buffer";
import { webcrypto } from "node:crypto";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { employeeAccessSchema, employeeAuthEmail } from "./account-rules";
import { fingerprintPunches, parseLateFileText } from "./late-punches";
import { parseImportStatus } from "./org-transfer-import";
import { parseBegin, parseFinish, TransferError } from "./org-transfer";
import { registerSchema } from "./onboarding-rules";
import { sanitizeProfileCache } from "./personnel";

beforeAll(() => {
  vi.stubGlobal("Blob", NodeBlob);
  vi.stubGlobal("crypto", webcrypto);
});

const V4 = "a1b2c3d4-0000-4000-8000-000000000001";
// Postgres uuid prijme aj tvar, ktorý nie je RFC verzia 1 až 8 (zod 4 `.uuid()` by ho odmietol), preto schémy používajú z.guid().
const NIL_LIKE = "00000000-0000-0000-0000-000000000001";
const V1_LIKE = "11111111-1111-1111-1111-111111111111";
const UPPER = "A1B2C3D4-0000-4000-8000-00000000000A";
const NOT_UUID = [
  `{${V4}}`,
  `urn:uuid:${V4}`,
  `${V4}\n`,
  V4.slice(1),
  V4.replace("a1b2", "g1b2"),
  "",
  "abc",
];

describe("UUID v schémach", () => {
  const access = (organization: string) =>
    employeeAccessSchema.safeParse({ organization, number: "1234567", password: "12345678" });

  it.each([V4, NIL_LIKE, V1_LIKE, UPPER])("prijme %s", (id) => {
    expect(access(id).success).toBe(true);
    expect(employeeAuthEmail(id, "1234567")).toBe(`1234567.${id}@accounts.invalid`);
  });

  it.each(NOT_UUID)("odmietne %j", (id) => {
    expect(access(id).success).toBe(false);
    expect(() => employeeAuthEmail(id, "1234567")).toThrow();
  });

  it("odpovede prenosu organizácie prijmú aj tvar uuid, ktorý nie je „čistý“ v4", () => {
    const finish = (transfer_id: string) =>
      parseFinish({
        state: "exported",
        transfer_id,
        locked: false,
        is_test: true,
        protected: false,
      });
    for (const id of [V4, NIL_LIKE, V1_LIKE, UPPER]) expect(finish(id).transfer_id).toBe(id);
    for (const id of NOT_UUID) expect(() => finish(id)).toThrow(TransferError);

    const begin = parseBegin({
      transfer_id: NIL_LIKE,
      locked: true,
      meta: { format: 2, organization: { id: V1_LIKE, name: "N", code: "ABCD1234" } },
      tables: [{ rel: "public.punches", n: 1 }],
    });
    expect(begin.transfer_id).toBe(NIL_LIKE);
    expect(begin.meta.organization.id).toBe(V1_LIKE);

    const status = parseImportStatus({
      eligible: true,
      reasons: [],
      active: {
        import_id: NIL_LIKE,
        state: "checked",
        organization: { id: V1_LIKE, name: "N", code: "C" },
        rows: 1,
        received: 0,
      },
    });
    expect(status.active?.importId).toBe(NIL_LIKE);
  });
});

describe("neznáme kľúče v odpovediach", () => {
  it("meta a organizácia pri začiatku prenosu ostanú (passthrough), kľúče navyše na vrchu sa zahodia", () => {
    const begin = parseBegin({
      transfer_id: V4,
      locked: true,
      junk: 1,
      meta: {
        format: 2,
        organization: { id: V4, name: "N", code: "ABCD1234", extra: "x" },
        other: { a: 1 },
      },
      tables: [{ rel: "public.punches", n: 3 }],
    });
    expect(begin).not.toHaveProperty("junk");
    expect(begin.meta).toMatchObject({ other: { a: 1 } });
    expect(begin.meta.organization).toMatchObject({ extra: "x" });
  });
});

describe("registrácia", () => {
  const base = { code: "ABCD1234", name: "Firma", number: "1234567", password: "Dlhe-Heslo-12345" };

  it("bez súhlasu so zodpovednosťou vráti slovenskú hlášku pri poli accepted", () => {
    for (const accepted of [false, undefined, "true", 1]) {
      const r = registerSchema.safeParse({ ...base, accepted });
      expect(r.success).toBe(false);
      if (!r.success) {
        const issue = r.error.issues.find((i) => i.path.join(".") === "accepted");
        expect(issue?.message).toBe("Je potrebný súhlas so zodpovednosťou.");
      }
    }
  });
});

describe("medzipamäť profilu", () => {
  const profile = (extra: Record<string, unknown>) => ({
    roles: ["admin"],
    profile: { id: "p", department: null, daily_fund: 1, organization_id: null, ...extra },
    organization: null,
  });

  it("chýbajúce, prázdne aj neplatné osobné číslo sa zmení na null, platné ostane", () => {
    expect(sanitizeProfileCache(profile({}))?.profile?.sap_id).toBeNull();
    expect(sanitizeProfileCache(profile({ sap_id: undefined }))?.profile?.sap_id).toBeNull();
    expect(sanitizeProfileCache(profile({ sap_id: null }))?.profile?.sap_id).toBeNull();
    expect(sanitizeProfileCache(profile({ sap_id: "12" }))?.profile?.sap_id).toBeNull();
    expect(sanitizeProfileCache(profile({ sap_id: "1234567" }))?.profile?.sap_id).toBe("1234567");
  });
});

describe("súbor s razeniami zo zariadenia", () => {
  const punch = (extra: Record<string, unknown> = {}) => ({
    client_uuid: "11111111-1111-4111-8111-111111111111",
    user_id: "22222222-2222-4222-8222-222222222222",
    code: "WORK",
    direction: "IN",
    client_time: "2026-11-10T08:00:00.123+01:00",
    device: "ua",
    ...extra,
  });
  const file = async (punches: unknown[], extra: Record<string, unknown> = {}) =>
    JSON.stringify({
      format: "dochs-late-punches",
      version: 1,
      created_at: "2026-11-10T09:00:00.000Z",
      origin: "http://x",
      count: punches.length,
      fingerprint: await fingerprintPunches(punches as Parameters<typeof fingerprintPunches>[0]),
      punches,
      ...extra,
    });

  it("kľúč navyše v razení (napr. kľúč zariadenia) súbor odmietne, kľúč navyše na vrchu sa zahodí", async () => {
    await expect(parseLateFileText(await file([punch()], { junk: 1 }))).resolves.toMatchObject({
      punches: [expect.objectContaining({ code: "WORK" })],
    });
    await expect(parseLateFileText(await file([punch({ key: "tajne" })]))).rejects.toThrow(
      "poškodený alebo upravený",
    );
  });
});
