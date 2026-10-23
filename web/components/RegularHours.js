'use client';

// The customer sets a contractor's regular hours: when their regular rate applies and when after-hours (overtime) starts.
// Some contractors run day and night crews at the regular rate; maintenance programs often have no overtime at all.
// Used under Contractors & QR → each contractor.
import { useState } from 'react';
import { act } from '@/lib/supabase';

const DAYS = [['mon', 'Mon'], ['tue', 'Tue'], ['wed', 'Wed'], ['thu', 'Thu'], ['fri', 'Fri'], ['sat', 'Sat'], ['sun', 'Sun']];
const STANDARD = { mon: ['08:00', '17:00'], tue: ['08:00', '17:00'], wed: ['08:00', '17:00'], thu: ['08:00', '17:00'], fri: ['08:00', '17:00'], sat: null, sun: null, holidays: 'after' };
const PRESETS = [
  ['Mon–Fri 8 to 5', STANDARD],
  ['Mon–Fri 7 to 5, Sat 8 to noon', { mon: ['07:00', '17:00'], tue: ['07:00', '17:00'], wed: ['07:00', '17:00'], thu: ['07:00', '17:00'], fri: ['07:00', '17:00'], sat: ['08:00', '12:00'], sun: null, holidays: 'after' }],
  ['Day and night crew: 6 am to 10 pm every day', Object.fromEntries([...DAYS.map(([d]) => [d, ['06:00', '22:00']]), ['holidays', 'regular']])],
  ['Regular rate around the clock', Object.fromEntries([...DAYS.map(([d]) => [d, ['00:00', '24:00']]), ['holidays', 'regular']])],
];

export function hoursSummary(h) {
  if (!h) return 'Standard (Mon–Fri business hours)';
  const on = DAYS.filter(([d]) => Array.isArray(h[d]));
  if (!on.length) return 'Every hour is after hours';
  const same = on.every(([d]) => h[d][0] === h[on[0][0]][0] && h[d][1] === h[on[0][0]][1]);
  const t = (x) => (x === '24:00' ? 'midnight' : x);
  const span = same ? `${t(h[on[0][0]][0])}–${t(h[on[0][0]][1])}` : 'varies by day';
  return `${on.length === 7 ? 'Every day' : on.map(([, l]) => l).join(', ')} ${span}`;
}

export default function RegularHours({ contractorId, name, initial, canEdit = true, onSaved }) {
  const [h, setH] = useState(() => ({ ...STANDARD, ...(initial || {}) }));
  const [custom, setCustom] = useState(!!initial);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  const setDay = (d, i, v) => setH({ ...h, [d]: [...(h[d] || ['08:00', '17:00'])].map((x, j) => (j === i ? v : x)) });
  async function save(next) {
    setBusy(true); setErr(''); setMsg('');
    try { await act('set_regular_hours', { p_contractor: contractorId, p_hours: next }); setMsg(`Saved. ${name || 'This contractor'}'s after-hours rate now follows these hours.`); onSaved?.(); }
    catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  return (
    <div className="stack" style={{ gap: 8 }}>
      <div className="small muted">Their regular rate applies inside these hours. Outside them (and on days left blank) is after hours. Calls, the verified time and the bill check all follow this.</div>
      <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
        {PRESETS.map(([l, p]) => <button key={l} type="button" className="small" disabled={!canEdit} onClick={() => { setH({ ...p, pm_regular: h.pm_regular }); setCustom(true); }}>{l}</button>)}
      </div>
      <table className="small" style={{ maxWidth: 460 }}>
        <tbody>{DAYS.map(([d, l]) => (
          <tr key={d}>
            <td style={{ width: 60 }}><label className="row" style={{ gap: 4, fontWeight: 600 }}><input type="checkbox" style={{ width: 'auto' }} disabled={!canEdit} checked={Array.isArray(h[d])}
              onChange={(e) => { setCustom(true); setH({ ...h, [d]: e.target.checked ? ['08:00', '17:00'] : null }); }} />{l}</label></td>
            <td>{Array.isArray(h[d]) ? (
              <span className="row" style={{ gap: 4 }}>
                <input type="time" value={h[d][0]} disabled={!canEdit} onChange={(e) => { setCustom(true); setDay(d, 0, e.target.value); }} style={{ width: 'auto' }} />
                to
                {h[d][1] === '24:00' ? <button type="button" className="small" disabled={!canEdit} onClick={() => setDay(d, 1, '23:00')}>midnight</button>
                  : <input type="time" value={h[d][1]} disabled={!canEdit} onChange={(e) => { setCustom(true); setDay(d, 1, e.target.value); }} style={{ width: 'auto' }} />}
              </span>) : <span className="muted">After hours all day</span>}</td>
          </tr>
        ))}</tbody>
      </table>
      <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} disabled={!canEdit} checked={h.holidays === 'regular'}
        onChange={(e) => { setCustom(true); setH({ ...h, holidays: e.target.checked ? 'regular' : 'after' }); }} />Holidays are regular hours too</label>
      <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} disabled={!canEdit} checked={!!h.pm_regular}
        onChange={(e) => { setCustom(true); setH({ ...h, pm_regular: e.target.checked }); }} />Maintenance (PM) calls are never after hours (no overtime on the maintenance program)</label>
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
      {canEdit && (
        <div className="row">
          <button type="button" className="primary" disabled={busy || !custom} onClick={() => save(h)}>Save hours</button>
          {initial && <button type="button" disabled={busy} onClick={() => { setH(STANDARD); setCustom(false); save(null); }}>Back to standard</button>}
        </div>
      )}
    </div>
  );
}
