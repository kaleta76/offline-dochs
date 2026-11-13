import { z } from 'zod';
import { personnelNumberSchema } from './personnel';

export const passwordSchema = z.string().min(8).max(128);
// zod 4: `.uuid()` kontroluje verziu a variant; `z.guid()` prijíma každý tvar 8-4-4-4-12 ako zod 3 a Postgres uuid.
export const employeeAccessSchema = z.object({ organization: z.guid(), number: personnelNumberSchema, password: passwordSchema });
export const enrollmentSchema = employeeAccessSchema.extend({ pin: z.string().min(12).max(128), email: z.union([z.literal(''), z.string().email().max(254)]) });
export function employeeAuthEmail(organization: string, number: string) {
  return `${personnelNumberSchema.parse(number)}.${z.guid().parse(organization)}@accounts.invalid`;
}
export function canApproveNumber(admin: boolean, managerId: string | null, actor: string, sameOrganization: boolean) {
  return sameOrganization && (admin || managerId === actor);
}