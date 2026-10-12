/**
 * Server-only readiness checks. Never log or return secret values.
 * Do not enable sending merely because the endpoint is reachable.
 */
export type WorkerReadiness = {
  ready: boolean;
  missing: string[];
};

export function getWorkerReadiness(env: NodeJS.ProcessEnv = process.env): WorkerReadiness {
  const required = [
    'REMINDER_WORKER_SECRET',
    'NEON_DATABASE_URL',
    'TOKEN_ENCRYPTION_KEY',
    'META_WEBHOOK_VERIFY_TOKEN',
  ] as const;
  const missing = required.filter(key => !env[key]?.trim());
  return { ready: missing.length === 0, missing };
}
