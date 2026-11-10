import { describe, expect, it } from "vitest";
import {
  AUTH_REQUIRED_MESSAGE,
  INVALID_OVERVIEW_MESSAGE,
  loadAdminOverview,
  parseAdminOverview,
  resetAdminOverviewStateForTests,
} from "./admin-overview";
import { isMissingFunction } from "./rpc-helpers";

type RpcResult = { data: unknown; error: { message?: string; code?: string } | null };

interface Calls {
  rpc: string[];
  from: string[];
}

const A1 = "11111111-1111-4111-8111-111111111111";
const A2 = "22222222-2222-4222-8222-222222222222";
const ORG = "33333333-3333-4333-8333-333333333333";
const CODE = "0123456789abcdef0123456789abcdef0123456789abcdef";

const PERSON_A1 = {
  id: A1,
  sap_id: "9000001",
  department: "IT",
  manager_id: null,
  daily_fund: 7.5,
  organization_id: ORG,
  roles: ["admin", "employee", "manager"],
};
const PERSON_A2 = {
  id: A2,
  sap_id: "9000002",
  department: null,
  manager_id: A1,
  daily_fund: 7.5,
  organization_id: ORG,
  roles: ["employee"],
};
const RESPONSE = { invite_code: CODE, people: [PERSON_A1, PERSON_A2] };

// Falošný klient: počíta volania a vracia pripravené odpovede. Žiadna skutočná sieť.
function fakeClient(opts: {
  rpc?: () => Promise<RpcResult>;
  legacy?: { inviteError?: boolean; profilesError?: boolean; rolesError?: boolean };
}) {
  const calls: Calls = { rpc: [], from: [] };
  const client = {
    rpc: (name: string) => {
      calls.rpc.push(name);
      return opts.rpc ? opts.rpc() : Promise.resolve({ data: null, error: null });
    },
    from: (table: string) => {
      calls.from.push(table);
      const query: Record<string, unknown> = {
        select: () => query,
        order: () => query,
        maybeSingle: () =>
          Promise.resolve(
            opts.legacy?.inviteError
              ? { data: null, error: { message: "permission denied" } }
              : { data: { code: CODE }, error: null },
          ),
        // `await supabase.from("profiles").select().order()` je priamo očakávaný (bez maybeSingle).
        then: (resolve: (v: unknown) => unknown) => {
          if (table === "profiles") {
            return Promise.resolve(
              opts.legacy?.profilesError
                ? { data: null, error: { message: "profiles failed" } }
                : {
                    data: [PERSON_A1, PERSON_A2].map(({ roles: _roles, ...rest }) => rest),
                    error: null,
                  },
            ).then(resolve);
          }
          return Promise.resolve(
            opts.legacy?.rolesError
              ? { data: null, error: { message: "roles failed" } }
              : {
                  data: [
                    { user_id: A1, role: "admin" },
                    { user_id: A1, role: "employee" },
                    { user_id: A2, role: "employee" },
                  ],
                  error: null,
                },
          ).then(resolve);
        },
      };
      return query;
    },
  };
  return { client: client as never, calls };
}

async function failure(
  promise: Promise<unknown>,
): Promise<{ message?: string; code?: string } | undefined> {
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
      message: "Could not find the function public.get_admin_overview without parameters in the schema cache",
    },
  });

describe("loadAdminOverview: jeden POST dopyt (RPC get_admin_overview)", () => {
  it("správca: pozývací kód a dvaja ľudia s rolami, jeden dopyt RPC a žiadne čítanie tabuliek", async () => {
    resetAdminOverviewStateForTests();
    const { client, calls } = fakeClient({ rpc: () => Promise.resolve({ data: RESPONSE, error: null }) });
    const overview = await loadAdminOverview(client);
    expect(overview.inviteCode).toBe(CODE);
    expect(overview.people).toHaveLength(2);
    expect(overview.people[0]?.roles).toEqual(["admin", "employee", "manager"]);
    expect(overview.people[1]?.manager_id).toBe(A1);
    expect(overview.people[0]?.daily_fund).toBe(7.5);
    expect(calls.rpc).toEqual(["get_admin_overview"]);
    expect(calls.from).toHaveLength(0);
  });

  it("zamestnanec: kód null sa zmení na undefined a dostane len seba", async () => {
    resetAdminOverviewStateForTests();
    const response = { invite_code: null, people: [PERSON_A2] };
    const { client } = fakeClient({ rpc: () => Promise.resolve({ data: response, error: null }) });
    const overview = await loadAdminOverview(client);
    expect(overview.inviteCode).toBeUndefined();
    expect(overview.people).toHaveLength(1);
  });

  it("prázdny zoznam ľudí je platná odpoveď", async () => {
    resetAdminOverviewStateForTests();
    const { client } = fakeClient({
      rpc: () => Promise.resolve({ data: { invite_code: null, people: [] }, error: null }),
    });
    const overview = await loadAdminOverview(client);
    expect(overview.people).toHaveLength(0);
  });

  it("osobné číslo, oddelenie a nadriadený môžu byť null", async () => {
    resetAdminOverviewStateForTests();
    const person = { ...PERSON_A2, sap_id: null, department: null, manager_id: null };
    const { client } = fakeClient({
      rpc: () => Promise.resolve({ data: { invite_code: CODE, people: [person] }, error: null }),
    });
    const overview = await loadAdminOverview(client);
    expect(overview.people[0]?.sap_id).toBeNull();
  });

  it("neznáma rola sa vynechá, zoznam sa pre ňu neodmietne", async () => {
    resetAdminOverviewStateForTests();
    const person = { ...PERSON_A2, roles: ["employee", "auditor"] };
    const { client } = fakeClient({
      rpc: () => Promise.resolve({ data: { invite_code: CODE, people: [person] }, error: null }),
    });
    expect((await loadAdminOverview(client)).people[0]?.roles).toEqual(["employee"]);
  });

  it("neplatný tvar odpovede je chyba, správa neobsahuje údaje z odpovede", async () => {
    resetAdminOverviewStateForTests();
    const bad = [
      { people: [PERSON_A1] },
      { invite_code: CODE },
      { invite_code: CODE, people: "nie pole" },
      { invite_code: 7, people: [] },
      { invite_code: CODE, people: [{ ...PERSON_A1, daily_fund: "7.5" }] },
      { invite_code: CODE, people: [{ ...PERSON_A1, roles: "admin" }] },
      { invite_code: CODE, people: [{ ...PERSON_A1, id: undefined }] },
      "text",
      42,
    ];
    for (const data of bad) {
      const { client } = fakeClient({ rpc: () => Promise.resolve({ data, error: null }) });
      const err = await failure(loadAdminOverview(client));
      expect(err?.message).toBe(INVALID_OVERVIEW_MESSAGE);
      expect(String(err?.message)).not.toContain(CODE);
      expect(String(err?.message)).not.toContain("9000001");
    }
  });

  it("odpoveď null (bez prihlásenia) je chyba Prihlásenie je potrebné", async () => {
    resetAdminOverviewStateForTests();
    const { client } = fakeClient({ rpc: () => Promise.resolve({ data: null, error: null }) });
    expect((await failure(loadAdminOverview(client)))?.message).toBe(AUTH_REQUIRED_MESSAGE);
  });

  it("parseAdminOverview prijíma neznáme kľúče navyše", () => {
    const overview = parseAdminOverview({ ...RESPONSE, extra: 1 });
    expect(overview.people).toHaveLength(2);
  });
});

