import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { supabase } from "@/integrations/supabase/client";
import { deleteDeviceKey } from "@/lib/device";
import { cleanupAfterMove, deleteIndexedDb, type CleanupResult } from "@/lib/device-cleanup";
import {
  encryptLateFile,
  fingerprintPunches,
  lateFileName,
  MAX_LATE_PUNCHES,
  toLatePunch,
} from "@/lib/late-punches";
import {
  listAllQueued,
  observeQueue,
  removeQueued,
  useAllQueued,
  type QueuedPunch,
} from "@/lib/offline-queue";
import { MIN_PASSWORD_LENGTH, passwordProblem } from "@/lib/org-transfer-crypto";
import {
  checkMoveNotice,
  forgetMove,
  getMoveSnapshot,
  noteAccepted,
  noteTransferLock,
  subscribeMove,
  type MoveMap,
  type NoticeClient,
} from "@/lib/server-move";

// Oznam o presťahovaní organizácie na iný server (migrácia 0019, docs/PRENOS-ORGANIZACIE.md). Ukazuje sa na každej stránke vrátane
// prihlásenia: po zrušení pôvodnej organizácie sa do nej už nikto neprihlási, ale jej razenia v tomto zariadení ostali.
//   * počas prenosu: razenia sú uložené a odošlú sa samy,
//   * po presťahovaní: razenia sa dajú uložiť do šifrovaného súboru pre správcu nového servera; zmazanie a upratanie zariadenia sa
//     ponúkne až po uložení súboru a po potvrdení. Nič sa nemaže samo.
//   * po zrušení organizácie bez presunu (migrácia 0020): súbor je nepovinný; razenia sa dajú aj zahodiť bez súboru, ale len po
//     zaškrtnutí a druhom potvrdení a len pri zrušenej organizácii (nie pri presťahovaní). Správcova správa sa ukazuje ako čistý text.

/** Záznam o poslednom uloženom súbore (len odtlačok a počet, žiadne razenia ani heslo). */
export const LATE_EXPORT_KEY = "late-export:v1";

export interface ExportRecord {
  fingerprint: string;
  count: number;
  name: string;
}

const EMPTY: MoveMap = {};
const client = supabase as unknown as NoticeClient;
const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

function readExport(): ExportRecord | null {
  try {
    const v = JSON.parse(
      window.localStorage.getItem(LATE_EXPORT_KEY) ?? "null",
    ) as Partial<ExportRecord> | null;
    return v &&
      typeof v.fingerprint === "string" &&
      typeof v.count === "number" &&
      typeof v.name === "string"
      ? { fingerprint: v.fingerprint, count: v.count, name: v.name }
      : null;
  } catch {
    return null;
  }
}

