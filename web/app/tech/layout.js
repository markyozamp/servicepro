export const metadata = {
  title: 'ServicePro Tech',
  manifest: '/manifest.webmanifest',
  appleWebApp: { capable: true, title: 'ServicePro', statusBarStyle: 'black-translucent' },
  icons: { icon: '/icon-192.png', apple: '/icon-192.png' },
};

export const viewport = { width: 'device-width', initialScale: 1, themeColor: '#16202b' };

export default function TechLayout({ children }) {
  return children;
}
