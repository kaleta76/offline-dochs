import { migrateProfileCaches, sanitizeProfileCache } from "./personnel";
import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";

type Role = "employee" | "manager" | "admin";
interface AuthCtx {
  session: Session | null;
  ready: boolean;
  roles: Role[];
  profile: { id: string; sap_id: string | null; department: string | null; daily_fund: number; organization_id: string | null } | null;
  organization: { id: string; name: string } | null;
}
const Ctx = createContext<AuthCtx>({ session: null, ready: false, roles: [], profile: null, organization: null });

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
  const { data } = useQuery({
    queryKey: ["me", uid],
    enabled: !!uid,
    queryFn: async () => {
      if (!uid) throw new Error('Prihlásenie je potrebné.');
      const [r, p] = await Promise.all([
        supabase.from("user_roles").select("role").eq("user_id", uid),
        supabase.from("profiles").select("id, sap_id, department, daily_fund, organization_id").eq("id", uid).maybeSingle(),
      ]);
      if (r.error || p.error) throw r.error ?? p.error;
      const org = await supabase.from('organizations').select('id, name').maybeSingle();
      if (org.error) throw org.error;
      const v = { roles: (r.data ?? []).map((x) => x.role as Role), profile: p.data, organization: org.data };
      localStorage.setItem(`me-cache:${uid}`, JSON.stringify(v));
      return v;
    },
  });
  return (
    <Ctx.Provider value={{ session, ready, roles: data?.roles ?? (cached && cached.profile?.id === uid ? cached.roles : []), profile: data?.profile ?? (cached && cached.profile?.id === uid ? cached.profile : null), organization: data?.organization ?? (cached?.profile?.id === uid ? cached?.organization ?? null : null) }}>
      {children}
    </Ctx.Provider>
  );
}
export const useAuth = () => useContext(Ctx);
