export const metadata = {
  title: 'All Service Flow Tech',
  manifest: '/manifest.webmanifest',
  appleWebApp: { capable: true, title: 'All Service Flow', statusBarStyle: 'black-translucent' },
  icons: { icon: '/icon-192.png', apple: '/icon-192.png' },
};

export const viewport = { width: 'device-width', initialScale: 1, themeColor: '#16202b' };

export default function TechLayout({ children }) {
  return children;
}
