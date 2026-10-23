'use client';

// Busy hours for one location: when contractors may not come for non-emergency work (a lunch and dinner rush,
// patient hours). Up to 2 windows a day. Only the location can let a contractor in during them, per call.
import { useState } from 'react';
import { act } from '@/lib/supabase';
import { BUSY_DAYS, busySummary } from '@/lib/busy';

const empty = () => Object.fromEntries(BUSY_DAYS.map(([d]) => [d, []]));

export default function BusyHours({ siteId, siteName, initial, onSaved }) {
  const [h, setH] = useState(() => ({ ...empty(), ...(initial || {}) }));
  const [open, setOpen] = useState(false);
  const [same, setSame] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  const summary = busySummary(initial);

  const setRange = (d, i, k, v) => {
    const next = { ...h };
    const apply = (day) => { const list = [...(next[day] || [])]; list[i] = [...list[i]]; list[i][k] = v; next[day] = list; };
    if (same) BUSY_DAYS.forEach(([day]) => { if ((next[day] || [])[i]) apply(day); }); else apply(d);
    setH(next);
  };
  const addRange = (d) => {
    const next = { ...h };
    const add = (day) => { next[day] = [...(next[day] || []), (next[day] || []).length ? ['17:00', '19:30'] : ['11:00', '13:30']].slice(0, 2); };
    if (same) BUSY_DAYS.forEach(([day]) => add(day)); else add(d);
    setH(next);
  };
  const removeRange = (d, i) => {
    const next = { ...h };
    const rm = (day) => { next[day] = (next[day] || []).filter((_, j) => j !== i); };
    if (same) BUSY_DAYS.forEach(([day]) => rm(day)); else rm(d);
    setH(next);
  };
  async function save(value) {
    setBusy(true); setErr(''); setMsg('');
    try {
      const clean = value && Object.fromEntries(Object.entries(value).filter(([, v]) => Array.isArray(v) && v.length));
      await act('set_busy_hours', { p_site: siteId, p_hours: clean && Object.keys(clean).length ? clean : null });
      setMsg('Saved. Contractors can’t come for non-emergency work during these hours.'); onSaved?.();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }

  if (!open) {
    return (
      <div className="row small" style={{ gap: 8 }}>
        <strong>Busy hours:</strong> {summary ? <span className="chip tone-amber">{summary}</span> : <span className="muted">none</span>}
        <button type="button" onClick={() => setOpen(true)}>{summary ? 'Change' : 'Set busy hours'}</button>
      </div>
    );
  }
  const days = same ? [BUSY_DAYS[0]] : BUSY_DAYS;
  return (
    <div className="stack" style={{ gap: 8, border: '1px solid var(--line)', borderRadius: 10, padding: 10 }}>
      <strong>Busy hours at {siteName}</strong>
      <div className="small muted">Your rush hours: contractors can&apos;t schedule, offer or start a non-emergency visit then. Emergencies still come right away. If you want someone during busy hours, tap &ldquo;Let them come now&rdquo; on that call.</div>
      <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={same}
        onChange={(e) => { setSame(e.target.checked); if (e.target.checked) { const m = h.mon || []; setH(Object.fromEntries(BUSY_DAYS.map(([d]) => [d, m.map((r) => [...r])]))); } }} />Same every day</label>
      {days.map(([d, l]) => (
        <div key={d} className="row small" style={{ gap: 8, alignItems: 'center' }}>
          <strong style={{ width: 70 }}>{same ? 'Every day' : l}</strong>
          {(h[d] || []).map((r, i) => (
            <span key={i} className="row" style={{ gap: 4 }}>
              <input type="time" value={r[0]} onChange={(e) => setRange(d, i, 0, e.target.value)} style={{ width: 'auto' }} />–
              <input type="time" value={r[1]} onChange={(e) => setRange(d, i, 1, e.target.value)} style={{ width: 'auto' }} />
              <button type="button" className="linkbtn small" onClick={() => removeRange(d, i)}>✕</button>
            </span>
          ))}
          {(h[d] || []).length < 2 && <button type="button" className="small" onClick={() => addRange(d)}>+ {(h[d] || []).length ? 'Second window' : 'Add busy time'}</button>}
          {!(h[d] || []).length && <span className="muted">not busy</span>}
        </div>
      ))}
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
      <div className="row">
        <button type="button" className="primary" disabled={busy} onClick={() => save(h)}>Save busy hours</button>
        {summary && <button type="button" disabled={busy} onClick={() => { setH(empty()); save(null); }}>No busy hours</button>}
        <button type="button" onClick={() => setOpen(false)}>Close</button>
      </div>
    </div>
  );
}
