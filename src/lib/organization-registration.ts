import { z } from 'zod';
import { personnelNumberSchema } from './personnel';

export const organizationSignupSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('organization'), name: z.string().trim().min(2).max(160) }),
  z.object({ kind: z.literal('employee'), invite: z.string().trim().regex(/^[a-f0-9]{48}$/, 'Zadajte platný pozývací kód od správcu.'), number: personnelNumberSchema }),
]);

export function organizationSignupMetadata(input: unknown) {
  const value = organizationSignupSchema.parse(input);
  return value.kind === 'organization'
    ? { organization_name: value.name }
    : { invite_code: value.invite, sap_id: value.number };
}