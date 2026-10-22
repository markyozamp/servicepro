'use client';

// "Order printed stickers from us": for now it prepares an email to Service Call Proof (ordering in the app comes later).
import { useState } from 'react';

export default function OrderStickers({ sites = [], unitsBySite = {} }) {
  const [open, setOpen] = useState(false);
  const [site, setSite] = useState(sites.length === 1 ? sites[0].id : '');
  const [qty, setQty] = useState('');
  const [note, setNote] = useState('');
  const s = sites.find((x) => x.id === site);
  const n = qty || (site ? unitsBySite[site] || '' : Object.values(unitsBySite).reduce((a, b) => a + b, 0) || '');
  const body = `Hello Service Call Proof,\n\nPlease send printed QR stickers for:\n\nLocation: ${s ? `${s.name}, ${s.address || ''}` : 'all our locations (list below)'}\nNumber of stickers: ${n || '(please advise)'}\n${note ? `\nNotes: ${note}\n` : ''}\nPlease send a quote before printing.\n\nThank you`;
  const href = `mailto:support@servicecallproof.com?subject=${encodeURIComponent('Sticker order' + (s ? ` — ${s.name}` : ''))}&body=${encodeURIComponent(body)}`;
  return (
    <div className="stack" style={{ gap: 8 }}>
      <div className="order-choice">
        <div><strong>Print your own</strong><span className="small muted">Any printer on sticker paper (Avery 22806 or similar), then stick one on each unit.</span></div>
        <div><strong>Or order them from us</strong><span className="small muted">Weatherproof, pre-printed with your units, mailed to your store. Quoted before printing.</span>
          {!open && <button type="button" className="primary" onClick={() => setOpen(true)}>Order stickers from us</button>}</div>
      </div>
      {open && (
        <div className="stack" style={{ gap: 6, border: '1px solid var(--line)', borderRadius: 10, padding: 12 }}>
          <div className="row">
            {sites.length > 1 && <label className="grow">Location<select value={site} onChange={(e) => setSite(e.target.value)}><option value="">All locations</option>{sites.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></label>}
            <label className="grow">How many stickers?<input type="number" min="1" value={qty} onChange={(e) => setQty(e.target.value)} placeholder={n ? `${n} (one per unit listed)` : 'e.g. 25'} /></label>
          </div>
          <label>Anything else? <span className="muted" style={{ fontWeight: 400 }}>(optional)</span><input value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. extra stickers for new units, rush by Friday" /></label>
          <div className="row">
            <a className="callbtn" href={href}>✉ Send the order by email</a>
            <button type="button" onClick={() => setOpen(false)}>Cancel</button>
          </div>
          <div className="small muted">This opens your email with the order filled in, addressed to support@servicecallproof.com. We reply with a price before printing. Ordering and paying right here is coming soon.</div>
        </div>
      )}
    </div>
  );
}
