import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";

type Role = "employee" | "manager" | "admin";
interface AuthCtx {
  session: Session | null;
  ready: boolean;
  roles: Role[];
  profile: { id: string; full_name: string; department: string | null; daily_fund: number } | null;
}
const Ctx = createContext<AuthCtx>({ session: null, ready: false, roles: [], profile: null });

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    const { data } = supabase.auth.onAuthStateChange((_e, s) => { setSession(s); setReady(true); });
    supabase.auth.getSession().then(({ data }) => { setSession(data.session); setReady(true); });
    return () => data.subscription.unsubscribe();
  }, []);
  const uid = session?.user.id;
  const { data } = useQuery({
    queryKey: ["me", uid],
    enabled: !!uid,
    queryFn: async () => {
      const [r, p] = await Promise.all([
        supabase.from("user_roles").select("role").eq("user_id", uid!),
        supabase.from("profiles").select("id, full_name, department, daily_fund").eq("id", uid!).maybeSingle(),
      ]);
      const v = { roles: (r.data ?? []).map((x) => x.role as Role), profile: p.data };
      localStorage.setItem("me-cache", JSON.stringify(v));
      return v;
    },
    initialData: () => {
      if (typeof window === "undefined") return undefined;
      try { return JSON.parse(localStorage.getItem("me-cache") ?? "null") ?? undefined; } catch { return undefined; }
    },
  });
  return (
    <Ctx.Provider value={{ session, ready, roles: data?.roles ?? [], profile: data?.profile ?? null }}>
      {children}
    </Ctx.Provider>
  );
}
export const useAuth = () => useContext(Ctx);
