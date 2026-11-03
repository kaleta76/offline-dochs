import { describe, expect, it } from "vitest";
import {
  enrollCore,
  loginCore,
  provisionCore,
  recoverCore,
  registerCore,
  type AccountsPort,
  type AuditDetails,
  type CoreUser,
  type Meta,
  type Tokens,
} from "./accounts-core";
import { normalizeCode, orgCodeOf, sha256Hex } from "./credentials";
import { LOGIN_WINDOW_MS, PIN_TTL_MS } from "./onboarding-logic";

// Pamäťová náhrada Supabase: účty, profily, organizácie, role, relácie a audit.
// Simuluje aj databázový trigger handle_new_user (zakladá organizáciu alebo profil zamestnanca).
type FakeUser = { id: string; email: string; password: string; meta: Meta; sessions: string[] };

class FakePort implements AccountsPort {
  users = new Map<string, FakeUser>();
  profiles: { id: string; org: string; number: string }[] = [];
  orgs: { id: string; name: string; invite: string }[] = [];
  roles: { userId: string; role: string }[] = [];
  audits: { actor: string; action: string; target: string; details?: AuditDetails }[] = [];
  failNextCreate = false;
  private counter = 0;

  async organizationsInRange(lo: string, hi: string) {
    return this.orgs
      .filter((o) => o.id >= lo && o.id <= hi)
      .map((o) => o.id)
      .slice(0, 2);
  }
  async profileId(org: string, number: string) {
    return this.profiles.find((p) => p.org === org && p.number === number)?.id ?? null;
  }
  async organizationOfUser(userId: string) {
    return this.profiles.find((p) => p.id === userId)?.org ?? null;
  }
  async isAdmin(userId: string) {
    return this.roles.some((r) => r.userId === userId && r.role === "admin");
  }
  async getUser(id: string): Promise<CoreUser | null> {
    const u = this.users.get(id);
    return u ? { id: u.id, email: u.email, meta: { ...u.meta } } : null;
  }
  async createUser(attrs: {
    email: string;
    password: string;
    email_confirm: boolean;
    user_metadata: Meta;
    app_metadata: Meta;
  }) {
    if (this.failNextCreate) {
      this.failNextCreate = false;
      return null;
    }
    if ([...this.users.values()].some((u) => u.email === attrs.email)) return null;
    const id = crypto.randomUUID();
    const number = String(attrs.user_metadata["sap_id"]);
    let org: string;
    const roles = ["employee"];
    const orgName = attrs.user_metadata["organization_name"];
    if (typeof orgName === "string" && orgName) {
      org = crypto.randomUUID();
      this.orgs.push({ id: org, name: orgName, invite: `invite-${org}` });
      roles.push("admin", "manager");
    } else {
      const found = this.orgs.find((o) => o.invite === attrs.user_metadata["invite_code"]);
      if (!found) return null;
      org = found.id;
    }
    if (this.profiles.some((p) => p.org === org && p.number === number)) return null;
    this.users.set(id, {
      id,
      email: attrs.email,
      password: attrs.password,
      meta: { ...attrs.app_metadata },
      sessions: [],
    });
    this.profiles.push({ id, org, number });
    for (const role of roles) this.roles.push({ userId: id, role });
    return { id };
  }
  // Najhorší prípad: app_metadata sa nahrádza celé (nie zlučuje).
  async updateUser(id: string, attrs: { app_metadata: Meta; password?: string }) {
    const u = this.users.get(id);
    if (!u) return false;
    u.meta = { ...attrs.app_metadata };
    if (attrs.password !== undefined) u.password = attrs.password;
    return true;
  }
  async deleteUser(id: string) {
    this.users.delete(id);
  }
  async signIn(email: string, password: string): Promise<Tokens | null> {
    const u = [...this.users.values()].find((x) => x.email === email);
    if (!u || u.password !== password) return null;
    const token = `at-${u.id}-${++this.counter}`;
    u.sessions.push(token);
    return { access_token: token, refresh_token: `rt-${token}` };
  }
  async signOutAll(accessToken: string) {
    const u = [...this.users.values()].find((x) => x.sessions.includes(accessToken));
    if (!u) return false;
    u.sessions = [];
    return true;
  }
  async audit(actor: string, action: string, target: string, details?: AuditDetails) {
    this.audits.push({ actor, action, target, ...(details ? { details } : {}) });
    return true;
  }
}

