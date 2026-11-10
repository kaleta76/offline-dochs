import { useState } from "react";
import { labelOf } from "@/lib/month";
import type { QueuedPunch } from "@/lib/offline-queue";

interface Props {
  /** Najstaršie razenie, ktoré databáza odmietla; ostáva v zariadení, kým sa nevyrieši. */
  punch: QueuedPunch;
  /** Jeden pokus o odoslanie (rovnaké ako „Odoslať teraz“). */
  onRetry: () => void;
  /** Potvrdené odstránenie razenia zo zariadenia; následne sa odošlú ostatné razenia. */
  onDiscard: (uuid: string) => void;
}

/**
 * Upozornenie na razenie, ktoré server natrvalo neprijal (napríklad uzavretý mesiac). Ďalšie razenia čakajú za ním,
 * preto treba ukázať dôvod a dať používateľovi výslovnú, potvrdenú cestu: skúsiť znova alebo zahodiť v zariadení.
 * Nič sa nezahadzuje automaticky.
 */
export function RejectedPunchNotice({ punch, onRetry, onDiscard }: Props) {
  const [confirming, setConfirming] = useState(false);
  const when = new Date(punch.client_time).toLocaleString("sk-SK");
  const what = labelOf(punch.code, punch.direction);

  return (
    <section
      role="alert"
      className="no-print border-b-2 border-destructive bg-card px-4 py-3 text-sm"
      aria-label="Razenie nebolo prijaté"
    >
      <div className="mx-auto flex max-w-6xl flex-col gap-2">
        <p className="font-bold text-destructive">Razenie nebolo prijaté serverom</p>
        <p>
          {what} <span className="num">{when}</span>
          {punch.error ? <span className="text-muted-foreground"> · {punch.error}</span> : null}
        </p>
        <p className="text-xs text-muted-foreground">
          Razenie ostáva uložené v zariadení a ďalšie razenia sa neodošlú, kým sa toto nevyrieši. Opakovať ho
          automaticky nemá zmysel, preto sa nepokúša samo. Ak ide o uzavretý mesiac, obráťte sa na správcu alebo
          personálne oddelenie.
        </p>
        {!confirming ? (
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              onClick={onRetry}
              className="rounded-sm border-2 border-foreground px-3 py-1 text-xs font-semibold uppercase tracking-wider hover:bg-accent"
            >
              Skúsiť znova
            </button>
            <button
              type="button"
              onClick={() => setConfirming(true)}
              className="rounded-sm border-2 border-destructive px-3 py-1 text-xs font-semibold uppercase tracking-wider text-destructive hover:bg-destructive hover:text-destructive-foreground"
            >
              Zahodiť v zariadení
            </button>
          </div>
        ) : (
          <div className="flex flex-col gap-2 rounded-sm border-2 border-destructive p-3">
            <p className="font-semibold">
              Naozaj zahodiť toto razenie: {what}, {when}?
            </p>
            <p className="text-xs text-muted-foreground">
              Server ho neprijal, takže sa nedá vrátiť. Čas a druh si poznačte a oznámte ich personálnemu oddeleniu.
            </p>
            <div className="flex flex-wrap gap-2">
              <button
                type="button"
                onClick={() => {
                  setConfirming(false);
                  onDiscard(punch.client_uuid);
                }}
                className="rounded-sm bg-destructive px-3 py-1 text-xs font-semibold uppercase tracking-wider text-destructive-foreground"
              >
                Áno, zahodiť
              </button>
              <button
                type="button"
                onClick={() => setConfirming(false)}
                className="rounded-sm border-2 border-foreground px-3 py-1 text-xs font-semibold uppercase tracking-wider hover:bg-accent"
              >
                Nie, ponechať
              </button>
            </div>
          </div>
        )}
      </div>
    </section>
  );
}
