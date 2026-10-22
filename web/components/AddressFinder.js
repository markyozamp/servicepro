'use client';

// Type an address, tap Find: shows the matched address so the person can confirm it before saving.
import { useState } from 'react';

export default function AddressFinder({ id, value, onChange, onFound, found }) {
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');
  async function find() {
    setBusy(true); setMsg('');
    try {
      const r = await fetch(`/api/geocode?address=${encodeURIComponent(value)}`);
      const d = await r.json();
      if (!d.found) { onFound(null); setMsg(d.error || 'Address not found. Check the street, city and state (include the ZIP if you can).'); }
      else onFound(d);
    } catch { setMsg('The address lookup did not answer. Try again.'); } finally { setBusy(false); }
  }
  return (
    <div className="stack" style={{ gap: 6 }}>
      <label>Street address, city, state
        <div className="row" style={{ gap: 8, flexWrap: 'nowrap' }}>
          <input id={id} className="grow" value={value} onChange={(e) => { onChange(e.target.value); onFound(null); }} placeholder="e.g. 4852 Curt Cir, Grand Forks, ND 58201" />
          <button type="button" disabled={busy || value.trim().length < 5} onClick={find}>{busy ? 'Finding…' : 'Find'}</button>
        </div>
      </label>
      {found && <div className="notice small">Found: <strong>{found.address}</strong> · {found.timezone.replace('America/', '').replace('_', ' ')} time · map point set for automatic arrival</div>}
      {msg && <div className="error small">{msg}</div>}
    </div>
  );
}