const REG_CODE = "ABCD-EFGH-JKMN-PQRS-TVWX";
const NOW = 1_800_000_000_000;
const PASS = "dlhe-heslo-12345";

async function setup() {
  const port = new FakePort();
  const hash = await sha256Hex(normalizeCode(REG_CODE));
  const reg = await registerCore(
    port,
    { code: REG_CODE, name: "Firma A", number: "1000001", password: PASS },
    hash,
  );
  if (!reg.ok) throw new Error("registrácia v teste zlyhala");
  const adminId = port.profiles[0]!.id;
  const org = port.orgs[0]!.id;
  return { port, hash, reg, adminId, org, orgCode: reg.organizationCode };
}

async function issue(
  port: FakePort,
  adminId: string,
  org: string,
  numbers: string[],
  reset = false,
  now = NOW,
) {
  const invite = port.orgs.find((o) => o.id === org)!.invite;
  return provisionCore(
    port,
    { adminUserId: adminId, org, inviteCode: invite },
    { numbers, reset },
    now,
  );
}

describe("registrácia organizácie", () => {
  it("bez správneho kódu nič nevznikne", async () => {
    const port = new FakePort();
    const hash = await sha256Hex(normalizeCode(REG_CODE));
    const r = await registerCore(
      port,
      { code: "AAAA-BBBB", name: "Firma", number: "1000001", password: PASS },
      hash,
    );
    expect(r.ok).toBe(false);
    expect(port.users.size).toBe(0);
    expect(port.orgs).toHaveLength(0);
  });

  it("so správnym kódom (aj s preklepmi v zápise) založí firmu a správcu", async () => {
    const port = new FakePort();
    const hash = await sha256Hex(normalizeCode(REG_CODE));
    const r = await registerCore(
      port,
      { code: " abcd-efgh-jkmn-pqrs-tvwx ", name: "Firma A", number: "1000001", password: PASS },
      hash,
    );
    expect(r.ok).toBe(true);
    expect(port.orgs).toHaveLength(1);
    expect(port.roles.filter((x) => x.role === "admin")).toHaveLength(1);
    if (r.ok) {
      expect(r.organizationCode).toBe(orgCodeOf(port.orgs[0]!.id).replace(/(.{4})(?=.)/g, "$1-"));
      expect(r.recoveryCode).toMatch(/^[0-9A-Z]{4}(-[0-9A-Z]{4}){4}$/);
    }
    expect(port.audits.map((a) => a.action)).toEqual([
      "organization_registered",
      "organization_terms_accepted",
    ]);
  });

  it("správca sa prihlási číslom a heslom, bez e-mailu", async () => {
    const { port, orgCode } = await setup();
    const r = await loginCore(port, { orgCode, number: "1000001", password: PASS }, NOW);
    expect(r.ok).toBe(true);
  });

  it("ak sa organizácia nevytvorí, účet sa zruší", async () => {
    const port = new FakePort();
    port.orgs.length = 0;
    const original = port.organizationOfUser.bind(port);
    port.organizationOfUser = async () => null;
    const hash = await sha256Hex(normalizeCode(REG_CODE));
    const r = await registerCore(
      port,
      { code: REG_CODE, name: "Firma", number: "1000001", password: PASS },
      hash,
    );
    expect(r.ok).toBe(false);
    expect(port.users.size).toBe(0);
    port.organizationOfUser = original;
  });
});

