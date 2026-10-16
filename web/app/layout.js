import './globals.css';

export const metadata = {
  title: 'ServicePro',
  description: 'Service calls with proof: photos, GPS, and no surprise invoices.',
};

export const viewport = { width: 'device-width', initialScale: 1 };

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
