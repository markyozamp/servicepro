export const metadata = {
  title: 'Service Call Proof Tech',
  manifest: '/manifest.webmanifest',
  appleWebApp: { capable: true, title: 'Service Call Proof', statusBarStyle: 'black-translucent' },
  icons: { icon: '/icon-192.png', apple: '/icon-192.png' },
};

export const viewport = { width: 'device-width', initialScale: 1, themeColor: '#16202b' };

export default function TechLayout({ children }) {
  return children;
}
