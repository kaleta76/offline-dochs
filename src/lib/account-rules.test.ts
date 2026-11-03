import { describe, it, expect } from 'vitest';
import { employeeAuthEmail, enrollmentSchema, canApproveNumber } from './account-rules';
const org = '00000000-0000-4000-8000-000000000001';
describe('employee access rules', () => {
  it('preserves the 7-digit number and leading zeros', () => expect(employeeAuthEmail(org, '0012345')).toBe(`0012345.${org}@accounts.invalid`));
  it('separates identical numbers in different companies', () => expect(employeeAuthEmail(org, '00123456')).not.toBe(employeeAuthEmail('00000000-0000-4000-8000-000000000002', '00123456')));
  it('allows enrollment without email', () => expect(enrollmentSchema.safeParse({organization:org,number:'00123456',password:'password123',pin:'temporary-pin-123',email:''}).success).toBe(true));
  it('requires manager or admin approval in the same company', () => {
    expect(canApproveNumber(false,'manager','manager',true)).toBe(true);
    expect(canApproveNumber(true,null,'admin',false)).toBe(false);
    expect(canApproveNumber(false,'manager','employee',true)).toBe(false);
  });
});