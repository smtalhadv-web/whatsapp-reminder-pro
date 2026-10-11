import type { Contact } from './types';

export function canMessageContact(contact: Pick<Contact, 'consent'|'consentRecordedAt'|'consentSource'|'optedOut'> | null | undefined): boolean {
  return Boolean(contact?.consent && contact.consentRecordedAt && contact.consentSource?.trim() && !contact.optedOut);
}
