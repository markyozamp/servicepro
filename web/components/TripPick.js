'use client';

// Return trips the customer agrees to. The contractor offers up to 3 times; the customer taps the one that works,
// or says none of them work and what would. Used on the customer's dashboard and on the call.
import { useState } from 'react';
import { act } from '@/lib/supabase';
import { dateTime, time } from '@/lib/format';

export const OFFER_SELECT = 'id, work_order_id, tech_id, options, note, status, chosen, store_note, created_at, decided_at, tech:profiles!trip_offers_tech_id_fkey(full_name)';

export const optText = (o) => `${dateTime(o.start)}${o.end ? `–${time(o.end)}` : ''}`;

export default function TripPick({ offer, contractor, callNo, site, onDone, compact }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [no, setNo] = useState(false);
  const [note, setNote] = useState('');
  async function pick(i) {
    setBusy(true); setErr('');
    try { await act('store_pick_trip_time', { p_offer: offer.id, p_choice: i, p_note: i == null ? note : null }); onDone?.(); }
    catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  return (
    <div className="stack" style={{ gap: 6 }}>
      <div><strong>{contractor || 'Your contractor'} wants to come back{callNo ? ` for call #${callNo}` : ''}{site ? ` at ${site}` : ''}.</strong>
        {' '}{offer.tech?.full_name ? `${offer.tech.full_name} would come. ` : ''}Pick the time that works for you{compact ? '' : ' (so it doesn’t land in your busy hours)'}.
        {offer.note ? <span className="muted"> “{offer.note}”</span> : null}</div>
      <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
        {(offer.options || []).map((o, i) => (
          <button key={i} type="button" className="primary" disabled={busy} onClick={() => pick(i + 1)}>✓ {optText(o)}</button>
        ))}
        {!no && <button type="button" disabled={busy} onClick={() => setNo(true)}>None of these work</button>}
      </div>
      {no && (
        <div className="row" style={{ alignItems: 'flex-end' }}>
          <label className="grow">What would work? <span className="muted" style={{ fontWeight: 400 }}>(they get this and send new times)</span>
            <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. After 2 pm, or Tuesday morning before 10" /></label>
          <button type="button" disabled={busy || !note.trim()} onClick={() => pick(null)}>Send</button>
          <button type="button" onClick={() => setNo(false)}>Cancel</button>
        </div>
      )}
      {err && <div className="error">{err}</div>}
    </div>
  );
}
