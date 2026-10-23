'use client';

// "Install on this phone / computer": puts a Service Call Proof icon on the home screen, desktop or taskbar.
// Android / Chrome / Edge: one tap (the browser's own install prompt).
// iPhone / iPad: Apple doesn't let a website add itself, so we show a clear step-by-step sheet, tuned to the browser
// they're in (Safari, Chrome/Edge/Firefox on iPhone, or an in-app browser from Gmail, Outlook, Facebook, etc.).
import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';

function detect() {
  const ua = navigator.userAgent || '';
  const ipad = /ipad/i.test(ua) || (/macintosh/i.test(ua) && navigator.maxTouchPoints > 1);
  const ios = /iphone|ipod/i.test(ua) || ipad;
  const inApp = /FBAN|FBAV|Instagram|LinkedInApp|Line\/|Snapchat|Twitter|GSA\/|Outlook-iOS|MicrosoftTeams/i.test(ua);
  const otherBrowser = /CriOS|FxiOS|EdgiOS|OPiOS|DuckDuckGo/i.test(ua);
  return { ios, ipad, inApp, otherBrowser, phone: ios || /android/i.test(ua) };
}

const ShareIcon = () => (
  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" style={{ verticalAlign: 'middle' }}>
    <path d="M12 3v12M7.5 7.5 12 3l4.5 4.5" fill="none" stroke="#0a84ff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
    <path d="M8 10H6.5A1.5 1.5 0 0 0 5 11.5v8A1.5 1.5 0 0 0 6.5 21h11a1.5 1.5 0 0 0 1.5-1.5v-8a1.5 1.5 0 0 0-1.5-1.5H16" fill="none" stroke="#0a84ff" strokeWidth="2" strokeLinecap="round" />
  </svg>
);
const AddIcon = () => (
  <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" style={{ verticalAlign: 'middle' }}>
    <rect x="3.5" y="3.5" width="17" height="17" rx="4" fill="none" stroke="#333" strokeWidth="1.8" />
    <path d="M12 8v8M8 12h8" stroke="#333" strokeWidth="1.8" strokeLinecap="round" />
  </svg>
);

function IosSheet({ d, onClose }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => { try { await navigator.clipboard.writeText(window.location.origin); setCopied(true); } catch { /* fine */ } };
  return (
    <>
      <div className="scrim" onClick={onClose} style={{ zIndex: 60 }} />
      <div className="ios-sheet" data-keep="1" role="dialog" aria-label="Add Service Call Proof to your home screen">
        <div className="spread"><strong>Add the app to your home screen</strong><button onClick={onClose} aria-label="Close">✕</button></div>
        <div className="small muted">iPhone doesn't let websites add their own icon, so it takes 3 taps. You only do this once.</div>

        {d.inApp ? (
          <ol className="ios-steps">
            <li><strong>Open this page in Safari first.</strong> You're inside another app's browser (email or social), which can't add icons.
              <div className="small">Tap <strong>•••</strong> or the <strong>Safari compass</strong> at the bottom or top of the screen and choose <strong>Open in Safari</strong>. Or copy the link and paste it into Safari:</div>
              <button className="ios-copy" onClick={copy}>{copied ? '✓ Link copied — paste it in Safari' : 'Copy the link'}</button></li>
            <li>Then tap this <strong>Install</strong> button again in Safari.</li>
          </ol>
        ) : (
          <ol className="ios-steps">
            <li>Tap the <strong>Share</strong> button <ShareIcon />
              <div className="small">{d.otherBrowser
                ? 'It\'s at the top right, in the address bar.'
                : d.ipad ? 'It\'s at the top right of Safari.'
                  : 'It\'s in the bar at the bottom of Safari. On newer iPhones, tap ••• first, then Share.'}</div></li>
            <li>Scroll down the list and tap <strong>Add to Home Screen</strong> <AddIcon />
              <div className="small">Don't see it? Scroll to the bottom and tap <strong>Edit Actions</strong> to turn it on.</div></li>
            <li>Tap <strong>Add</strong> at the top right. The Service Call Proof icon lands on your home screen.</li>
            <li>Open the app from the new icon and <strong>sign in once</strong>. After that it opens straight to your screen.</li>
          </ol>
        )}
        <button className="primary" onClick={onClose}>Got it</button>
      </div>
      {!d.inApp && !d.otherBrowser && !d.ipad && <div className="ios-arrow" aria-hidden="true">⬇</div>}
    </>
  );
}

export default function InstallButton() {
  const [prompt, setPrompt] = useState(null);
  const [installed, setInstalled] = useState(false);
  const [help, setHelp] = useState(false);
  const [d, setD] = useState({ ios: false, phone: false });
  useEffect(() => {
    if (window.matchMedia?.('(display-mode: standalone)').matches || window.navigator.standalone) { setInstalled(true); try { localStorage.setItem('scp_installed', '1'); } catch { /* fine */ } }
    setD(detect());
    const h = (e) => { e.preventDefault(); setPrompt(e); };
    window.addEventListener('beforeinstallprompt', h);
    window.addEventListener('appinstalled', () => { setInstalled(true); try { localStorage.setItem('scp_installed', '1'); } catch { /* fine */ } });
    return () => window.removeEventListener('beforeinstallprompt', h);
  }, []);
  // The tip bubble closes when you click or tap anywhere else, or after 20 seconds.
  useEffect(() => {
    if (!help || d.ios) return undefined;
    const close = (e) => { if (!e.target.closest('.install-wrap')) setHelp(false); };
    const t = setTimeout(() => setHelp(false), 20000);
    document.addEventListener('pointerdown', close, true);
    return () => { clearTimeout(t); document.removeEventListener('pointerdown', close, true); };
  }, [help, d.ios]);
  if (installed) return null;
  return (
    <>
      <button className="install-wrap" data-keep={prompt ? undefined : '1'} onClick={async () => {
        if (prompt) { prompt.prompt(); const r = await prompt.userChoice.catch(() => null); if (r?.outcome === 'accepted') setInstalled(true); setPrompt(null); }
        else setHelp(!help);
      }}>⬇ Install on this {d.phone ? 'phone' : 'computer'}</button>
      {help && d.ios && createPortal(<IosSheet d={d} onClose={() => setHelp(false)} />, document.body)}
      {help && !d.ios && (
        <div className="hdr-help small install-wrap" onClick={() => setHelp(false)} title="Click to close">
          {d.phone
            ? 'In Chrome: tap the ⋮ menu at the top right, then "Install app" or "Add to Home screen".'
            : 'In Chrome or Edge: click the install icon at the right end of the address bar (a screen with a down arrow), or the ⋮ menu → "Install Service Call Proof". It then opens from your desktop or taskbar like a program, already signed in.'}
        </div>
      )}
    </>
  );
}
