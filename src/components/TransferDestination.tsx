import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { TransferError, type TransferClient } from "@/lib/org-transfer";
import { MAX_MESSAGE_LENGTH } from "@/lib/server-move";
import {
  destinationProblem,
  getNotice,
  messageProblem,
  setDestination,
  setNotice,
} from "@/lib/transfer-destination";

// Nepovinná nová adresa aplikácie a správa pre zariadenia k rozpracovanému prenosu (migrácie 0019 a 0020). Terminály, v ktorých ostanú
// razenia, ich ukážu ľuďom. `onDirtyChange` hlási, že v poliach je text, ktorý nie je uložený (zariadenia ho neuvidia).

const client: TransferClient = {
  rpc: (fn, args) => (supabase as unknown as TransferClient).rpc(fn, args),
};

const normalizeUrl = (v: string) => v.trim().replace(/\/+$/, "");

export function TransferDestination({
  transferId,
  onDirtyChange,
}: {
  transferId: string | null;
  onDirtyChange?: ((dirty: boolean) => void) | undefined;
}) {
  const qc = useQueryClient();
  const key = ["org-transfer-destination", transferId];
  const query = useQuery({
    queryKey: key,
    enabled: !!transferId,
    retry: false,
    queryFn: () => getNotice(client),
  });
  const [value, setValue] = useState("");
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);

  useEffect(() => {
    if (query.data === undefined) return;
    setValue(query.data.url ?? "");
    setText(query.data.message ?? "");
  }, [query.data]);

  const supportsMessage = query.data?.supportsMessage ?? false;
  const urlProblem = destinationProblem(value);
  const textProblem = supportsMessage ? messageProblem(text) : null;
  const savedUrl = normalizeUrl(query.data?.url ?? "");
  const savedText = query.data?.message ?? "";
  const dirty =
    query.data !== undefined &&
    (normalizeUrl(value) !== savedUrl || (supportsMessage && text.trim() !== savedText));

  useEffect(() => {
    onDirtyChange?.(dirty);
  }, [dirty, onDirtyChange]);
  useEffect(() => () => onDirtyChange?.(false), [onDirtyChange]);

  // Bez migrácie 0019 sa pole neukáže: prenos funguje ďalej ako predtým.
  if (!transferId || (query.error instanceof TransferError && query.error.kind === "missing"))
    return null;
  // Kým sa uložené hodnoty nenačítajú, polia sú zamknuté (načítaná hodnota by prepísala to, čo človek medzitým napísal).
  const loading = query.isPending;

  async function save() {
    setBusy(true);
    setMessage(null);
    try {
      if (supportsMessage) {
        const saved = await setNotice(client, value, text);
        qc.setQueryData(key, saved);
        setMessage({
          ok: true,
          text:
            saved.url || saved.message
              ? "Adresa a správa sú uložené."
              : "Adresa a správa sú zmazané.",
        });
      } else {
        const url = await setDestination(client, value);
        qc.setQueryData(key, { url, message: null, supportsMessage: false });
        setMessage({ ok: true, text: url ? "Adresa je uložená." : "Adresa je zmazaná." });
      }
    } catch (e) {
      setMessage({ ok: false, text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-2 text-sm">
      <div className="space-y-1">
        <label htmlFor="transfer-destination" className="font-semibold">
          Nová adresa aplikácie (nepovinné)
        </label>
        <p className="text-xs text-muted-foreground">
          Zariadenia, v ktorých ostanú neodoslané razenia, ju ukážu ľuďom počas prenosu aj po
          presťahovaní. Razenia z nich potom dostanete ako šifrovaný súbor a nahráte ho na novom
          serveri (Servis → Neskoré razenia). Adresa musí byť dostupná z počítačov zamestnancov (pre
          iný počítač nestačí „localhost“).
        </p>
        <Input
          id="transfer-destination"
          type="url"
          inputMode="url"
          placeholder="https://"
          value={value}
          disabled={loading}
          onChange={(e) => setValue(e.target.value)}
          className="max-w-md"
        />
        {urlProblem && <p className="text-xs text-destructive">{urlProblem}</p>}
      </div>

      {supportsMessage && (
        <div className="space-y-1">
          <label htmlFor="transfer-message" className="font-semibold">
            Správa pre zariadenia (nepovinné)
          </label>
          <p className="text-xs text-muted-foreground">
            Ukáže sa v zariadeniach s neodoslanými razeniami, napríklad „Presťahovali sme sa,
            razenia odovzdajte správcovi.“. Jeden riadok, najviac {MAX_MESSAGE_LENGTH} znakov.
            Správu vidí každý, kto má takéto zariadenie, preto nepíšte osobné údaje.
          </p>
          <Input
            id="transfer-message"
            autoComplete="off"
            maxLength={MAX_MESSAGE_LENGTH}
            value={text}
            disabled={loading}
            onChange={(e) => setText(e.target.value)}
            className="max-w-2xl"
          />
          <p className="text-xs text-muted-foreground">
            <span className="num">{[...text].length}</span> / {MAX_MESSAGE_LENGTH}
          </p>
          {textProblem && <p className="text-xs text-destructive">{textProblem}</p>}
        </div>
      )}

      {query.error && (
        <p role="alert" className="text-xs text-destructive">
          Uloženú adresu a správu sa nepodarilo načítať
          {query.error instanceof Error ? `: ${query.error.message}` : "."} Ukladanie je zatiaľ
          vypnuté, aby sa neprepísali; skúste stránku načítať znova.
        </p>
      )}
      <Button
        type="button"
        variant="outline"
        disabled={busy || !!urlProblem || !!textProblem || !dirty}
        onClick={() => void save()}
      >
        {busy ? "Ukladám…" : supportsMessage ? "Uložiť adresu a správu" : "Uložiť adresu"}
      </Button>
      {dirty && !urlProblem && !textProblem && (
        <p role="status" className="text-xs text-muted-foreground">
          Zmeny ešte nie sú uložené.
        </p>
      )}
      {message && (
        <p
          role={message.ok ? "status" : "alert"}
          className={message.ok ? "text-xs" : "text-xs text-destructive"}
        >
          {message.text}
        </p>
      )}
    </div>
  );
}
