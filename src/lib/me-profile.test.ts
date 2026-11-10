import { describe, expect, it } from "vitest";
import {
  AUTH_REQUIRED_MESSAGE,
  INVALID_ME_RESPONSE_MESSAGE,
  loadMe,
  parseMeResponse,
  resetMeRpcStateForTests,
} from "./me-profile";

type RpcResult = { data: unknown; error: { message?: string; code?: string } | null };

interface Calls {
  rpc: string[];
  from: string[];
}

const UID = "11111111-1111-4111-8111-111111111111";
const ORG = "22222222-2222-4222-8222-222222222222";

const PROFILE = { id: UID, sap_id: "9000001", department: null, daily_fund: 7.5, organization_id: ORG };
const ORGANIZATION = { id: ORG, name: "Firma", is_test: false };
const ADMIN_RESPONSE = { roles: ["admin", "employee", "manager"], profile: PROFILE, organization: ORGANIZATION };

// Falošný klient: počíta volania a vracia pripravené odpovede. Žiadna skutočná sieť.
function fakeClient(opts: {
  rpc?: () => Promise<RpcResult>;
  legacy?: { roles?: { role: string }[]; flagError?: boolean; rolesError?: boolean };
}) {
  const calls: Calls = { rpc: [], from: [] };
  let organizationReads = 0;
  const client = {
    rpc: (name: string) => {
      calls.rpc.push(name);
      return opts.rpc ? opts.rpc() : Promise.resolve({ data: null, error: null });
    },
    from: (table: string) => {
      calls.from.push(table);
      const query: Record<string, unknown> = {
        select: () => query,
        eq: () => query,
        maybeSingle: () => {
          if (table === "profiles") return Promise.resolve({ data: PROFILE, error: null });
          organizationReads += 1;
          if (organizationReads === 1) return Promise.resolve({ data: { id: ORG, name: "Firma" }, error: null });
          if (opts.legacy?.flagError) return Promise.resolve({ data: null, error: { message: "column is_test does not exist" } });
          return Promise.resolve({ data: { is_test: true }, error: null });
        },
        // `await supabase.from("user_roles").select().eq()` je priamo očakávaný (bez maybeSingle).
        then: (resolve: (v: unknown) => unknown) =>
          Promise.resolve(
            opts.legacy?.rolesError
              ? { data: null, error: { message: "permission denied" } }
              : { data: opts.legacy?.roles ?? [{ role: "employee" }], error: null },
          ).then(resolve),
      };
      return query;
    },
  };
  return { client: client as never, calls };
}

async function failure(promise: Promise<unknown>): Promise<{ message?: string; code?: string } | undefined> {
  try {
    await promise;
    return undefined;
  } catch (error) {
    return error as { message?: string; code?: string };
  }
}

const missingFunction = () =>
  Promise.resolve({
    data: null,
    error: {
      code: "PGRST202",
      message: "Could not find the function public.get_my_profile without parameters in the schema cache",
    },
  });

describe("loadMe: jeden POST dopyt (RPC get_my_profile)", () => {
  it("správca s tromi rolami: jeden dopyt RPC a žiadne čítanie tabuliek", async () => {
    resetMeRpcStateForTests();
    const { client, calls } = fakeClient({ rpc: () => Promise.resolve({ data: ADMIN_RESPONSE, error: null }) });
    const me = await loadMe(client, UID);
    expect(me).toEqual({ roles: ["admin", "employee", "manager"], profile: PROFILE, organization: ORGANIZATION });
    expect(calls.rpc).toEqual(["get_my_profile"]);
    expect(calls.from).toHaveLength(0);
  });

  it("zamestnanec s jednou rolou a testovacou organizáciou, daily_fund ostáva číslo", async () => {
    resetMeRpcStateForTests();
    const response = { roles: ["employee"], profile: PROFILE, organization: { ...ORGANIZATION, is_test: true } };
    const { client } = fakeClient({ rpc: () => Promise.resolve({ data: response, error: null }) });
    const me = await loadMe(client, UID);
    expect(me.roles).toEqual(["employee"]);
    expect(me.profile?.daily_fund).toBe(7.5);
    expect(me.organization?.is_test).toBe(true);
  });

  it("účet bez profilu: prázdne roly, profil a organizácia null", async () => {
    resetMeRpcStateForTests();
    const response = { roles: [], profile: null, organization: null };
    const { client } = fakeClient({ rpc: () => Promise.resolve({ data: response, error: null }) });
    expect(await loadMe(client, UID)).toEqual({ roles: [], profile: null, organization: null });
  });

  it("osobné číslo a oddelenie môžu byť null", async () => {
    resetMeRpcStateForTests();
    const response = { roles: ["employee"], profile: { ...PROFILE, sap_id: null, department: null }, organization: ORGANIZATION };
    const { client } = fakeClient({ rpc: () => Promise.resolve({ data: response, error: null }) });
    const me = await loadMe(client, UID);
    expect(me.profile?.sap_id).toBeNull();
  });

  it("neznáma rola sa vynechá, prihlásenie sa pre ňu neodmietne", async () => {
    resetMeRpcStateForTests();
    const response = { ...ADMIN_RESPONSE, roles: ["employee", "auditor"] };
    const { client } = fakeClient({ rpc: () => Promise.resolve({ data: response, error: null }) });
    expect((await loadMe(client, UID)).roles).toEqual(["employee"]);
  });

  it("neplatný tvar odpovede je chyba, správa neobsahuje údaje z odpovede", async () => {
    resetMeRpcStateForTests();
    const bad = [
      { profile: PROFILE, organization: ORGANIZATION },
      { ...ADMIN_RESPONSE, roles: "admin" },
      { ...ADMIN_RESPONSE, profile: { ...PROFILE, daily_fund: "7.5" } },
      { ...ADMIN_RESPONSE, organization: { id: ORG, name: "Firma" } },
      "text",
      42,
    ];
    for (const data of bad) {
      const { client } = fakeClient({ rpc: () => Promise.resolve({ data, error: null }) });
      const err = await failure(loadMe(client, UID));
      expect(err?.message).toBe(INVALID_ME_RESPONSE_MESSAGE);
      expect(String(err?.message)).not.toContain("9000001");
    }
  });

  it("odpoveď null (bez prihlásenia) a chýbajúce uid sú chyba Prihlásenie je potrebné", async () => {
    resetMeRpcStateForTests();
    const nullReply = fakeClient({ rpc: () => Promise.resolve({ data: null, error: null }) });
    expect((await failure(loadMe(nullReply.client, UID)))?.message).toBe(AUTH_REQUIRED_MESSAGE);
    const noUid = fakeClient({});
    expect((await failure(loadMe(noUid.client, undefined)))?.message).toBe(AUTH_REQUIRED_MESSAGE);
    expect(noUid.calls.rpc).toHaveLength(0);
    expect(noUid.calls.from).toHaveLength(0);
  });

  it("parseMeResponse prijíma neznáme kľúče navyše", () => {
    const me = parseMeResponse({ ...ADMIN_RESPONSE, extra: 1 });
    expect(me.roles).toEqual(["admin", "employee", "manager"]);
  });
});

