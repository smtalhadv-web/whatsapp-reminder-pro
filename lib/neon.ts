import { createClient, SupabaseAuthAdapter } from '@neondatabase/neon-js';

let client: ReturnType<typeof createClient> | null = null;

export const hasNeon = Boolean(
  process.env.NEXT_PUBLIC_NEON_AUTH_URL &&
  process.env.NEXT_PUBLIC_NEON_DATA_API_URL,
);

/**
 * Neon client with the Supabase-compatible Auth adapter. Database requests go
 * through Neon Data API and are protected by PostgreSQL grants and RLS.
 * These public URLs are endpoints, not database credentials.
 */
export function getNeon() {
  if (!hasNeon) return null;
  if (!client) {
    client = createClient({
      auth: {
        url: process.env.NEXT_PUBLIC_NEON_AUTH_URL!,
        adapter: SupabaseAuthAdapter(),
      },
      dataApi: { url: process.env.NEXT_PUBLIC_NEON_DATA_API_URL! },
    });
  }
  return client;
}
