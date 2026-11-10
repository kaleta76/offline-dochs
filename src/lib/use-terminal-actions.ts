import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { pollInterval, useRefetchOnResume, useUserActive } from "./activity-polling";
import {
  newestTerminalConfig,
  parseTerminalConfig,
  readTerminalCache,
  terminalActions,
  terminalCacheKey,
  type TerminalConfig,
} from "./terminal-actions";

/** Ako často sa pri práci s terminálom kontroluje nová konfigurácia tlačidiel (po nečinnosti sa kontrola zastaví, pozri activity-polling.ts). */
const CONFIG_POLL_MS = 60_000;

/** Celá projekcia konfigurácie terminálu (tlačidlá, žiadosti, lehoty) s offline cache podľa účtu a organizácie. */
export function useTerminalConfig(
  userId: string | undefined,
  organizationId: string | null | undefined,
  online: boolean,
): TerminalConfig | null {
  const key = userId && organizationId ? terminalCacheKey(userId, organizationId) : null;
  const [cached, setCached] = useState<{ key: string; config: TerminalConfig | null } | null>(null);
  useEffect(() => {
    try {
      if (key) setCached({ key, config: readTerminalCache(localStorage, key) });
      else setCached(null);
    } catch {
      setCached(null);
    }
  }, [key]);
  const active = useUserActive();
  const query = useQuery({
    queryKey: ["terminal-buttons", userId, organizationId],
    enabled: !!key && online,
    refetchInterval: pollInterval(CONFIG_POLL_MS, online && active),
    queryFn: async () => {
      if (!key || !organizationId) return null;
      const { data, error } = await supabase
        .from("access_config")
        .select("config_version, config")
        .eq("organization_id", organizationId)
        .maybeSingle();
      if (error) throw error;
      if (!data) {
        try {
          localStorage.removeItem(key);
        } catch {
          /* optional cache */
        }
        return null;
      }
      const parsed = parseTerminalConfig(data.config_version, data.config);
      if (!parsed) throw new Error("Neplatná konfigurácia tlačidiel.");
      let previous: TerminalConfig | null = null;
      try {
        previous = readTerminalCache(localStorage, key);
      } catch {
        /* optional cache */
      }
      const config = newestTerminalConfig(previous, parsed);
      try {
        localStorage.setItem(key, JSON.stringify(config));
      } catch {
        /* punching must remain available */
      }
      return config;
    },
  });
  useRefetchOnResume({ active, enabled: !!key && online, updatedAt: query.dataUpdatedAt, baseMs: CONFIG_POLL_MS, refetch: query.refetch });
  // Query data belongs to the full account/organization key; stale cached state never crosses accounts.
  return query.data !== undefined ? query.data : cached?.key === key ? cached.config : null;
}

export function useTerminalActions(
  userId: string | undefined,
  organizationId: string | null | undefined,
  online: boolean,
) {
  return terminalActions(useTerminalConfig(userId, organizationId, online));
}
