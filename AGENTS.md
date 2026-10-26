<!-- LOVABLE:BEGIN -->
> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.
<!-- LOVABLE:END -->

## Architecture rules
- Attendance math lives only in `src/lib/engine.ts` as a pure function with tests in `engine.test.ts`; UI and exports call it, never reimplement it — keeps payroll results consistent.
- Punches are written to the IndexedDB queue (`src/lib/offline-queue.ts`) first and synced with an idempotent `client_uuid` — offline is a core requirement.
- Server time, drift and SHA-256 hash chain are set by the `punches_chain` DB trigger, never by the client — tamper evidence must not depend on the device.
- Punches are append-only; corrections become new punches only via the `decide_correction` RPC — audit trail stays intact.
