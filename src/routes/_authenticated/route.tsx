import { createFileRoute, redirect } from "@tanstack/react-router";
import { supabase } from "@/integrations/supabase/client";
import { AppShell } from "@/components/AppShell";
import { guardDecision } from "@/lib/auth-guard";
import {
  decideIdleExpiry,
  isIdleSignOutPending,
  readIdleLimitMs,
  readLastActivity,
  signOutForInactivity,
  signedInAtOf,
} from "@/lib/idle-timeout";

export const Route = createFileRoute("/_authenticated")({
  ssr: false,
  beforeLoad: async () => {
    // Po odhlásení pre nečinnosť ostávajú chránené stránky zatvorené až do nového prihlásenia (aj offline).
    if (isIdleSignOutPending()) throw redirect({ to: "/auth" });
    const local = await supabase.auth.getSession();
    const s = local.data.session;
    // Po vypršaní limitu nečinnosti sa odhlási len vtedy, keď je server dosiahnuteľný (inak by sa zamestnanec nevedel
    // znova prihlásiť): pri výpadku sa odhlásenie odloží (pozri decideIdleExpiry), razenia idú do fronty.
    if (s) {
      const decision = await decideIdleExpiry({
        lastActivity: readLastActivity(),
        now: Date.now(),
        signedInAt: signedInAtOf(s),
        limitMs: readIdleLimitMs(),
      });
      if (decision === "signout") {
        await signOutForInactivity(s.user.id);
        throw redirect({ to: "/auth" });
      }
    }
    // Bez spojenia platí lokálna relácia. Pri zlyhaní spojenia (výpadok, firemný proxy) sa tiež nepresmerúva:
    // na prihlásenie vedie len jasné odmietnutie servera (pozri auth-guard.ts).
    const online = navigator.onLine;
    let user: unknown = null;
    let error: unknown = null;
    if (online || !s) {
      try {
        const res = await supabase.auth.getUser();
        user = res.data.user;
        error = res.error;
      } catch (e) {
        error = e;
      }
    }
    if (guardDecision({ hasSession: !!s, online, user, error }) === "login")
      throw redirect({ to: "/auth" });
  },
  component: AppShell,
});
