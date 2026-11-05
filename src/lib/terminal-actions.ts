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
const snapshotSchema = z
  .object({
    version: z.string().regex(/^\d{4}\.\d{2}\.\d{2}\.\d{4}$/),
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
        }),
      )
      .max(MAX_BUTTONS),
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
  interruptions: z.array(
    z.object({
      code: z.number().int(),
      name: z.string(),
      terminal_button: z.boolean().optional(),
      terminal_label: z.string().optional(),
      terminal_order: z.number().optional(),
      terminal_icon: z.string().optional(),
      full_day_only: z.boolean().optional(),
    }),
  ),
  terminal_code_map: z.array(z.object({ code: z.string(), interruption: z.number().int() })),
});

/** Read only the button projection of an already accepted document; never cache employee plans. */
export function parseTerminalConfig(version: string, doc: unknown): TerminalConfig | null {
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
    });
  }
  const result = snapshotSchema.safeParse({ version, buttons });
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
export function newestTerminalConfig(
  current: TerminalConfig | null,
  next: TerminalConfig,
): TerminalConfig {
  return current && current.version > next.version ? current : next;
}
