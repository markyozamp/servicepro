'use client';

// Shown on every screen while signed in to a demo account: says it's the demo and gives an obvious way back.
import { signOutLocal } from '@/lib/useProfile';

export async function backToDemo() {
  await signOutLocal();
  window.location.replace('/demo');
}

export default function DemoBanner({ who }) {
  return (
    <div className="demo-banner" role="note">
      <span>You're exploring the <strong>demo</strong>{who ? <> as <strong>{who}</strong></> : null}. Click around freely; it resets every night.</span>
      <button type="button" onClick={backToDemo}>← Back to demo menu</button>
    </div>
  );
}
