import { describe, expect, it, vi } from "vitest";
import {
  destinationProblem,
  getDestination,
  getNotice,
  LATE_NOTICE_MISSING_MESSAGE,
  messageProblem,
  setDestination,
  setNotice,
} from "./transfer-destination";
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

  it("správa: prázdna je v poriadku (nepovinná), jeden riadok čistého textu do 300 znakov tiež, ostatné nie", () => {
    expect(messageProblem("")).toBeNull();
    expect(messageProblem("   ")).toBeNull();
    expect(messageProblem("Testovanie sa po upozornení SOC ukončilo.")).toBeNull();
    expect(messageProblem("a".repeat(300))).toBeNull();
    expect(messageProblem("a".repeat(301))).toMatch(/najviac 300 znakov/);
    expect(messageProblem("dva\nriadky")).not.toBeNull();
    expect(messageProblem("skrytý\u200bznak")).not.toBeNull();
  });

  it("getNotice: server s migráciou 0020 vracia správu, server len s 0019 nie (supportsMessage)", async () => {
    const withMessage = vi.fn().mockResolvedValue({
      data: { transfer_id: "t", url: "https://novy.example.test", message: "Ahoj" },
      error: null,
    });
    expect(await getNotice({ rpc: withMessage } as TransferClient)).toEqual({
      url: "https://novy.example.test",
      message: "Ahoj",
      supportsMessage: true,
    });
    const emptyMessage = vi
      .fn()
      .mockResolvedValue({ data: { transfer_id: null, url: null, message: null }, error: null });
    expect(await getNotice({ rpc: emptyMessage } as TransferClient)).toEqual({
      url: null,
      message: null,
      supportsMessage: true,
    });
    const old = vi.fn().mockResolvedValue({
      data: { transfer_id: "t", url: "https://novy.example.test" },
      error: null,
    });
    expect(await getNotice({ rpc: old } as TransferClient)).toEqual({
      url: "https://novy.example.test",
      message: null,
      supportsMessage: false,
    });
  });

  it("setNotice pošle adresu aj správu orezané, neopakuje sa po chybe spojenia a vráti uložené", async () => {
    const rpc = vi.fn().mockResolvedValue({
      data: { transfer_id: "t", url: "https://novy.example.test", message: "Ahoj" },
      error: null,
    });
    expect(
      await setNotice({ rpc } as TransferClient, " https://novy.example.test ", "  Ahoj  "),
    ).toEqual({ url: "https://novy.example.test", message: "Ahoj", supportsMessage: true });
    expect(rpc).toHaveBeenLastCalledWith("org_transfer_set_notice", {
      _url: "https://novy.example.test",
      _message: "Ahoj",
    });
    const fail = vi
      .fn()
      .mockResolvedValue({ data: null, error: { message: "TypeError: Failed to fetch" } });
    await expect(setNotice({ rpc: fail } as TransferClient, "", "Ahoj")).rejects.toMatchObject({
      kind: "transport",
    });
    expect(fail).toHaveBeenCalledTimes(1);
  });

  it("setNotice bez migrácie 0020 má vlastný text s názvom migrácie", async () => {
    const rpc = vi
      .fn()
      .mockResolvedValue({ data: null, error: { code: "PGRST202", message: "x" } });
    await expect(setNotice({ rpc } as TransferClient, "", "Ahoj")).rejects.toThrow(
      LATE_NOTICE_MISSING_MESSAGE,
    );
    expect(LATE_NOTICE_MISSING_MESSAGE).toContain("0020");
  });

  it("odpoveď servera v neočakávanom tvare je chyba, nie prázdna adresa", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: { url: 5 }, error: null });
    await expect(getNotice({ rpc } as TransferClient)).rejects.toThrow(/neočakávanú odpoveď/);
  });
});
