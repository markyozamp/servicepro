'use client';

// "Install on this computer / phone": puts a Service Call Proof icon on the desktop, taskbar or home screen.
import { useEffect, useState } from 'react';

export default function InstallButton() {
  const [prompt, setPrompt] = useState(null);
  const [installed, setInstalled] = useState(false);
  const [help, setHelp] = useState(false);
  const [dev, setDev] = useState({ ios: false, phone: false });
  useEffect(() => {
    if (window.matchMedia?.('(display-mode: standalone)').matches) setInstalled(true);
    const ua = navigator.userAgent || '';
    setDev({ ios: /iphone|ipad|ipod/i.test(ua), phone: /iphone|ipad|ipod|android/i.test(ua) });
    const h = (e) => { e.preventDefault(); setPrompt(e); };
    window.addEventListener('beforeinstallprompt', h);
    window.addEventListener('appinstalled', () => setInstalled(true));
    return () => window.removeEventListener('beforeinstallprompt', h);
  }, []);
  if (installed) return null;
  const { ios } = dev;
  return (
    <>
      <button data-keep={prompt ? undefined : '1'} onClick={async () => {
        if (prompt) { prompt.prompt(); const r = await prompt.userChoice.catch(() => null); if (r?.outcome === 'accepted') setInstalled(true); setPrompt(null); }
        else setHelp(!help);
      }}>⬇ Install on this {dev.phone ? 'phone' : 'computer'}</button>
      {help && (
        <div className="hdr-help small">
          {ios ? 'On iPhone/iPad: tap the Share button (square with arrow) in Safari, then "Add to Home Screen".'
            : 'In Chrome or Edge: click the install icon at the right end of the address bar (a screen with a down arrow), or the ⋮ menu → "Install Service Call Proof". It then opens from your desktop or taskbar like a program, already signed in.'}
        </div>
      )}
    </>
  );
}
