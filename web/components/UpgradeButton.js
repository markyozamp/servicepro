'use client';

// Contractor menu: "Upgrade" shows the Base / Pro / Enterprise plans (payment coming soon).
import { useState } from 'react';
import { createPortal } from 'react-dom';

const PLANS = [
  ['Time Verify', 'Free', 'What you have now: calls from your stores, I\'m going / I\'m here / Leaving, check-in codes, parts runs, invoices against the PO.'],
  ['Base', 'Coming soon', 'Run your whole service business: dispatch board, scheduling, work orders and POs, quotes, preventive maintenance, agreements, technician app with the live cost meter, invoicing.'],
  ['Pro', 'Coming soon', 'Everything in Base plus full estimating, install handoff from sales to the crew, and job costing (labor, parts and profit per job).'],
  ['Enterprise', 'Contact us', 'For larger contractors: CRM and agreement renewals, multiple branches, and moving your data over from other software.'],
];

export default function UpgradeButton() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button onClick={() => setOpen(true)}>⬆ Upgrade</button>
      {open && createPortal(
        <>
          <div className="scrim" onClick={() => setOpen(false)} />
          <aside className="drawer" role="dialog" aria-label="Upgrade your plan" style={{ width: 'min(520px, 100vw)', color: 'var(--ink)' }}>
            <div className="drawer-head spread"><h2 style={{ margin: 0 }}>Upgrade your plan</h2><button onClick={() => setOpen(false)}>Close</button></div>
            <div className="drawer-body">
              <div className="small muted">Priced per technician per month. Paying in the app is coming soon; for now, contact support@servicecallproof.com.</div>
              {PLANS.map(([name, tag, text]) => (
                <div key={name} className="panel panel-pad stack" style={{ gap: 6 }}>
                  <div className="spread"><strong style={{ fontSize: 16 }}>{name}</strong><span className={tag === 'Free' ? 'chip tone-green' : 'soon'}>{tag}</span></div>
                  <div className="small">{text}</div>
                  {tag !== 'Free' && <div><button disabled>Choose {name}</button></div>}
                </div>
              ))}
            </div>
          </aside>
        </>,
        document.body
      )}
    </>
  );
}