describe("loadAdminOverview: záloha len pri chýbajúcej funkcii", () => {
  it("PGRST202 použije pôvodné tri čítania a výsledok má rovnaký tvar", async () => {
    resetAdminOverviewStateForTests();
    const { client, calls } = fakeClient({ rpc: missingFunction });
    const overview = await loadAdminOverview(client);
    expect(overview.inviteCode).toBe(CODE);
    expect(overview.people).toHaveLength(2);
    expect(overview.people[0]?.roles).toEqual(["admin", "employee"]);
    expect(overview.people[1]?.roles).toEqual(["employee"]);
    expect(calls.rpc).toEqual(["get_admin_overview"]);
    expect(calls.from).toEqual(["organization_invites", "profiles", "user_roles"]);
  });

  it("rozpoznanie podľa správy bez kódu, a druhé volanie už RPC neskúša", async () => {
    resetAdminOverviewStateForTests();
    const rpc = () =>
      Promise.resolve({
        data: null,
        error: { message: "Could not find the function public.get_admin_overview in the schema cache" },
      });
    const first = fakeClient({ rpc });
    await loadAdminOverview(first.client);
    expect(first.calls.rpc).toHaveLength(1);
    const second = fakeClient({ rpc });
    await loadAdminOverview(second.client);
    expect(second.calls.rpc).toHaveLength(0);
    expect(second.calls.from).toHaveLength(3);
  });

  it("v zálohe chyba čítania pozývacieho kódu neblokuje zoznam ľudí", async () => {
    resetAdminOverviewStateForTests();
    const { client } = fakeClient({ rpc: missingFunction, legacy: { inviteError: true } });
    const overview = await loadAdminOverview(client);
    expect(overview.inviteCode).toBeUndefined();
    expect(overview.people).toHaveLength(2);
  });

  it("v zálohe chyba čítania profilov alebo rolí je chyba", async () => {
    resetAdminOverviewStateForTests();
    const profiles = fakeClient({ rpc: missingFunction, legacy: { profilesError: true } });
    expect((await failure(loadAdminOverview(profiles.client)))?.message).toBe("profiles failed");
    resetAdminOverviewStateForTests();
    const roles = fakeClient({ rpc: missingFunction, legacy: { rolesError: true } });
    expect((await failure(loadAdminOverview(roles.client)))?.message).toBe("roles failed");
  });
});

describe("loadAdminOverview: pri chybe spojenia žiadna záloha (nepridáva blokovanú prevádzku)", () => {
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
      resetAdminOverviewStateForTests();
      const { client, calls } = fakeClient({ rpc: () => Promise.resolve({ data: null, error }) });
      const err = await failure(loadAdminOverview(client));
      expect(err?.message).toBe(error.message);
      expect(calls.rpc).toHaveLength(1);
      expect(calls.from).toHaveLength(0);
    });
  }

  it("po chybe spojenia sa RPC neoznačí za chýbajúcu: ďalší pokus ju skúsi znova", async () => {
    resetAdminOverviewStateForTests();
    const down = fakeClient({
      rpc: () => Promise.resolve({ data: null, error: { message: "TypeError: Failed to fetch" } }),
    });
    await failure(loadAdminOverview(down.client));
    const up = fakeClient({ rpc: () => Promise.resolve({ data: RESPONSE, error: null }) });
    const overview = await loadAdminOverview(up.client);
    expect(up.calls.rpc).toHaveLength(1);
    expect(overview.people).toHaveLength(2);
  });
});

describe("isMissingFunction", () => {
  it("rozpozná PGRST202 aj správu a nič iné", () => {
    expect(isMissingFunction({ code: "PGRST202" })).toBe(true);
    expect(isMissingFunction({ message: "Could not find the function public.x" })).toBe(true);
    expect(isMissingFunction({ message: "TypeError: Failed to fetch" })).toBe(false);
    expect(isMissingFunction({ code: "42501", message: "permission denied" })).toBe(false);
    expect(isMissingFunction({})).toBe(false);
  });
});
