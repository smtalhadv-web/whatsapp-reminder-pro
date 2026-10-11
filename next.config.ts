import type { NextConfig } from 'next';
const nextConfig: NextConfig = {
  poweredByHeader: false,
  // The workspace sandbox blocks Next's child-process TypeScript --showConfig probe.
  // `npm run build` runs `tsc --noEmit` immediately before this production build.
  experimental: { useTypeScriptCli: false },
  typescript: { ignoreBuildErrors: true },
};
export default nextConfig;
