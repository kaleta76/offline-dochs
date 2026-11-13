import { describe, expect, it, vi } from "vitest";
import { destinationProblem, getDestination, setDestination } from "./transfer-destination";
import type { TransferClient } from "./org-transfer";

describe("nová adresa pri prenose organizácie", () => {
  it("prázdna adresa je v poriadku (nepovinné), platná tiež, ostatné nie", () => {
    expect(destinationProblem("")).toBeNull();
    expect(destinationProblem("  https://novy.example.test/  ")).toBeNull();
    expect(destinationProblem("http://localhost:8080")).toBeNull();
    expect(destinationProblem("novy.example.test")).toMatch(/https:\/\//);
    expect(destinationProblem("https://a:b@novy.example.test")).not.toBeNull();
    expect(destinationProblem("javascript:alert(1)")).not.toBeNull();
  });
  it("čítanie a uloženie volajú správne funkcie a uloženie sa neopakuje", async () => {
    const rpc = vi.fn().mockResolvedValue({
      data: { transfer_id: "t", url: "https://novy.example.test" },
      error: null,
    });
    expect(await getDestination({ rpc } as TransferClient)).toBe("https://novy.example.test");
    expect(rpc).toHaveBeenLastCalledWith("org_transfer_get_destination", {});
    expect(await setDestination({ rpc } as TransferClient, " https://novy.example.test ")).toBe(
      "https://novy.example.test",
    );
    expect(rpc).toHaveBeenLastCalledWith("org_transfer_set_destination", {
      _url: "https://novy.example.test",
    });
    const fail = vi
      .fn()
      .mockResolvedValue({ data: null, error: { message: "TypeError: Failed to fetch" } });
    await expect(
      setDestination({ rpc: fail } as TransferClient, "https://x.example.test"),
    ).rejects.toMatchObject({ kind: "transport" });
    expect(fail).toHaveBeenCalledTimes(1);
  });
  it("chýbajúca migrácia 0019 má vlastný text", async () => {
    const rpc = vi
      .fn()
      .mockResolvedValue({ data: null, error: { code: "PGRST202", message: "x" } });
    await expect(getDestination({ rpc } as TransferClient)).rejects.toThrow(/0019/);
  });
});
