import { migrateProfileCaches, sanitizeProfileCache } from "./personnel";
import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { loadMe } from "./me-profile";

type Role = "employee" | "manager" | "admin";
interface AuthCtx {
  session: Session | null;
  ready: boolean;
  roles: Role[];
  profile: { id: string; sap_id: string | null; department: string | null; daily_fund: number; organization_id: string | null } | null;
  organization: { id: string; name: string; is_test?: boolean | undefined } | null;
  /** Správa o chybe, ak sa údaje o účte (roly, profil, organizácia) nepodarilo načítať; inak null. */
  meError: string | null;
  refetchMe: () => void;
}
const Ctx = createContext<AuthCtx>({ session: null, ready: false, roles: [], profile: null, organization: null, meError: null, refetchMe: () => undefined });

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    const { data } = supabase.auth.onAuthStateChange((_e, s) => { setSession(s); setReady(true); });
    supabase.auth.getSession().then(({ data }) => { setSession(data.session); setReady(true); });
    return () => data.subscription.unsubscribe();
  }, []);
  const uid = session?.user.id;
  const [cached, setCached] = useState<Pick<AuthCtx, "roles" | "profile" | "organization"> | null>(null);
  useEffect(() => {
    setCached(null);
    try {
      migrateProfileCaches(localStorage);
      if (!uid) return;
      setCached(sanitizeProfileCache(JSON.parse(localStorage.getItem(`me-cache:${uid}`) ?? 'null')));
    } catch { /* unavailable storage */ }
  }, [uid]);
  const { data, error: meFailure, refetch } = useQuery({
    queryKey: ["me", uid],
    enabled: !!uid,
    queryFn: async () => {
      // Jeden POST dopyt (RPC get_my_profile) namiesto štyroch GET so select=; pozri src/lib/me-profile.ts.
      const v = await loadMe(supabase, uid);
      localStorage.setItem(`me-cache:${uid}`, JSON.stringify(v));
      return v;
    },
  });
  return (
    <Ctx.Provider value={{ session, ready, roles: data?.roles ?? (cached && cached.profile?.id === uid ? cached.roles : []), profile: data?.profile ?? (cached && cached.profile?.id === uid ? cached.profile : null), organization: data?.organization ?? (cached?.profile?.id === uid ? cached?.organization ?? null : null), meError: meFailure ? ((meFailure as { message?: string }).message ?? "neznáma chyba") : null, refetchMe: () => { void refetch(); } }}>
      {children}
    </Ctx.Provider>
  );
}
export const useAuth = () => useContext(Ctx);
