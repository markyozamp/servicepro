import './globals.css';

export const metadata = {
  title: 'All Service Flow',
  description: 'Service calls with proof: photos, GPS, and no surprise invoices.',
  manifest: '/manifest.webmanifest',
  appleWebApp: { capable: true, title: 'All Service Flow', statusBarStyle: 'black-translucent' },
  icons: { icon: '/icon-192.png', apple: '/icon-192.png' },
};

export const viewport = { width: 'device-width', initialScale: 1, themeColor: '#16202b' };

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
