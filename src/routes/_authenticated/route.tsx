import { createFileRoute, redirect } from "@tanstack/react-router";
import { supabase } from "@/integrations/supabase/client";
import { AppShell } from "@/components/AppShell";
import {
  isIdleExpired,
  isIdleSignOutPending,
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
    if (s && isIdleExpired(readLastActivity(), Date.now(), signedInAtOf(s))) {
      await signOutForInactivity(s.user.id);
      throw redirect({ to: "/auth" });
    }
    // Offline: trust the locally stored session so the terminal keeps working.
    if (!navigator.onLine && s) return;
    const { data } = await supabase.auth.getUser();
    if (!data.user) throw redirect({ to: "/auth" });
  },
  component: AppShell,
});