describe("loadMe: záloha len pri chýbajúcej funkcii", () => {
  it("PGRST202 použije pôvodné čítania a výsledok má rovnaký tvar vrátane is_test", async () => {
    resetMeRpcStateForTests();
    const { client, calls } = fakeClient({ rpc: missingFunction, legacy: { roles: [{ role: "employee" }, { role: "admin" }] } });
    const me = await loadMe(client, UID);
    expect(me).toEqual({
      roles: ["employee", "admin"],
      profile: PROFILE,
      organization: { id: ORG, name: "Firma", is_test: true },
    });
    expect(calls.rpc).toEqual(["get_my_profile"]);
    expect(calls.from).toEqual(["user_roles", "profiles", "organizations", "organizations"]);
  });

  it("rozpoznanie podľa správy bez kódu, a druhé volanie už RPC neskúša", async () => {
    resetMeRpcStateForTests();
    const rpc = () =>
      Promise.resolve({ data: null, error: { message: "Could not find the function public.get_my_profile in the schema cache" } });
    const first = fakeClient({ rpc });
    await loadMe(first.client, UID);
    expect(first.calls.rpc).toHaveLength(1);
    const second = fakeClient({ rpc });
    await loadMe(second.client, UID);
    expect(second.calls.rpc).toHaveLength(0);
    expect(second.calls.from).toHaveLength(4);
  });

  it("v zálohe chýbajúci stĺpec is_test neznemožní načítanie účtu (is_test sa nevráti)", async () => {
    resetMeRpcStateForTests();
    const { client } = fakeClient({ rpc: missingFunction, legacy: { flagError: true } });
    const me = await loadMe(client, UID);
    expect(me.organization).toEqual({ id: ORG, name: "Firma" });
  });

  it("v zálohe chyba čítania rolí je chyba", async () => {
    resetMeRpcStateForTests();
    const { client } = fakeClient({ rpc: missingFunction, legacy: { rolesError: true } });
    expect((await failure(loadMe(client, UID)))?.message).toBe("permission denied");
  });
});

describe("loadMe: pri chybe spojenia žiadna záloha (nepridáva blokovanú prevádzku)", () => {
  const errors: { label: string; error: { message: string; code?: string } }[] = [
    { label: "Failed to fetch", error: { message: "TypeError: Failed to fetch" } },
    { label: "ERR_CONNECTION_CLOSED", error: { message: "net::ERR_CONNECTION_CLOSED" } },
    { label: "certifikát", error: { message: "net::ERR_CERT_AUTHORITY_INVALID" } },
    { label: "HTML stránka proxy", error: { message: "<!DOCTYPE html><html><body>Blocked</body></html>" } },
    { label: "JWT vypršal (401)", error: { message: "JWT expired", code: "PGRST301" } },
    { label: "chyba servera", error: { message: "internal error", code: "XX000" } },
  ];
  for (const { label, error } of errors) {
    it(`${label}: chyba sa vyhodí a tabuľky sa nečítajú`, async () => {
      resetMeRpcStateForTests();
      const { client, calls } = fakeClient({ rpc: () => Promise.resolve({ data: null, error }) });
      const err = await failure(loadMe(client, UID));
      expect(err?.message).toBe(error.message);
      expect(calls.rpc).toHaveLength(1);
      expect(calls.from).toHaveLength(0);
    });
  }

  it("po chybe spojenia sa RPC neoznačí za chýbajúce: ďalší pokus ju skúsi znova", async () => {
    resetMeRpcStateForTests();
    const down = fakeClient({ rpc: () => Promise.resolve({ data: null, error: { message: "TypeError: Failed to fetch" } }) });
    await failure(loadMe(down.client, UID));
    const up = fakeClient({ rpc: () => Promise.resolve({ data: ADMIN_RESPONSE, error: null }) });
    const me = await loadMe(up.client, UID);
    expect(up.calls.rpc).toHaveLength(1);
    expect(me.roles).toHaveLength(3);
  });
});
