import { describe, expect, it, vi } from "vitest";

vi.mock("@/integrations/supabase/client", () => ({ supabase: {} }));

import { buildProbes } from "./connection-probes";

const ids = (admin?: boolean) =>
  buildProbes("u1", new Date(2026, 10, 11), admin === undefined ? {} : { admin }).map((p) => p.id);

describe("buildProbes", () => {
  it("správca (a predvolene) dostane všetky dopyty vrátane správcovských", () => {
    for (const list of [ids(), ids(true)]) {
      expect(list).toContain("rpc-admin-overview");
      expect(list).toContain("get-invites");
      expect(list).toHaveLength(8);
    }
  });

  it("zamestnanec dostane len dopyty, ktoré smie robiť, a rovnaké tvary ako aplikácia", () => {
    const list = ids(false);
    expect(list).not.toContain("rpc-admin-overview");
    expect(list).not.toContain("get-invites");
    expect(list).toEqual([
      "auth-user",
      "rpc-my-profile",
      "rpc-settings-for-month",
      "get-user-roles",
      "get-profiles",
      "get-punches",
    ]);
  });

  it("dopyty nenesú žiadne pomocné pole navyše (adminOnly)", () => {
    for (const p of buildProbes("u1", new Date(2026, 10, 11), { admin: false })) {
      expect(Object.keys(p).sort()).toEqual(["id", "label", "method", "request", "run"]);
    }
  });
});
