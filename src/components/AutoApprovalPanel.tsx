import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { labelOf } from "@/lib/month";
import { personnelLabel } from "@/lib/personnel";
import {
  AUTO_APPROVAL_DAYS,
  AUTO_APPROVAL_PER_DAY,
  autoApprovalRows,
  autoApprovalSince,
  isAutoApprovalUnavailable,
} from "@/lib/auto-approval";
import { AutoApprovalConsent } from "@/components/AutoApprovalConsent";
import { useVoidRequest } from "@/components/VoidRequest";
import { Button } from "@/components/ui/button";

const when = (iso: string) =>
  new Date(iso).toLocaleString("sk-SK", {
    day: "numeric",
    month: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });

/**
 * Automatické schvaľovanie opráv (migrácia 0013). Priamy vedúci zapne pri podriadenom voľbu, ktorá schváli sama opravy
 * podané z jeho overeného zariadenia; správca ju smie len vypnúť. Pod voľbami je kontrolný zoznam automaticky schválených opráv
 * za posledných 14 dní so zneplatnením razenia cez existujúci postup. Bez migrácie v databáze sa karta neukáže.
 */
export function AutoApprovalPanel({ uid, isAdmin }: { uid: string; isAdmin: boolean }) {
  const qc = useQueryClient();
  const [message, setMessage] = useState<string | null>(null);
  // Zamestnanec, pri ktorom vedúci práve potvrdzuje zapnutie (pred zapnutím musí prečítať a odsúhlasiť upozornenie).
  const [confirming, setConfirming] = useState<string | null>(null);
  const voidRequest = useVoidRequest();

  const people = useQuery({
    queryKey: ["auto-approval-people", uid, isAdmin],
    queryFn: async () => {
      let q = supabase
        .from("profiles")
        .select("id, sap_id, department, manager_id")
        .order("sap_id");
      if (!isAdmin) q = q.eq("manager_id", uid);
      const { data, error } = await q;
      if (error) throw error;
      return data ?? [];
    },
  });
  const pairs = useQuery({
    queryKey: ["auto-approval-pairs", uid],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("correction_auto_approvals")
        .select("user_id, manager_id, enabled_at");
      if (error) throw error;
      return data ?? [];
    },
  });
  const recent = useQuery({
    queryKey: ["auto-approved-recent", uid],
    enabled: pairs.isSuccess,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("corrections")
        .select("id, user_id, code, direction, at_time, reason, created_at, punch_id")
        .eq("auto_approved", true)
        .neq("user_id", uid)
        .gte("created_at", autoApprovalSince(new Date()))
        .order("created_at", { ascending: false })
        .limit(100);
      if (error) throw error;
      const rows = data ?? [];
      const punchIds = rows.flatMap((r) => (r.punch_id == null ? [] : [r.punch_id]));
      const { data: punches } = punchIds.length
        ? await supabase.from("punches").select("id, voided_at").in("id", punchIds)
        : { data: [] };
      const voided = new Set((punches ?? []).filter((p) => p.voided_at).map((p) => p.id));
      return rows.map((r) => ({ ...r, voided: r.punch_id != null && voided.has(r.punch_id) }));
    },
  });

  const toggle = useMutation({
    mutationFn: async ({ user, enabled }: { user: string; enabled: boolean }) => {
      const { error } = await supabase.rpc("set_correction_auto_approval", {
        _user: user,
        _enabled: enabled,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      setMessage(null);
      qc.invalidateQueries({ queryKey: ["auto-approval-pairs"] });
    },
    onError: (e: Error) => setMessage(e.message),
  });

  // Databáza bez migrácie 0013: voľba neexistuje, karta sa neukáže (ostatné časti Môj tím fungujú ako doteraz).
  if (pairs.error && isAutoApprovalUnavailable(pairs.error)) return null;
  if (people.isLoading || pairs.isLoading) return null;
  if (pairs.error || people.error) {
    return (
      <section>
        <h2 className="mb-2 text-sm font-bold uppercase tracking-widest">
          Automatické schvaľovanie opráv
        </h2>
        <p className="text-sm text-muted-foreground">Nepodarilo sa načítať (ste offline?).</p>
      </section>
    );
  }

  const peopleById = new Map((people.data ?? []).map((p) => [p.id, p]));
  const rows = autoApprovalRows(uid, isAdmin, people.data ?? [], pairs.data ?? []);
  const nameOf = (id: string) => personnelLabel(peopleById.get(id) ?? { id, sap_id: null });
  const recentRows = recent.data ?? [];

  return (
    <section className="space-y-4">
      <div>
        <h2 className="mb-2 text-sm font-bold uppercase tracking-widest">
          Automatické schvaľovanie opráv
        </h2>
        <p className="mb-3 text-xs text-muted-foreground">
          Zapnuté pri zamestnancovi schváli samo jeho žiadosti o opravu, ktoré podal zo svojho
          overeného zariadenia: príchod, odchod a prerušenia bez príznaku „vyžaduje schválenie“,
          najviac {AUTO_APPROVAL_PER_DAY} za deň a nie staršie ako {AUTO_APPROVAL_DAYS} dní. Všetko
          ostatné (žiadosti z neoverených zariadení, schvaľovanie zariadení, čakajúce žiadosti spred
          zapnutia) schvaľujete ručne. Zapnúť voľbu smie len priamy vedúci, vypnúť ju smie aj
          správca. Pri zmene vedúceho voľba zanikne.
        </p>
        {message && (
          <p role="alert" className="mb-2 text-sm text-destructive">
            {message}
          </p>
        )}
        {rows.length === 0 && (
          <p className="text-sm text-muted-foreground">
            {isAdmin
              ? "Nikto nemá voľbu zapnutú a nemáte priamych podriadených."
              : "Nemáte priradených zamestnancov."}
          </p>
        )}
        <ul className="space-y-2">
          {rows.map((r) => (
            <li
              key={r.person.id}
              className="flex flex-wrap items-center gap-3 rounded-sm border-2 border-foreground bg-card px-3 py-2 text-sm"
            >
              <span className="font-bold">{personnelLabel(r.person)}</span>
              <span className="flex-1 text-muted-foreground">
                {r.enabled
                  ? `zapnuté${r.enabledAt ? ` od ${when(r.enabledAt)}` : ""}${
                      r.enabledBy && r.enabledBy !== uid ? ` · zapol ${nameOf(r.enabledBy)}` : ""
                    }`
                  : "vypnuté"}
              </span>
              {r.canEnable && (
                <Button
                  size="sm"
                  disabled={toggle.isPending}
                  onClick={() => {
                    setMessage(null);
                    setConfirming(r.person.id);
                  }}
                >
                  Zapnúť
                </Button>
              )}
              {r.canDisable && (
                <Button
                  size="sm"
                  variant="outline"
                  disabled={toggle.isPending}
                  onClick={() => toggle.mutate({ user: r.person.id, enabled: false })}
                >
                  Vypnúť
                </Button>
              )}
              {r.canEnable && confirming === r.person.id && (
                <AutoApprovalConsent
                  name={personnelLabel(r.person)}
                  busy={toggle.isPending}
                  onCancel={() => setConfirming(null)}
                  onConfirm={() =>
                    toggle.mutate(
                      { user: r.person.id, enabled: true },
                      { onSuccess: () => setConfirming(null) },
                    )
                  }
                />
              )}
            </li>
          ))}
        </ul>
      </div>

      <div>
        <h3 className="mb-2 text-sm font-bold uppercase tracking-widest">
          Automaticky schválené za posledných {AUTO_APPROVAL_DAYS} dní
        </h3>
        {voidRequest.panel}
        {recent.isError && (
          <p className="text-sm text-muted-foreground">
            Zoznam sa nepodarilo načítať (ste offline?).
          </p>
        )}
        {recent.isSuccess && recentRows.length === 0 && (
          <p className="text-sm text-muted-foreground">
            Za posledné obdobie nič nebolo schválené automaticky.
          </p>
        )}
        <ul className="space-y-2">
          {recentRows.map((c) => (
            <li
              key={c.id}
              className="flex flex-wrap items-center gap-3 rounded-sm border-2 border-foreground bg-card px-3 py-2 text-sm"
            >
              <span className="font-bold">{nameOf(c.user_id)}</span>
              <span>
                {labelOf(c.code, c.direction)} · <span className="num">{when(c.at_time)}</span>
              </span>
              <span className="flex-1 text-muted-foreground">„{c.reason}“</span>
              {c.voided ? (
                <span className="rounded-sm bg-muted px-2 py-1 text-xs font-bold">zneplatnené</span>
              ) : (
                c.punch_id != null && (
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() =>
                      voidRequest.open({
                        id: c.punch_id as number,
                        label: labelOf(c.code, c.direction),
                        time: when(c.at_time),
                      })
                    }
                  >
                    Zneplatniť
                  </Button>
                )
              )}
            </li>
          ))}
        </ul>
        <p className="mt-2 text-xs text-muted-foreground">
          Zneplatnenie ide cez žiadosť o zneplatnenie razenia (vyššie v časti Žiadosti o
          zneplatnenie razenia): odošlete ju a potvrďte tlačidlom Zneplatniť razenie.
        </p>
      </div>
    </section>
  );
}
