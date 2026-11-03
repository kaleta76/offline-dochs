import { z } from 'zod';
import { personnelNumberSchema } from './personnel';

export const passwordSchema = z.string().min(8).max(128);
export const employeeAccessSchema = z.object({ organization: z.string().uuid(), number: personnelNumberSchema, password: passwordSchema });
export const enrollmentSchema = employeeAccessSchema.extend({ pin: z.string().min(12).max(128), email: z.union([z.literal(''), z.string().email().max(254)]) });
export function employeeAuthEmail(organization: string, number: string) {
  return `${personnelNumberSchema.parse(number)}.${z.string().uuid().parse(organization)}@accounts.invalid`;
}
export function canApproveNumber(admin: boolean, managerId: string | null, actor: string, sameOrganization: boolean) {
  return sameOrganization && (admin || managerId === actor);
}