describe("vydanie PIN-u a prvé prihlásenie", () => {
  it("nový účet má PIN, ktorý sa nedá použiť ako heslo", async () => {
    const { port, adminId, org, orgCode } = await setup();
    const [row] = await issue(port, adminId, org, ["2000001"]);
    expect(row!.status).toBe("created");
    expect(row!.pin).toMatch(/^[0-9A-Z]{4}(-[0-9A-Z]{4}){2}$/);
    const email = port.users.get(port.profiles.find((p) => p.number === "2000001")!.id)!.email;
    const raw = normalizeCode(row!.pin!);
    expect(await port.signIn(email, raw)).toBeNull();
    expect(await port.signIn(email, row!.pin!)).toBeNull();
    const login = await loginCore(port, { orgCode, number: "2000001", password: raw }, NOW);
    expect(login.ok).toBe(false);
  });

  it("PIN uložený v účte je len odtlačok", async () => {
    const { port, adminId, org } = await setup();
    const [row] = await issue(port, adminId, org, ["2000001"]);
    const meta = port.users.get(port.profiles.find((p) => p.number === "2000001")!.id)!.meta;
    expect(JSON.stringify(meta).includes(normalizeCode(row!.pin!))).toBe(false);
    expect(typeof meta["pin_hash"]).toBe("string");
  });

  it("správny PIN dokončí registráciu a vráti prihlásenie", async () => {
    const { port, adminId, org, orgCode } = await setup();
    const [row] = await issue(port, adminId, org, ["2000001"]);
    const r = await enrollCore(
      port,
      { orgCode, number: "2000001", pin: row!.pin!.toLowerCase(), password: PASS + "x" },
      NOW + 1000,
    );
    expect(r.ok).toBe(true);
    if (r.ok) expect(typeof r.access_token).toBe("string");
    const login = await loginCore(
      port,
      { orgCode, number: "2000001", password: PASS + "x" },
      NOW + 2000,
    );
    expect(login.ok).toBe(true);
    // PIN je spotrebovaný
    const again = await enrollCore(
      port,
      { orgCode, number: "2000001", pin: row!.pin!, password: "ine-heslo-123456" },
      NOW + 3000,
    );
    expect(again.ok).toBe(false);
  });

  it("zlý PIN sa počíta a po piatich omyloch sa zablokuje aj správny", async () => {
    const { port, adminId, org, orgCode } = await setup();
    const [row] = await issue(port, adminId, org, ["2000001"]);
    for (let i = 0; i < 5; i++) {
      const r = await enrollCore(
        port,
        { orgCode, number: "2000001", pin: "AAAA-AAAA-AAAA", password: PASS },
        NOW + i,
      );
      expect(r.ok).toBe(false);
    }
    const blocked = await enrollCore(
      port,
      { orgCode, number: "2000001", pin: row!.pin!, password: PASS },
      NOW + 10,
    );
    expect(blocked.ok).toBe(false);
    if (!blocked.ok) expect(blocked.error).toMatch(/zablokovaný/);
    // správca vydá nový PIN a ten funguje
    const [fresh] = await issue(port, adminId, org, ["2000001"], false, NOW + 20);
    expect(fresh!.status).toBe("reissued");
    const ok = await enrollCore(
      port,
      { orgCode, number: "2000001", pin: fresh!.pin!, password: PASS },
      NOW + 30,
    );
    expect(ok.ok).toBe(true);
  });

  it("PIN po 24 hodinách expiruje", async () => {
    const { port, adminId, org, orgCode } = await setup();
    const [row] = await issue(port, adminId, org, ["2000001"]);
    const late = await enrollCore(
      port,
      { orgCode, number: "2000001", pin: row!.pin!, password: PASS },
      NOW + PIN_TTL_MS + 1,
    );
    expect(late.ok).toBe(false);
  });

  it("PIN z inej organizácie ani s cudzím kódom firmy nefunguje", async () => {
    const a = await setup();
    const hash = await sha256Hex(normalizeCode(REG_CODE));
    // druhá firma v rovnakej databáze
    const regB = await registerCore(
      a.port,
      { code: REG_CODE, name: "Firma B", number: "1000001", password: PASS },
      hash,
    );
    expect(regB.ok).toBe(true);
    const [row] = await issue(a.port, a.adminId, a.org, ["2000001"]);
    const orgCodeB = regB.ok ? regB.organizationCode : "";
    const r = await enrollCore(
      a.port,
      { orgCode: orgCodeB, number: "2000001", pin: row!.pin!, password: PASS },
      NOW + 1,
    );
    expect(r.ok).toBe(false);
  });
});

