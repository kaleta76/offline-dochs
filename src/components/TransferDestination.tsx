import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { supabase } from "@/integrations/supabase/client";
import { TransferError, type TransferClient } from "@/lib/org-transfer";
import { destinationProblem, getDestination, setDestination } from "@/lib/transfer-destination";

// Nepovinná nová adresa aplikácie k rozpracovanému prenosu (migrácia 0019). Terminály, v ktorých ostanú razenia, ju ukážu ľuďom.

const client: TransferClient = {
  rpc: (fn, args) => (supabase as unknown as TransferClient).rpc(fn, args),
};

export function TransferDestination({ transferId }: { transferId: string | null }) {
  const qc = useQueryClient();
  const key = ["org-transfer-destination", transferId];
  const query = useQuery({
    queryKey: key,
    enabled: !!transferId,
    retry: false,
    queryFn: () => getDestination(client),
  });
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);

  useEffect(() => {
    if (query.data !== undefined) setValue(query.data ?? "");
  }, [query.data]);

  // Bez migrácie 0019 sa pole neukáže: prenos funguje ďalej ako predtým.
  if (!transferId || (query.error instanceof TransferError && query.error.kind === "missing"))
    return null;

  const problem = destinationProblem(value);
  const saved = query.data ?? "";

  async function save() {
    setBusy(true);
    setMessage(null);
    try {
      const url = await setDestination(client, value);
      qc.setQueryData(key, url);
      setMessage({ ok: true, text: url ? "Adresa je uložená." : "Adresa je zmazaná." });
    } catch (e) {
      setMessage({ ok: false, text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-1 text-sm">
      <label htmlFor="transfer-destination" className="font-semibold">
        Nová adresa aplikácie (nepovinné)
      </label>
      <p className="text-xs text-muted-foreground">
        Zariadenia, v ktorých ostanú neodoslané razenia, ju ukážu ľuďom počas prenosu aj po
        presťahovaní. Razenia z nich potom dostanete ako šifrovaný súbor a nahráte ho na novom
        serveri (Servis → Neskoré razenia).
      </p>
      <div className="flex flex-wrap gap-2">
        <Input
          id="transfer-destination"
          type="url"
          inputMode="url"
          placeholder="https://"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          className="max-w-md"
        />
        <Button
          type="button"
          variant="outline"
          disabled={busy || !!problem || value.trim() === saved}
          onClick={() => void save()}
        >
          {busy ? "Ukladám…" : "Uložiť adresu"}
        </Button>
      </div>
      {problem && <p className="text-xs text-destructive">{problem}</p>}
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