function download(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

const button =
  "rounded-sm border-2 border-foreground px-3 py-1 text-xs font-semibold uppercase tracking-wider hover:bg-accent disabled:opacity-50";
const danger =
  "rounded-sm border-2 border-destructive px-3 py-1 text-xs font-semibold uppercase tracking-wider text-destructive hover:bg-destructive hover:text-destructive-foreground disabled:opacity-50";

/** Správa od správcu (migrácia 0020). Vždy čistý text: React ho neinterpretuje ako HTML a odkaz z neho nevznikne. */
function Notice({ message }: { message: string | null | undefined }) {
  if (!message) return null;
  return (
    <p className="border-l-4 border-primary pl-2">
      Správa od správcu: <strong>{message}</strong>
    </p>
  );
}

function Destination({ url }: { url: string | null }) {
  if (!url) return null;
  return (
    <p>
      Nová adresa aplikácie:{" "}
      <a
        href={url}
        rel="noopener noreferrer"
        className="num font-bold underline underline-offset-4"
      >
        {url}
      </a>
    </p>
  );
}

export interface ServerMoveViewProps {
  /** Razenia účtov, ktorých organizácia bola presťahovaná. */
  moved: QueuedPunch[];
  /** Razenia účtov, ktorých organizácia sa práve prenáša. */
  locked: QueuedPunch[];
  url: string | null;
  /** Posledný uložený súbor, ak obsahuje presne tie razenia, ktoré sú teraz v zariadení; inak null. */
  exported: ExportRecord | null;
  done: CleanupResult | null;
  onExport: (password: string) => Promise<void>;
  onDownloadAgain: (() => void) | null;
  onCleanup: () => Promise<void>;
  onRecheck: () => void;
  /** Razenia účtov, ktorých organizácia bola zrušená bez presunu na iný server (migrácia 0020). Okno „presťahovaný“ má prednosť. */
  ended?: QueuedPunch[];
  /** Správa od správcu k zobrazenému oznamu. */
  message?: string | null;
  /** Zahodenie razení bez uloženia súboru; ponúka sa len pri zrušenej organizácii (nie pri presťahovaní). */
  onDiscard?: () => Promise<void>;
}

export function ServerMoveView(props: ServerMoveViewProps) {
  const { moved, locked, url, exported, done } = props;
  const ended = props.ended ?? [];
  const message = props.message ?? null;
  const isEnded = moved.length === 0 && ended.length > 0;
  const punches = isEnded ? ended : moved;
  const [password, setPassword] = useState("");
  const [password2, setPassword2] = useState("");
  const [busy, setBusy] = useState<"export" | "cleanup" | "discard" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [understood, setUnderstood] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [understoodDiscard, setUnderstoodDiscard] = useState(false);
  const [confirmingDiscard, setConfirmingDiscard] = useState(false);

  if (done) {
    return (
      <section
        role="status"
        aria-label="Zariadenie je upratané"
        className="no-print border-b-2 border-primary bg-card px-4 py-3 text-sm"
      >
        <div className="mx-auto flex max-w-6xl flex-col gap-2">
          <p className="font-bold">
            {done.full ? "Zariadenie je upratané." : "Razenia zo súboru sú zo zariadenia zmazané."}
          </p>
          <p>
            Zmazaných razení: <span className="num">{done.removed}</span>.{" "}
            {done.full
              ? "Zmazané sú aj prihlásenie, kľúč zariadenia, uložené nastavenia a offline kópia aplikácie. Túto stránku môžete zavrieť."
              : `V zariadení ostalo ${done.remaining} razení iných účtov alebo neskorších razení, preto sa ostatné údaje ponechali.`}
          </p>
          {done.problems.length > 0 && (
            <p role="alert" className="text-destructive">
              Nepodarilo sa zmazať: {done.problems.join(", ")}. Dokončíte to vymazaním údajov tejto
              stránky v nastaveniach prehliadača.
            </p>
          )}
          <Notice message={message} />
          <Destination url={url} />
        </div>
      </section>
    );
  }

  if (punches.length === 0) {
    if (locked.length === 0) return null;
    return (
      <section
        role="status"
        aria-label="Organizácia sa prenáša"
        className="no-print border-b-2 border-warning bg-card px-4 py-3 text-sm"
      >
        <div className="mx-auto flex max-w-6xl flex-col gap-1">
          <p className="font-bold">Organizácia sa práve sťahuje na iný server</p>
          <p>
            Server teraz razenia neprijíma. V tomto zariadení čaká{" "}
            <span className="num">{locked.length}</span>{" "}
            {locked.length === 1 ? "razenie" : "razení"}: sú uložené a odošlú sa samy, keď sa prenos
            zruší. Razte ďalej ako zvyčajne, nič sa nestratilo. Ak sa prenos dokončí, zariadenie
            ponúkne uloženie razení do súboru pre nový server.
          </p>
          <Notice message={message} />
          <Destination url={url} />
        </div>
      </section>
    );
  }

  const count = punches.length;
  const accounts = new Set(punches.map((p) => p.user_id)).size;
  const tooMany = count > MAX_LATE_PUNCHES;
  const problem = password ? passwordProblem(password) : null;
  const mismatch = password2 !== "" && password !== password2;
  const canExport = !busy && !tooMany && password !== "" && !problem && password === password2;

  async function run(kind: "export" | "cleanup" | "discard", action: () => Promise<void>) {
    setBusy(kind);
    setError(null);
    try {
      await action();
      if (kind === "export") {
        setPassword("");
        setPassword2("");
      }
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(null);
      setConfirming(false);
      setConfirmingDiscard(false);
    }
  }

  return (
    <section
      role="alert"
      aria-label={isEnded ? "Organizácia bola zrušená" : "Server bol presťahovaný"}
      className="no-print border-b-2 border-destructive bg-card px-4 py-3 text-sm"
    >
      <div className="mx-auto flex max-w-6xl flex-col gap-3">
        <div className="space-y-1">
          <p className="font-bold text-destructive">
            {isEnded ? "Organizácia bola zrušená" : "Server bol presťahovaný"}
          </p>
          <p>
            {isEnded
              ? "Organizácia bola na tomto serveri zrušená a nikam sa nepresťahovala. "
              : "Organizácia bola presťahovaná na iný server. "}
            V tomto zariadení ostalo <strong className="num">{count}</strong>{" "}
            {count === 1 ? "razenie, ktoré" : "razení, ktoré"} sa na pôvodný server už nedajú
            odoslať
            {accounts > 1 ? ` (${accounts} účty alebo viac)` : ""}. Nič sa nezmazalo a nič sa
            nezmaže samo.
          </p>
          <Notice message={message} />
          <Destination url={url} />
        </div>

        <div className="space-y-2 rounded-sm border-2 border-foreground p-3">
          <p className="font-semibold">
            {isEnded
              ? "1. Uložte razenia do šifrovaného súboru (nepovinné)"
              : "1. Uložte razenia do šifrovaného súboru"}
          </p>
          <p className="text-xs text-muted-foreground">
            {isEnded ? (
              <>
                Ak razenia ešte potrebujete (napríklad ak sa organizácia obnoví z exportu), uložte
                ich do súboru. Správca ho vtedy nahrá na serveri, kde organizácia znova existuje
                (Správa → Servis → Neskoré razenia). Heslo mu povedzte inou cestou než súbor.
              </>
            ) : (
              <>
                Súbor odovzdajte správcovi; ten ho nahrá na novom serveri (Správa → Servis → Neskoré
                razenia). Heslo mu povedzte inou cestou než súbor. Razenia budú na novom serveri
                označené ako neoverené a potvrdí ich vedúci. Priamo odoslať na novú adresu sa z
                tohto zariadenia nedajú.
              </>
            )}
          </p>
          {tooMany ? (
            <p role="alert" className="text-destructive">
              V zariadení je viac než {MAX_LATE_PUNCHES} razení, do jedného súboru sa nezmestia.
              Obráťte sa na správcu.
            </p>
          ) : (
            <form
              className="flex flex-wrap items-end gap-2"
              onSubmit={(e) => {
                e.preventDefault();
                if (canExport) void run("export", () => props.onExport(password));
              }}
            >
              <label className="flex flex-col gap-1 text-xs">
                Heslo súboru (aspoň {MIN_PASSWORD_LENGTH} znakov)
                <input
                  type="password"
                  autoComplete="new-password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="rounded-sm border-2 border-input bg-background px-2 py-1 text-sm"
                />
              </label>
              <label className="flex flex-col gap-1 text-xs">
                Heslo znova
                <input
                  type="password"
                  autoComplete="new-password"
                  value={password2}
                  onChange={(e) => setPassword2(e.target.value)}
                  className="rounded-sm border-2 border-input bg-background px-2 py-1 text-sm"
                />
              </label>
              <button type="submit" disabled={!canExport} className={button}>
                {busy === "export" ? "Šifrujem…" : exported ? "Uložiť súbor znova" : "Uložiť súbor"}
              </button>
            </form>
          )}
          {problem && <p className="text-xs text-destructive">{problem}</p>}
          {mismatch && <p className="text-xs text-destructive">Heslá sa nezhodujú.</p>}
          {exported && (
            <p role="status">
              Súbor <strong>{exported.name}</strong> (<span className="num">{exported.count}</span>{" "}
              razení) je uložený v tomto počítači v priečinku so stiahnutými súbormi. Skontrolujte,
              že tam naozaj je.{" "}
              {props.onDownloadAgain && (
                <button
                  type="button"
                  onClick={props.onDownloadAgain}
                  className="font-bold underline underline-offset-4"
                >
                  Stiahnuť znova
                </button>
              )}
            </p>
          )}
        </div>

        <div className="space-y-2 rounded-sm border-2 border-destructive p-3">
          <p className="font-semibold">2. Zmazať razenia a upratať toto zariadenie</p>
          {!exported ? (
            <>
              <p className="text-xs text-muted-foreground">
                {isEnded
                  ? "Zmazanie so súborom sa ponúkne až po uložení súboru (je to jediná kópia a zmazanie sa nedá vrátiť). Ak razenia nepotrebujete, môžete ich zahodiť bez uloženia."
                  : "Zmazanie sa ponúkne až po uložení súboru. Ak razenia preniesť nechcete, súbor si aj tak najprv uložte: je to jediná kópia a zmazanie sa nedá vrátiť."}
              </p>
              {isEnded && props.onDiscard && !confirmingDiscard && (
                <div className="space-y-2 border-t border-border pt-2">
                  <p className="text-xs font-semibold">Alebo razenia zahodiť bez uloženia</p>
                  <label className="flex items-start gap-2 text-xs">
                    <input
                      type="checkbox"
                      checked={understoodDiscard}
                      onChange={(e) => setUnderstoodDiscard(e.target.checked)}
                      className="mt-0.5"
                    />
                    <span>
                      Razenia nepotrebujem. Rozumiem, že <strong className="num">{count}</strong>{" "}
                      razení sa z tohto zariadenia zmaže, nezostane po nich žiadna kópia a nedá sa
                      to vrátiť. Spolu s nimi sa zmaže kľúč zariadenia a uložené údaje účtu; ak v
                      zariadení nič iné neostane, aj prihlásenie a offline kópia aplikácie.
                    </span>
                  </label>
                  <button
                    type="button"
                    disabled={!understoodDiscard || !!busy}
                    onClick={() => setConfirmingDiscard(true)}
                    className={danger}
                  >
                    Zahodiť {count} razení a upratať
                  </button>
                </div>
              )}
              {isEnded && props.onDiscard && confirmingDiscard && (
                <div className="space-y-2">
                  <p className="font-semibold">Naozaj zahodiť {count} razení z tohto zariadenia?</p>
                  <p className="text-xs text-muted-foreground">
                    Nedá sa to vrátiť. Nie je uložená žiadna kópia.
                  </p>
                  <div className="flex flex-wrap gap-2">
                    <button
                      type="button"
                      disabled={!!busy}
                      onClick={() => void run("discard", props.onDiscard!)}
                      className="rounded-sm bg-destructive px-3 py-1 text-xs font-semibold uppercase tracking-wider text-destructive-foreground disabled:opacity-50"
                    >
                      {busy === "discard" ? "Mažem…" : "Áno, zahodiť"}
                    </button>
                    <button
                      type="button"
                      disabled={!!busy}
                      onClick={() => setConfirmingDiscard(false)}
                      className={button}
                    >
                      Nie, ponechať
                    </button>
                  </div>
                </div>
              )}
            </>
          ) : !confirming ? (
            <>
              <label className="flex items-start gap-2 text-xs">
                <input
                  type="checkbox"
                  checked={understood}
                  onChange={(e) => setUnderstood(e.target.checked)}
                  className="mt-0.5"
                />
                <span>
                  Súbor mám uložený a rozumiem, že <strong className="num">{count}</strong> razení
                  sa z tohto zariadenia zmaže. Spolu s nimi sa zmaže kľúč zariadenia a uložené údaje
                  účtu; ak v zariadení nič iné neostane, aj prihlásenie a offline kópia aplikácie.
                </span>
              </label>
              <button
                type="button"
                disabled={!understood || !!busy}
                onClick={() => setConfirming(true)}
                className={danger}
              >
                Zmazať {count} razení a upratať
              </button>
            </>
          ) : (
            <div className="space-y-2">
              <p className="font-semibold">Naozaj zmazať {count} razení z tohto zariadenia?</p>
              <p className="text-xs text-muted-foreground">
                Nedá sa to vrátiť. Razenia ostanú len v súbore {exported.name}.
              </p>
              <div className="flex flex-wrap gap-2">
                <button
                  type="button"
                  disabled={!!busy}
                  onClick={() => void run("cleanup", props.onCleanup)}
                  className="rounded-sm bg-destructive px-3 py-1 text-xs font-semibold uppercase tracking-wider text-destructive-foreground disabled:opacity-50"
                >
                  {busy === "cleanup" ? "Mažem…" : "Áno, zmazať"}
                </button>
                <button
                  type="button"
                  disabled={!!busy}
                  onClick={() => setConfirming(false)}
                  className={button}
                >
                  Nie, ponechať
                </button>
              </div>
            </div>
          )}
        </div>

        {error && (
          <p role="alert" className="text-destructive">
            {error}
          </p>
        )}
        <p className="text-xs text-muted-foreground">
          Ak sa organizácia medzitým vrátila na tento server, prihláste sa a razenia sa odošlú
          bežne.{" "}
          <button type="button" onClick={props.onRecheck} className="underline underline-offset-4">
            Skontrolovať znova
          </button>
        </p>
      </div>
    </section>
  );
}

/** Účty z fronty, ktoré nie sú prihlásené (lokálna relácia, bez dopytu na server). */
async function unsentUsers(items: QueuedPunch[]): Promise<string[]> {
  let uid: string | undefined;
  try {
    uid = (await supabase.auth.getSession()).data.session?.user.id;
  } catch {
    uid = undefined;
  }
  return [...new Set(items.filter((p) => p.user_id !== uid).map((p) => p.user_id))];
}

export function ServerMoveNotice() {
  const items = useAllQueued();
  const move = useSyncExternalStore(subscribeMove, getMoveSnapshot, () => EMPTY);
  const [exportRecord, setExportRecord] = useState<ExportRecord | null>(null);
  const [fingerprint, setFingerprint] = useState<string | null>(null);
  const [done, setDone] = useState<CleanupResult | null>(null);
  const [doneUrl, setDoneUrl] = useState<string | null>(null);
  const [doneMessage, setDoneMessage] = useState<string | null>(null);
  const lastBlob = useRef<{ blob: Blob; name: string; fingerprint: string } | null>(null);

  const moved = useMemo(
    () => items.filter((p) => move[p.user_id]?.state === "moved"),
    [items, move],
  );
  // Organizácia zrušená bez presunu (migrácia 0020): okno „presťahovaný“ má prednosť, zrušená sa ukáže až po jeho vybavení.
  const ended = useMemo(
    () => items.filter((p) => move[p.user_id]?.state === "ended"),
    [items, move],
  );
  const locked = useMemo(
    () => items.filter((p) => move[p.user_id]?.state === "transferring"),
    [items, move],
  );
  const kind: "moved" | "ended" = moved.length > 0 ? "moved" : "ended";
  const active = kind === "moved" ? moved : ended;
  const shown = active[0] ?? locked[0];
  const url = shown ? (move[shown.user_id]?.url ?? null) : null;
  const message = shown ? (move[shown.user_id]?.message ?? null) : null;

  // Udalosti fronty: zámok a prijatie bez dopytu; dopyt na oznam len keď server razenie neprijal alebo účet nie je prihlásený.
  useEffect(
    () =>
      observeQueue((event) => {
        if (event.type === "transfer-lock") noteTransferLock(event.userId);
        else if (event.type === "accepted") noteAccepted(event.userId);
        else if (event.type === "refused") void checkMoveNotice(client, [event.userId]);
        else if (event.type === "unsent") void checkMoveNotice(client, event.userIds);
      }),
    [],
  );

  // Na stránke prihlásenia fronta nebeží, preto sa razenia neprihlásených účtov skontrolujú pri načítaní a pri návrate spojenia.
  useEffect(() => {
    setExportRecord(readExport());
    const check = () =>
      void listAllQueued()
        .then(unsentUsers)
        .then((ids) => checkMoveNotice(client, ids))
        .catch(() => undefined);
    check();
    window.addEventListener("online", check);
    return () => window.removeEventListener("online", check);
  }, []);

  useEffect(() => {
    let cancelled = false;
    if (active.length === 0) setFingerprint(null);
    else
      void fingerprintPunches(active.map(toLatePunch)).then((fp) => {
        if (!cancelled) setFingerprint(fp);
      });
    return () => {
      cancelled = true;
    };
  }, [active]);

  const exported =
    exportRecord && fingerprint && exportRecord.fingerprint === fingerprint ? exportRecord : null;

  async function onExport(password: string) {
    const current = active;
    const { blob, file } = await encryptLateFile(current, password, {
      origin: window.location.origin,
    });
    const name = lateFileName(new Date(), file.punches.length);
    download(blob, name);
    const record: ExportRecord = {
      fingerprint: file.fingerprint,
      count: file.punches.length,
      name,
    };
    lastBlob.current = { blob, name, fingerprint: file.fingerprint };
    try {
      window.localStorage.setItem(LATE_EXPORT_KEY, JSON.stringify(record));
    } catch {
      // bez úložiska platí záznam len do zatvorenia stránky
    }
    setExportRecord(record);
  }

  /** Čerstvé čítanie fronty: berú sa len razenia účtov v rovnakom stave, v akom ich okno ukazuje. */
  async function freshPunches(): Promise<QueuedPunch[]> {
    return (await listAllQueued()).filter((p) => getMoveSnapshot()[p.user_id]?.state === kind);
  }

  async function cleanUp(now: QueuedPunch[]) {
    const userIds = [...new Set(now.map((p) => p.user_id))];
    // Po upratanie sa stav oznamu zabudne, adresa a správa sa preto ukážu z kópie urobenej pred upratovaním.
    const address = url;
    const note = message;
    const result = await cleanupAfterMove(
      { uuids: now.map((p) => p.client_uuid), userIds },
      {
        removeQueued,
        listAllQueued,
        deleteDeviceKey,
        forgetMove,
        sessionUserId: async () => (await supabase.auth.getSession()).data.session?.user.id ?? null,
        signOutLocal: async () => {
          await supabase.auth.signOut({ scope: "local" });
        },
        storage: window.localStorage,
        sessionStorage: window.sessionStorage,
        deleteDatabase: deleteIndexedDb,
        cacheNames: async () => (typeof caches === "undefined" ? [] : caches.keys()),
        deleteCache: (name) => caches.delete(name),
        unregisterWorkers: async () => {
          if (!("serviceWorker" in navigator)) return 0;
          const registrations = await navigator.serviceWorker.getRegistrations();
          await Promise.all(registrations.map((r) => r.unregister()));
          return registrations.length;
        },
      },
    );
    try {
      window.localStorage.removeItem(LATE_EXPORT_KEY);
    } catch {
      // nič na zmazanie
    }
    lastBlob.current = null;
    setExportRecord(null);
    setDoneUrl(address);
    setDoneMessage(note);
    setDone(result);
  }

  async function onCleanup() {
    if (!exported) throw new Error("Najprv uložte razenia do súboru.");
    // Maže sa len vtedy, ak je v zariadení presne to, čo je v súbore.
    const now = await freshPunches();
    if ((await fingerprintPunches(now.map(toLatePunch))) !== exported.fingerprint)
      throw new Error(
        "V zariadení pribudli razenia, ktoré v uloženom súbore nie sú. Uložte súbor znova.",
      );
    await cleanUp(now);
  }

  // Zahodenie bez súboru: len pri zrušenej organizácii a len presne tých razení, ktoré okno ukázalo (počet sa porovná s čerstvým čítaním).
  async function onDiscard() {
    if (kind !== "ended") throw new Error("Razenia sa bez uloženia súboru zahodiť nedajú.");
    const now = await freshPunches();
    if (now.length !== active.length)
      throw new Error("V zariadení sa počet razení zmenil. Skontrolujte ho a skúste znova.");
    await cleanUp(now);
  }

  const again = lastBlob.current;
  return (
    <ServerMoveView
      moved={moved}
      ended={ended}
      locked={locked}
      message={done ? doneMessage : message}
      url={done ? doneUrl : url}
      exported={exported}
      done={done}
      onExport={onExport}
      onDownloadAgain={
        exported && again && again.fingerprint === exported.fingerprint
          ? () => download(again.blob, again.name)
          : null
      }
      onCleanup={onCleanup}
      onDiscard={onDiscard}
      onRecheck={() =>
        void checkMoveNotice(client, [...new Set(active.map((p) => p.user_id))], { force: true })
      }
    />
  );
}
