import { z } from "zod";
import { KNOWN_ICONS, MAX_BUTTONS, MAX_LABEL } from "./access-config";

export type TerminalIcon = (typeof KNOWN_ICONS)[number] | "in" | "out";
export interface TerminalAction {
  code: string;
  dir: "IN" | "OUT";
  label: string;
  icon: TerminalIcon;
}

const WORK_ACTIONS: TerminalAction[] = [
  { code: "WORK", dir: "IN", label: "Príchod", icon: "in" },
  { code: "WORK", dir: "OUT", label: "Odchod", icon: "out" },
];
export const DEFAULT_TERMINAL_ACTIONS: TerminalAction[] = [
  ...WORK_ACTIONS,
  { code: "DOCTOR", dir: "OUT", label: "Lekár", icon: "doctor" },
  { code: "FAMILY", dir: "OUT", label: "Sprievod", icon: "family" },
  { code: "TRIP", dir: "OUT", label: "Služobná cesta", icon: "trip" },
  { code: "ERRAND", dir: "OUT", label: "Služobné vzdialenie", icon: "errand" },
  { code: "PRIV", dir: "OUT", label: "Súkromne", icon: "private" },
];

const label = z
  .string()
  .min(1)
  .max(MAX_LABEL)
  .refine((v) => v.trim() === v && !Array.from(v).some((c) => c.charCodeAt(0) < 32));
const requestSchema = z.object({
  code: z
    .string()
    .regex(/^[A-Z][A-Z0-9_]{0,19}$/)
    .refine((v) => v !== "WORK"),
  label,
  interruption: z.number().int().min(2).max(9999),
  needsApproval: z.boolean(),
  fullDayOnly: z.boolean(),
});
const snapshotSchema = z
  .object({
    version: z.string().regex(/^\d{4}\.\d{2}\.\d{2}\.\d{4}$/),
    /** Poradie verzie nastavení v organizácii (migrácia 0022); 0 = staršia cache, ktorá poradie nepozná. */
    ord: z.number().int().min(0).default(0),
    buttons: z
      .array(
        z.object({
          code: z
            .string()
            .regex(/^[A-Z][A-Z0-9_]{0,19}$/)
            .refine((v) => v !== "WORK"),
          label,
          icon: z.enum(KNOWN_ICONS),
          interruption: z.number().int().min(2).max(9999),
          order: z.number().int().min(1).max(99),
          needsApproval: z.boolean().default(false),
        }),
      )
      .max(MAX_BUTTONS),
    /** Prerušenia s terminal_request = true (žiadosti o korekciu/absenciu); staršia cache ich nemá = predvolený zoznam. */
    requests: z.array(requestSchema).default([]),
    /** rules.correction_deadline_day: do ktorého dňa nasledujúceho mesiaca sa smie žiadať o opravu; 0 = bez lehoty. */
    correctionDeadlineDay: z.number().int().min(0).max(31).default(0),
  })
  .superRefine((v, ctx) => {
    for (const field of ["code", "interruption", "label"] as const) {
      const values = v.buttons.map((b) => (field === "label" ? b.label.toLowerCase() : b[field]));
      if (new Set(values).size !== values.length)
        ctx.addIssue({ code: "custom", message: `Duplicate ${field}` });
    }
  });
export type TerminalConfig = z.infer<typeof snapshotSchema>;
const docSchema = z.object({
  rules: z
    .object({ correction_deadline_day: z.number().int().min(0).max(31).optional() })
    .optional(),
  interruptions: z.array(
    z.object({
      code: z.number().int(),
      name: z.string(),
      terminal_button: z.boolean().optional(),
      terminal_label: z.string().optional(),
      terminal_order: z.number().optional(),
      terminal_icon: z.string().optional(),
      terminal_request: z.boolean().optional(),
      needs_approval: z.boolean().optional(),
      full_day_only: z.boolean().optional(),
    }),
  ),
  terminal_code_map: z.array(z.object({ code: z.string(), interruption: z.number().int() })),
});

/** Read only the button projection of an already accepted document; never cache employee plans. */
export function parseTerminalConfig(version: string, doc: unknown, ord = 0): TerminalConfig | null {
  const parsed = docSchema.safeParse(doc);
  if (!parsed.success) return null;
  const buttons = [];
  for (const it of parsed.data.interruptions) {
    if (it.terminal_button !== true) continue;
    const codes = parsed.data.terminal_code_map.filter((m) => m.interruption === it.code);
    const mapping = codes[0];
    if (codes.length !== 1 || !mapping || it.full_day_only) return null;
    const icon = KNOWN_ICONS.find((icon) => icon === it.terminal_icon) ?? "other";
    buttons.push({
      code: mapping.code,
      label: it.terminal_label ?? it.name,
      icon,
      interruption: it.code,
      order: it.terminal_order ?? 99,
      needsApproval: it.needs_approval === true,
    });
  }
  // Žiadosti z terminálu (kontrakt 1.4.0): prerušenie s terminal_request = true a práve jedným kódom v mape.
  // Nejednoznačné mapovanie žiadosti preskočíme (na rozdiel od tlačidla nemení razenie, len ponuku v dialógu).
  const requests = [];
  for (const it of parsed.data.interruptions) {
    if (it.terminal_request !== true || it.code === 1) continue;
    const codes = parsed.data.terminal_code_map.filter((m) => m.interruption === it.code);
    const mapping = codes[0];
    if (codes.length !== 1 || !mapping) continue;
    requests.push({
      code: mapping.code,
      label: it.name,
      interruption: it.code,
      needsApproval: it.needs_approval === true,
      fullDayOnly: it.full_day_only === true,
    });
  }
  const result = snapshotSchema.safeParse({
    version,
    ord,
    buttons,
    requests,
    correctionDeadlineDay: parsed.data.rules?.correction_deadline_day ?? 0,
  });
  return result.success ? result.data : null;
}

