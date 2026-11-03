// Jadro registrácie firiem a zamestnancov bez e-mailu (docs/REGISTRACIA.md).
// Nezávisí od Supabase ani od frameworku: všetko, čo potrebuje, dostane cez rozhranie AccountsPort.
// Skutočný port (Supabase) je v accounts.functions.ts, v testoch je to pamäťová náhrada.
//
// Zamestnanec sa identifikuje kódom organizácie a osobným číslom. Prvé prihlásenie ide cez
// jednorazový PIN od správcu, ktorý sa ukladá len ako odtlačok v app_metadata účtu. Heslo účtu je
// pritom náhodné a nikomu neznáme, takže PIN nejde použiť inak než cez enrollCore.
// Čakané chyby (zlý PIN, zlý kód) sa vracajú ako { ok: false, error }, nie ako výnimka.

import {
  PIN_LENGTH,
  RECOVERY_LENGTH,
  formatCode,
  hashSecret,
  normalizeCode,
  orgCodeOf,
  orgPrefixRange,
  randomCode,
  randomSalt,
  safeEqualHex,
  sha256Hex,
} from "./credentials";
import {
  LOGIN_LIMIT,
  LOGIN_WINDOW_MS,
  PIN_MAX_ATTEMPTS,
  PIN_TTL_MS,
  RECOVERY_LIMIT,
  RECOVERY_WINDOW_MS,
  clearPatch,
  failurePatch,
  hasFailures,
  isThrottled,
  pinStatus,
} from "./onboarding-logic";

export type Meta = Record<string, unknown>;
export type CoreUser = { id: string; email: string | null; meta: Meta };
export type Tokens = { access_token: string; refresh_token: string };
export type AuditDetails = { [key: string]: string | number | boolean | null };

export interface AccountsPort {
  /** Identifikátory organizácií, ktorých UUID leží v rozsahu (stačí vrátiť najviac 2). */
  organizationsInRange(lo: string, hi: string): Promise<string[]>;
  profileId(org: string, number: string): Promise<string | null>;
  organizationOfUser(userId: string): Promise<string | null>;
  isAdmin(userId: string): Promise<boolean>;
  getUser(id: string): Promise<CoreUser | null>;
  createUser(attrs: {
    email: string;
    password: string;
    email_confirm: boolean;
    user_metadata: Meta;
    app_metadata: Meta;
  }): Promise<{ id: string } | null>;
  updateUser(id: string, attrs: { app_metadata: Meta; password?: string }): Promise<boolean>;
  deleteUser(id: string): Promise<void>;
  signIn(email: string, password: string): Promise<Tokens | null>;
  signOutAll(accessToken: string): Promise<boolean>;
  audit(actor: string, action: string, target: string, details?: AuditDetails): Promise<boolean>;
}

export const fail = (error: string) => ({ ok: false as const, error });

export const LOGIN_ERROR = "Nesprávne údaje, alebo účet ešte nemá dokončené prvé prihlásenie.";
export const PIN_ERROR = "Neplatný alebo expirovaný PIN. Požiadajte správcu o nový.";

async function findOrganization(port: AccountsPort, orgCode: string): Promise<string | null> {
  const range = orgPrefixRange(orgCode);
  if (!range) return null;
  const ids = await port.organizationsInRange(range.lo, range.hi);
  return ids.length === 1 ? (ids[0] ?? null) : null;
}

async function findAccount(port: AccountsPort, org: string, number: string) {
  const id = await port.profileId(org, number);
  return id ? port.getUser(id) : null;
}

/** Zapíše zmeny do app_metadata (po zlúčení s doterajšími) a voliteľne nastaví heslo. */
async function patch(port: AccountsPort, user: CoreUser, changes: Meta, password?: string) {
  const ok = await port.updateUser(user.id, {
    app_metadata: { ...user.meta, ...changes },
    ...(password !== undefined ? { password } : {}),
  });
  if (!ok) throw new Error("Účet sa nepodarilo upraviť.");
}

async function issuePin(now: number) {
  const pin = randomCode(PIN_LENGTH);
  const salt = randomSalt();
  const expires = now + PIN_TTL_MS;
  const meta: Meta = {
    onboarding_pending: true,
    pin_hash: await hashSecret(normalizeCode(pin), salt),
    pin_salt: salt,
    pin_expires: expires,
    pin_attempts: 0,
    ...clearPatch("login"),
  };
  return { pin, expires, meta };
}

