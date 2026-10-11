import type { Metadata, Viewport } from 'next';
import './globals.css';
export const metadata: Metadata = { title: 'WhatsApp Reminder Pro', description: 'Simple, reliable reminders for your business.', manifest: '/manifest.webmanifest', applicationName: 'WhatsApp Reminder Pro', icons: { icon: [{ url: '/icon-192.png', sizes: '192x192', type: 'image/png' }, { url: '/icon-512.png', sizes: '512x512', type: 'image/png' }], apple: '/icon-192.png' } };
export const viewport: Viewport = { themeColor: '#f6f8f7', width: 'device-width', initialScale: 1 };
export default function RootLayout({children}:{children:React.ReactNode}) { return <html lang="en"><body>{children}</body></html>; }
