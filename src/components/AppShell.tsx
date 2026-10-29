import { Link, Outlet, useNavigate } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { Clock, CalendarDays, Users, Settings, LogOut, Wifi, WifiOff, CloudUpload } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { useQueue } from "@/lib/offline-queue";

export function AppShell() {
  const { roles, profile, session, organization } = useAuth();
  const { items, online } = useQueue(session?.user.id);
  const qc = useQueryClient();
  const navigate = useNavigate();
  const isMgr = roles.includes("manager") || roles.includes("admin");
  const isAdmin = roles.includes("admin");
  const pending = items.length;

  async function signOut() {
    await qc.cancelQueries();
    qc.clear();
    localStorage.removeItem("me-cache");
    if (session?.user.id) localStorage.removeItem(`me-cache:${session.user.id}`);
    await supabase.auth.signOut();
    navigate({ to: "/auth", replace: true });
  }

  const nav = [
    { to: "/terminal", label: "Terminál", icon: Clock, show: true },
    { to: "/mesiac", label: "Môj mesiac", icon: CalendarDays, show: true },
    { to: "/tim", label: "Môj tím", icon: Users, show: isMgr },
    { to: "/admin", label: "Správa", icon: Settings, show: isAdmin },
  ] as const;

  return (
    <div className="min-h-screen bg-background">
      <div
        className={`no-print flex items-center justify-center gap-2 px-4 py-1.5 text-xs font-semibold uppercase tracking-wider ${
          online ? (pending ? "bg-warning text-warning-foreground" : "bg-success text-success-foreground") : "bg-destructive text-destructive-foreground"
        }`}
      >
        {online ? <Wifi className="h-3.5 w-3.5" /> : <WifiOff className="h-3.5 w-3.5" />}
        {online ? "Online" : "Offline – záznamy sa ukladajú v zariadení"}
        {pending > 0 && (
          <span className="flex items-center gap-1">
            <CloudUpload className="h-3.5 w-3.5" /> čaká na odoslanie: {pending}
          </span>
        )}
      </div>
      <header className="no-print border-b-4 border-primary bg-secondary text-secondary-foreground">
        <div className="mx-auto flex max-w-6xl flex-wrap items-center gap-x-6 gap-y-2 px-4 py-3">
          <div className="flex flex-col gap-1">
            <span className="text-lg font-black uppercase tracking-tight">Dochádzka</span>
            <span className="max-w-64 break-words text-xs text-secondary-foreground/60">{organization?.name}</span>
          </div>
          <nav className="flex flex-1 flex-wrap gap-1">
            {nav.filter((n) => n.show).map((n) => (
              <Link
                key={n.to}
                to={n.to}
                className="flex items-center gap-1.5 rounded-sm px-3 py-1.5 text-sm font-semibold text-secondary-foreground/75 hover:bg-sidebar-accent hover:text-secondary-foreground"
                activeProps={{ className: "bg-primary !text-primary-foreground hover:bg-primary" }}
              >
                <n.icon className="h-4 w-4" />
                {n.label}
              </Link>
            ))}
          </nav>
          <div className="flex items-center gap-3 text-sm">
            <span className="hidden text-secondary-foreground/80 sm:inline">{profile?.full_name}</span>
            <button onClick={signOut} className="flex items-center gap-1 text-secondary-foreground/70 hover:text-secondary-foreground" aria-label="Odhlásiť">
              <LogOut className="h-4 w-4" />
            </button>
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-6xl px-4 py-6">
        <Outlet />
      </main>
    </div>
  );
}