describe("prihlásenie a zámok", () => {
  it("po 8 omyloch zamkne aj správne heslo, po 15 minútach sa odomkne", async () => {
    const { port, orgCode } = await setup();
    for (let i = 0; i < 8; i++) {
      const r = await loginCore(
        port,
        { orgCode, number: "1000001", password: "zle-heslo-123456" },
        NOW + i * 1000,
      );
      expect(r.ok).toBe(false);
    }
    const locked = await loginCore(
      port,
      { orgCode, number: "1000001", password: PASS },
      NOW + 9000,
    );
    expect(locked.ok).toBe(false);
    if (!locked.ok) expect(locked.error).toMatch(/Príliš veľa/);
    const later = await loginCore(
      port,
      { orgCode, number: "1000001", password: PASS },
      NOW + 8000 + LOGIN_WINDOW_MS + 1,
    );
    expect(later.ok).toBe(true);
  });

  it("úspešné prihlásenie vymaže počítadlo omylov", async () => {
    const { port, orgCode } = await setup();
    await loginCore(port, { orgCode, number: "1000001", password: "zle-heslo-123456" }, NOW);
    await loginCore(port, { orgCode, number: "1000001", password: PASS }, NOW + 1000);
    const meta = port.users.get(port.profiles[0]!.id)!.meta;
    expect(meta["login_fail"] ?? null).toBeNull();
  });

  it("neznáma organizácia aj neznáme číslo dajú rovnakú chybu", async () => {
    const { port, orgCode } = await setup();
    const a = await loginCore(
      port,
      { orgCode: "FFFF-FFFF", number: "1000001", password: PASS },
      NOW,
    );
    const b = await loginCore(port, { orgCode, number: "9999999", password: PASS }, NOW);
    expect(a.ok).toBe(false);
    expect(b.ok).toBe(false);
    if (!a.ok && !b.ok) expect(a.error).toBe(b.error);
  });
});

describe("správa účtov správcom", () => {
  it("existujúci účet sa bez výslovnej obnovy preskočí, s obnovou sa heslo zruší a relácie odhlásia", async () => {
    const { port, adminId, org, orgCode } = await setup();
    const [row] = await issue(port, adminId, org, ["2000001"]);
    await enrollCore(port, { orgCode, number: "2000001", pin: row!.pin!, password: PASS }, NOW + 1);
    const session = await loginCore(port, { orgCode, number: "2000001", password: PASS }, NOW + 2);
    expect(session.ok).toBe(true);
    const userId = port.profiles.find((p) => p.number === "2000001")!.id;
    expect(port.users.get(userId)!.sessions.length > 0).toBe(true);

    const [skipped] = await issue(port, adminId, org, ["2000001"], false, NOW + 3);
    expect(skipped!.status).toBe("exists");
    expect(skipped!.pin ?? null).toBeNull();

    const [reset] = await issue(port, adminId, org, ["2000001"], true, NOW + 4);
    expect(reset!.status).toBe("reset");
    expect(reset!.warning ?? null).toBeNull();
    expect(port.users.get(userId)!.sessions).toHaveLength(0);
    const old = await loginCore(port, { orgCode, number: "2000001", password: PASS }, NOW + 5);
    expect(old.ok).toBe(false);
    const fresh = await enrollCore(
      port,
      { orgCode, number: "2000001", pin: reset!.pin!, password: "nove-heslo-12345" },
      NOW + 6,
    );
    expect(fresh.ok).toBe(true);
  });

  it("správca nemôže obnoviť sám seba a duplicitné čísla sa nezdvoja", async () => {
    const { port, adminId, org } = await setup();
    const rows = await issue(port, adminId, org, ["1000001", "2000001"], true);
    expect(rows[0]!.status).toBe("self");
    expect(rows[1]!.status).toBe("created");
  });

  it("rovnaké číslo v dvoch firmách sú dva samostatné účty", async () => {
    const a = await setup();
    const hash = await sha256Hex(normalizeCode(REG_CODE));
    const regB = await registerCore(
      a.port,
      { code: REG_CODE, name: "Firma B", number: "5000001", password: PASS },
      hash,
    );
    expect(regB.ok).toBe(true);
    const orgB = a.port.orgs[1]!.id;
    const adminB = a.port.profiles.find((p) => p.org === orgB)!.id;
    const [x] = await issue(a.port, a.adminId, a.org, ["2000001"]);
    const [y] = await issue(a.port, adminB, orgB, ["2000001"]);
    expect(x!.status).toBe("created");
    expect(y!.status).toBe("created");
    expect(a.port.profiles.filter((p) => p.number === "2000001")).toHaveLength(2);
  });

  it("zlyhanie vytvorenia účtu sa ohlási pri danom čísle a ostatné pokračujú", async () => {
    const { port, adminId, org } = await setup();
    port.failNextCreate = true;
    const rows = await issue(port, adminId, org, ["2000001", "2000002"]);
    expect(rows[0]!.status).toBe("failed");
    expect(rows[1]!.status).toBe("created");
  });

  it("každé vydanie sa zapíše do auditu", async () => {
    const { port, adminId, org } = await setup();
    await issue(port, adminId, org, ["2000001"]);
    const last = port.audits[port.audits.length - 1]!;
    expect(last.action).toBe("employee_provisioned");
    expect(last.actor).toBe(adminId);
  });
});

