import { useState, type ReactNode } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import type { VoidTarget } from "@/components/MonthTable";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";

/**
 * Žiadosť o zneplatnenie razenia (napr. duplicitné razenie). Rozhodne vedúci alebo správca (Môj tím).
 * `open(target)` otvorí formulár s dôvodom, `panel` treba vykresliť nad tabuľkou mesiaca.
 * Používa sa v Môj mesiac (zamestnanec) aj vo výkaze zamestnanca (vedúci, správca).
 */
export function useVoidRequest(): { open: (t: VoidTarget) => void; panel: ReactNode } {
  const qc = useQueryClient();
  const [target, setTarget] = useState<VoidTarget | null>(null);
  const [reason, setReason] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const request = useMutation({
    mutationFn: async () => {
      if (!target) throw new Error("Vyberte razenie.");
      const { error } = await supabase.rpc("request_punch_void", {
        _punch_id: target.id,
        _reason: reason.trim(),
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setMsg({
        ok: true,
        text: "Žiadosť o zneplatnenie bola odoslaná vedúcemu. Razenie sa počíta, kým ju neschváli.",
      });
      setTarget(null);
      setReason("");
      qc.invalidateQueries({ queryKey: ["month"] });
    },
    onError: (e: Error) => setMsg({ ok: false, text: e.message }),
  });

  const panel = (
    <div className="no-print">
      {msg && (
        <p role={msg.ok ? "status" : "alert"} className={`mb-3 text-sm ${msg.ok ? "" : "text-destructive"}`}>
          {msg.text}
        </p>
      )}
      {target && (
        <form
          className="mb-4 space-y-2 rounded-sm border-2 border-foreground bg-card p-3"
          onSubmit={(e) => {
            e.preventDefault();
            setMsg(null);
            request.mutate();
          }}
        >
          <p className="text-sm font-bold">
            Zneplatniť razenie: {target.label} {target.time}
          </p>
          <Textarea
            required
            minLength={3}
            maxLength={500}
            placeholder="Dôvod (napr. dvojité razenie, bez osobných údajov)"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
          <div className="flex gap-2">
            <Button type="submit" size="sm" disabled={request.isPending}>
              Odoslať žiadosť
            </Button>
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() => {
                setTarget(null);
                setReason("");
              }}
            >
              Zrušiť
            </Button>
          </div>
        </form>
      )}
    </div>
  );

  return {
    open: (t) => {
      setMsg(null);
      setTarget(t);
    },
    panel,
  };
}
