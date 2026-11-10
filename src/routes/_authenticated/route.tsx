import { createFileRoute, redirect } from "@tanstack/react-router";
import { supabase } from "@/integrations/supabase/client";
import { AppShell } from "@/components/AppShell";
import { guardDecision } from "@/lib/auth-guard";
import {
  isIdleExpired,
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
    if (s && isIdleExpired(readLastActivity(), Date.now(), signedInAtOf(s), readIdleLimitMs())) {
      await signOutForInactivity(s.user.id);
      throw redirect({ to: "/auth" });
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