/** Odhlási účet zo všetkých zariadení (prihlási sa známym heslom a zruší všetky relácie). */
async function revokeSessions(port: AccountsPort, email: string, password: string) {
  try {
    const tokens = await port.signIn(email, password);
    return tokens ? await port.signOutAll(tokens.access_token) : false;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------------------------
// Registrácia organizácie
// ---------------------------------------------------------------------------------------------

export type RegisterInput = { code: string; name: string; number: string; password: string };

/** Nová organizácia a jej prvý správca. Chránené stálym registračným kódom (porovnáva sa odtlačok). */
export async function registerCore(port: AccountsPort, input: RegisterInput, codeHash: string) {
  const supplied = await sha256Hex(normalizeCode(input.code));
  if (!safeEqualHex(supplied, codeHash)) return fail("Neplatný registračný kód.");

  const recovery = randomCode(RECOVERY_LENGTH);
  const salt = randomSalt();
  const created = await port.createUser({
    email: `${input.number}.${crypto.randomUUID()}@accounts.invalid`,
    password: input.password,
    email_confirm: true,
    // Organizáciu a rolu správcu zakladá databázový trigger handle_new_user.
    user_metadata: { organization_name: input.name, sap_id: input.number },
    app_metadata: {
      onboarding_pending: false,
      recovery_hash: await hashSecret(normalizeCode(recovery), salt),
      recovery_salt: salt,
    },
  });
  if (!created)
    return fail("Registráciu sa nepodarilo dokončiť. Skontrolujte údaje a skúste to znova.");

  const org = await port.organizationOfUser(created.id);
  if (!org) {
    await port.deleteUser(created.id);
    return fail("Registráciu sa nepodarilo dokončiť. Skúste to znova.");
  }
  await port.audit(created.id, "organization_registered", org);
  await port.audit(created.id, "organization_terms_accepted", org, { version: 1 });
  return {
    ok: true as const,
    organizationCode: formatCode(orgCodeOf(org)),
    recoveryCode: formatCode(recovery),
  };
}

// ---------------------------------------------------------------------------------------------
// Prihlásenie, prvé prihlásenie s PIN-om, obnova správcu
// ---------------------------------------------------------------------------------------------

export type LoginInput = { orgCode: string; number: string; password: string };

export async function loginCore(port: AccountsPort, input: LoginInput, now: number) {
  const org = await findOrganization(port, input.orgCode);
  const account = org ? await findAccount(port, org, input.number) : null;
  if (!account?.email) return fail(LOGIN_ERROR);

  if (isThrottled(account.meta, "login", LOGIN_LIMIT, LOGIN_WINDOW_MS, now)) {
    return fail("Príliš veľa nesprávnych pokusov. Skúste to znova o 15 minút.");
  }
  if (account.meta["onboarding_pending"]) return fail(LOGIN_ERROR);

  const tokens = await port.signIn(account.email, input.password);
  if (!tokens) {
    await patch(port, account, failurePatch(account.meta, "login", LOGIN_WINDOW_MS, now)).catch(
      () => undefined,
    );
    return fail(LOGIN_ERROR);
  }
  if (hasFailures(account.meta, "login")) {
    await patch(port, account, clearPatch("login")).catch(() => undefined);
  }
  return { ok: true as const, ...tokens };
}

export type EnrollInput = { orgCode: string; number: string; pin: string; password: string };

export async function enrollCore(port: AccountsPort, input: EnrollInput, now: number) {
  const org = await findOrganization(port, input.orgCode);
  const account = org ? await findAccount(port, org, input.number) : null;
  if (!account?.email) return fail(PIN_ERROR);

  const status = pinStatus(account.meta, now);
  if (status === "locked") {
    return fail(
      `PIN je zablokovaný po ${PIN_MAX_ATTEMPTS} chybných pokusoch. Požiadajte správcu o nový.`,
    );
  }
  if (status !== "ready") return fail(PIN_ERROR);

  const given = await hashSecret(normalizeCode(input.pin), String(account.meta["pin_salt"]));
  if (!safeEqualHex(given, String(account.meta["pin_hash"]))) {
    const attempts = Number(account.meta["pin_attempts"]) || 0;
    await patch(port, account, { pin_attempts: attempts + 1 }).catch(() => undefined);
    return fail(PIN_ERROR);
  }

  await patch(
    port,
    account,
    {
      onboarding_pending: false,
      pin_hash: null,
      pin_salt: null,
      pin_expires: null,
      pin_attempts: null,
      ...clearPatch("login"),
    },
    input.password,
  );
  await port.audit(account.id, "employee_enrollment_completed", account.id);
  const tokens = await port.signIn(account.email, input.password);
  return {
    ok: true as const,
    access_token: tokens?.access_token ?? null,
    refresh_token: tokens?.refresh_token ?? null,
  };
}

export type RecoverInput = {
  orgCode: string;
  number: string;
  recoveryCode: string;
  password: string;
};

/** Správca, ktorý stratil heslo a nemá druhého správcu, ho obnoví obnovovacím kódom z registrácie. */
export async function recoverCore(port: AccountsPort, input: RecoverInput, now: number) {
  const generic = "Obnova sa nepodarila. Skontrolujte údaje.";
  const org = await findOrganization(port, input.orgCode);
  const account = org ? await findAccount(port, org, input.number) : null;
  if (!account) return fail(generic);

  if (isThrottled(account.meta, "recovery", RECOVERY_LIMIT, RECOVERY_WINDOW_MS, now)) {
    return fail("Príliš veľa nesprávnych pokusov. Skúste to znova o hodinu.");
  }
  const hash = account.meta["recovery_hash"];
  const salt = account.meta["recovery_salt"];
  if (!(await port.isAdmin(account.id)) || typeof hash !== "string" || typeof salt !== "string") {
    return fail(generic);
  }

  const given = await hashSecret(normalizeCode(input.recoveryCode), salt);
  if (!safeEqualHex(given, hash)) {
    await patch(
      port,
      account,
      failurePatch(account.meta, "recovery", RECOVERY_WINDOW_MS, now),
    ).catch(() => undefined);
    return fail(generic);
  }

  // Obnovovací kód je jednorazový: vydá sa nový.
  const recovery = randomCode(RECOVERY_LENGTH);
  const newSalt = randomSalt();
  await patch(
    port,
    account,
    {
      recovery_hash: await hashSecret(normalizeCode(recovery), newSalt),
      recovery_salt: newSalt,
      onboarding_pending: false,
      ...clearPatch("recovery"),
      ...clearPatch("login"),
    },
    input.password,
  );
  const revoked = account.email ? await revokeSessions(port, account.email, input.password) : false;
  await port.audit(account.id, "admin_recovered", account.id);
  return { ok: true as const, recoveryCode: formatCode(recovery), sessionsRevoked: revoked };
}

// ---------------------------------------------------------------------------------------------
// Správca organizácie vydáva PIN-y
// ---------------------------------------------------------------------------------------------

export type ProvisionRow = {
  number: string;
  status: "created" | "reissued" | "reset" | "exists" | "self" | "failed";
  pin?: string;
  expiresAt?: number;
  warning?: string;
};

export type ProvisionContext = { adminUserId: string; org: string; inviteCode: string };

/**
 * Nové čísla dostanú účet a jednorazový PIN. Účty, ktoré ešte nedokončili prvé prihlásenie, dostanú
 * nový PIN. Účty s dokončenou registráciou sa preskočia, ak správca výslovne nepožiada o obnovu
 * (reset): vtedy sa heslo zruší, odhlásia sa všetky zariadenia a vydá sa nový PIN.
 */
export async function provisionCore(
  port: AccountsPort,
  ctx: ProvisionContext,
  input: { numbers: string[]; reset: boolean },
  now: number,
): Promise<ProvisionRow[]> {
  async function one(number: string): Promise<ProvisionRow> {
    try {
      const existing = await findAccount(port, ctx.org, number);
      const issued = await issuePin(now);
      const warnings: string[] = [];
      let status: ProvisionRow["status"];
      let userId: string;

      if (existing) {
        if (existing.id === ctx.adminUserId) return { number, status: "self" };
        const pending = Boolean(existing.meta["onboarding_pending"]);
        if (!pending && !input.reset) return { number, status: "exists" };
        const temp = randomCode(32);
        await patch(port, existing, issued.meta, temp);
        const revoked = existing.email ? await revokeSessions(port, existing.email, temp) : false;
        if (!revoked) warnings.push("Staré prihlásenia sa nepodarilo zrušiť.");
        status = pending ? "reissued" : "reset";
        userId = existing.id;
      } else {
        const created = await port.createUser({
          email: `${number}.${ctx.org}@accounts.invalid`,
          password: randomCode(32),
          email_confirm: true,
          user_metadata: { invite_code: ctx.inviteCode, sap_id: number },
          app_metadata: issued.meta,
        });
        if (!created) return { number, status: "failed", warning: "Účet sa nepodarilo vytvoriť." };
        status = "created";
        userId = created.id;
      }

      const action = status === "created" ? "employee_provisioned" : "employee_password_reset";
      if (!(await port.audit(ctx.adminUserId, action, userId)))
        warnings.push("Zápis do auditu sa nepodaril.");
      return {
        number,
        status,
        pin: formatCode(issued.pin),
        expiresAt: issued.expires,
        ...(warnings.length > 0 ? { warning: warnings.join(" ") } : {}),
      };
    } catch {
      return { number, status: "failed", warning: "Spracovanie sa nepodarilo." };
    }
  }

  const rows: ProvisionRow[] = [];
  for (const number of input.numbers) rows.push(await one(number));
  return rows;
}