export function terminalActions(config: TerminalConfig | null): TerminalAction[] {
  if (!config?.buttons.length) return DEFAULT_TERMINAL_ACTIONS;
  return [
    ...WORK_ACTIONS,
    ...[...config.buttons]
      .sort((a, b) => a.order - b.order || a.interruption - b.interruption)
      .map((b) => ({ code: b.code, dir: "OUT" as const, label: b.label, icon: b.icon })),
  ];
}

export interface CorrectionType {
  code: string;
  dir: "IN" | "OUT";
  label: string;
  needsApproval: boolean;
  fullDayOnly: boolean;
}
/** Predvolená ponuka žiadosti o korekciu, keď konfigurácia z Accessu chýba (doterajšie správanie). */
export const DEFAULT_CORRECTION_TYPES: CorrectionType[] = [
  { code: "WORK", dir: "IN", label: "Príchod", needsApproval: false, fullDayOnly: false },
  { code: "WORK", dir: "OUT", label: "Odchod", needsApproval: false, fullDayOnly: false },
  { code: "DOCTOR", dir: "OUT", label: "Lekár", needsApproval: false, fullDayOnly: false },
  { code: "FAMILY", dir: "OUT", label: "Sprievod", needsApproval: false, fullDayOnly: false },
  { code: "TRIP", dir: "OUT", label: "Služobná cesta", needsApproval: false, fullDayOnly: false },
  { code: "PRIV", dir: "OUT", label: "Súkromne", needsApproval: false, fullDayOnly: false },
  { code: "LEAVE", dir: "OUT", label: "Dovolenka", needsApproval: false, fullDayOnly: false },
  { code: "SICK", dir: "OUT", label: "PN", needsApproval: false, fullDayOnly: false },
];

/** Typy v dialógu: príchod/odchod + zjednotené tlačidlové a žiadané prerušenia z Accessu. */
export function correctionTypes(config: TerminalConfig | null): CorrectionType[] {
  if (!config) return DEFAULT_CORRECTION_TYPES;
  const interruptions = new Map<string, TerminalConfig["requests"][number]>(
    config.buttons.map((b) => [b.code, { ...b, fullDayOnly: false }]),
  );
  for (const request of config.requests) interruptions.set(request.code, request);
  return [
    ...DEFAULT_CORRECTION_TYPES.slice(0, 2),
    ...[...interruptions.values()]
      .sort((a, b) => a.interruption - b.interruption)
      .map((r) => ({
        code: r.code,
        dir: "OUT" as const,
        label: r.label,
        needsApproval: r.needsApproval,
        fullDayOnly: r.fullDayOnly,
      })),
  ];
}

/**
 * Lehota na korekciu (rules.correction_deadline_day): za predchádzajúci mesiac sa smie žiadať
 * najneskôr do tohto dňa nasledujúceho mesiaca; 0 = bez lehoty. Staršie mesiace nikdy.
 */
export function correctionDeadlineOk(at: Date, now: Date, deadlineDay: number): boolean {
  if (deadlineDay <= 0) return true;
  const atMonth = at.getFullYear() * 12 + at.getMonth();
  const nowMonth = now.getFullYear() * 12 + now.getMonth();
  if (atMonth >= nowMonth) return true;
  if (atMonth === nowMonth - 1) return now.getDate() <= deadlineDay;
  return false;
}

/** Kódy celodenných prerušení na upozornenie; razenie zostáva dostupné. */
export function fullDayCodes(config: TerminalConfig | null): Set<string> {
  return new Set((config?.requests ?? []).filter((r) => r.fullDayOnly).map((r) => r.code));
}
/** Kódy vyžadujúce schválenie; terminál aktuálny stav schválenia nepozná. */
export function needsApprovalCodes(config: TerminalConfig | null): Set<string> {
  return new Set(
    [...(config?.buttons ?? []), ...(config?.requests ?? [])]
      .filter((r) => r.needsApproval)
      .map((r) => r.code),
  );
}

export function terminalCacheKey(userId: string, organizationId: string): string {
  return `terminal-buttons:${userId}:${organizationId}`;
}
export function readTerminalCache(
  storage: Pick<Storage, "getItem">,
  key: string,
): TerminalConfig | null {
  try {
    const parsed = snapshotSchema.safeParse(JSON.parse(storage.getItem(key) ?? "null"));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}
/**
 * Novšia z dvoch projekcií. Od migrácie 0022 rozhoduje poradie verzie nastavení (`ord`): verzia platná pre aktuálny mesiac má
 * v čase vždy rovnaké alebo vyššie poradie, takže staršia odpoveď nikdy neprepíše novšiu. Odpoveď servera s poradím má prednosť
 * pred staršou cache bez poradia; dve projekcie bez poradia sa porovnajú podľa verzie ako doteraz.
 */
export function newestTerminalConfig(
  current: TerminalConfig | null,
  next: TerminalConfig,
): TerminalConfig {
  if (!current) return next;
  if (next.ord > 0) return current.ord > next.ord ? current : next;
  return current.version > next.version ? current : next;
}
