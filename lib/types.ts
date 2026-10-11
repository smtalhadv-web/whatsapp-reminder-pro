export type Contact = { id:string; name:string; phone:string; email?:string; tags:string[]; consent:boolean; consentRecordedAt?:string; consentSource?:string; optedOut:boolean; optedOutAt?:string; notes:string; createdAt:string };
export type Reminder = { id:string; title:string; category:string; contactId:string; phone:string; message:string; dueAt:string; timezone:string; recurrence:string; status:'scheduled'|'paused'|'cancelled'|'sent'|'failed'|'manual'; mode:'manual'|'cloud'; templateId?:string; templateValues?:Record<string,string>; createdAt:string };
export type Template = { id:string; name:string; category:string; body:string; approved:boolean };
export type MessageLog = { id:string; reminderId:string; to:string; status:string; mode:string; message:string; at:string };