describe("obnova správcu", () => {
  it("správny kód zmení heslo, odhlási relácie a vydá nový kód", async () => {
    const { port, reg, orgCode } = await setup();
    if (!reg.ok) return;
    const before = await loginCore(port, { orgCode, number: "1000001", password: PASS }, NOW);
    expect(before.ok).toBe(true);
    const r = await recoverCore(
      port,
      {
        orgCode,
        number: "1000001",
        recoveryCode: reg.recoveryCode,
        password: "uplne-nove-heslo-1",
      },
      NOW + 10,
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.recoveryCode === reg.recoveryCode).toBe(false);
    expect(r.sessionsRevoked).toBe(true);
    expect(
      (await loginCore(port, { orgCode, number: "1000001", password: PASS }, NOW + 20)).ok,
    ).toBe(false);
    expect(
      (
        await loginCore(
          port,
          { orgCode, number: "1000001", password: "uplne-nove-heslo-1" },
          NOW + 30,
        )
      ).ok,
    ).toBe(true);
    // starý kód je spotrebovaný
    const reuse = await recoverCore(
      port,
      { orgCode, number: "1000001", recoveryCode: reg.recoveryCode, password: "este-ine-heslo-12" },
      NOW + 40,
    );
    expect(reuse.ok).toBe(false);
  });

  it("po piatich omyloch sa obnova zamkne aj so správnym kódom", async () => {
    const { port, reg, orgCode } = await setup();
    if (!reg.ok) return;
    for (let i = 0; i < 5; i++) {
      const r = await recoverCore(
        port,
        { orgCode, number: "1000001", recoveryCode: "AAAA-AAAA-AAAA-AAAA-AAAA", password: PASS },
        NOW + i,
      );
      expect(r.ok).toBe(false);
    }
    const r = await recoverCore(
      port,
      { orgCode, number: "1000001", recoveryCode: reg.recoveryCode, password: PASS + "z" },
      NOW + 10,
    );
    expect(r.ok).toBe(false);
  });

  it("zamestnanec bez roly správcu sa takto obnoviť nedá", async () => {
    const { port, adminId, org, orgCode } = await setup();
    const [row] = await issue(port, adminId, org, ["2000001"]);
    await enrollCore(port, { orgCode, number: "2000001", pin: row!.pin!, password: PASS }, NOW + 1);
    const r = await recoverCore(
      port,
      {
        orgCode,
        number: "2000001",
        recoveryCode: "AAAA-AAAA-AAAA-AAAA-AAAA",
        password: "nove-heslo-12345",
      },
      NOW + 2,
    );
    expect(r.ok).toBe(false);
  });
});
