import { describe, expect, it } from 'vitest';
import { organizationSignupMetadata } from './organization-registration';

describe('organization registration', () => {
  it('registers a company without selecting any existing organization or global role', () => {
    expect(organizationSignupMetadata({ kind: 'organization', name: ' Firma A ', role: 'admin', organization_id: 'other' })).toEqual({ organization_name: 'Firma A' });
  });
  it('requires a private invitation to join an existing company', () => {
    expect(() => organizationSignupMetadata({ kind: 'employee', invite: '' })).toThrow();
    expect(organizationSignupMetadata({ kind: 'employee', invite: 'a'.repeat(48), number: '00123456' })).toEqual({ invite_code: 'a'.repeat(48), sap_id: '00123456' });
  });
});