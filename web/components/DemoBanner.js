'use client';

// Shown on every screen while signed in to a demo account: says it's the demo, counts down to the next refresh
// (the demo goes back to its starting point every 10 minutes), and gives an obvious way back to the demo menu.
import { useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import { signOutLocal } from '@/lib/useProfile';

export async function backToDemo() {
  await signOutLocal();
  window.location.replace('/demo');
}

const SETTLE_MS = 20000;   // give the refresh 20 seconds to finish before reloading
const FLAG = 'scp_demo_refreshed';

function useDemoClock() {
  const [left, setLeft] = useState(null);
  useEffect(() => {
    let offset = 0; let next = null; let timer; let alive = true;
    (async () => {
      const { data } = await supabase.rpc('demo_clock');
      if (!alive || !data?.active) return;
      offset = new Date(data.now).getTime() - Date.now();
      next = new Date(data.next).getTime();
      const tick = () => {
        const ms = next - (Date.now() + offset);
        if (ms <= -SETTLE_MS) {
          try { sessionStorage.setItem(FLAG, String(Date.now())); } catch { /* fine */ }
          window.location.reload();
          return;
        }
        setLeft(ms);
      };
      tick();
      timer = setInterval(tick, 1000);
    })().catch(() => {});
    return () => { alive = false; clearInterval(timer); };
  }, []);
  return left;
}

function useJustRefreshed() {
  const [show, setShow] = useState(false);
  useEffect(() => {
    let at = 0;
    try { at = Number(sessionStorage.getItem(FLAG) || 0); sessionStorage.removeItem(FLAG); } catch { /* fine */ }
    if (at && Date.now() - at < 60000) { setShow(true); const t = setTimeout(() => setShow(false), 9000); return () => clearTimeout(t); }
    return undefined;
  }, []);
  return [show, setShow];
}

const mmss = (ms) => { const s = Math.max(0, Math.ceil(ms / 1000)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };

export default function DemoBanner({ who, compact }) {
  const left = useDemoClock();
  const [fresh, setFresh] = useJustRefreshed();
  const soon = left != null && left <= 60000;
  const now = left != null && left <= 0;
  const clock = left == null ? null : now ? <strong>Refreshing the demo now…</strong>
    : <>Demo refreshes in <strong className="demo-count">{mmss(left)}</strong>{soon ? '. Everything goes back to the start.' : ''}</>;
  return (
    <>
      {fresh && (
        <div className="demo-fresh" role="status">
          <span><strong>The demo was just refreshed.</strong> Everything's back to the start, so you can try it all again.</span>
          <button type="button" onClick={() => setFresh(false)} aria-label="Close">✕</button>
        </div>
      )}
      <div className={`demo-banner${soon ? ' soon' : ''}`} role="note">
        {compact ? <span>Demo{clock ? <> · {clock}</> : null}</span>
          : <span>You're exploring the <strong>demo</strong>{who ? <> as <strong>{who}</strong></> : null}. Click around freely.{clock ? <> {clock}</> : ' It resets every night.'}</span>}
        <button type="button" onClick={backToDemo}>← Back to demo menu</button>
      </div>
    </>
  );
}
