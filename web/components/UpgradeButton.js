'use client';

// Contractor menu: "Upgrade" shows the plans (Time Verify free → Base → Pro → Enterprise) and the founding-pilot offer.
import { useState } from 'react';
import { createPortal } from 'react-dom';
import PilotOffer from './PilotOffer';

export default function UpgradeButton({ profile, org }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button onClick={() => setOpen(true)}>⬆ Upgrade</button>
      {open && createPortal(
        <>
          <div className="scrim" onClick={() => setOpen(false)} />
          <aside className="drawer" role="dialog" aria-label="Upgrade your plan" style={{ width: 'min(560px, 100vw)', color: 'var(--ink)' }}>
            <div className="drawer-head spread"><h2 style={{ margin: 0 }}>Upgrade your plan</h2><button onClick={() => setOpen(false)}>Close</button></div>
            <div className="drawer-body">
              <PilotOffer source="app" defaults={{ company: org?.name, name: profile?.full_name, email: profile?.email, phone: profile?.phone }} />
            </div>
          </aside>
        </>,
        document.body
      )}
    </>
  );
}
