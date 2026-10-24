'use client';

// Crew on calls.
//  * CrewHome (any tech's home screen): "Helping on a job?" Check in on a call your company has someone on, on your
//    own phone (location-checked). Checked in: "Leaving" or "Switch to another job".
//  * CrewPanel (the lead's job screen): who's checked in, verified or not; "Left" for someone who's going;
//    add someone without the app (recorded by the lead, not verified).
//  * crewBeforeLeaving: before the lead leaves or finishes, anyone still checked in: "they stayed until now" or a time.
// These need signal (they're checked against the location when they happen).
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import * as T from '@/lib/techStore';
import { time } from '@/lib/format';

const ROLE = { helper: 'Helper', apprentice: 'Apprentice', tech: 'Tech' };
const since = (t) => time(t);

export function CrewHome({ collapsed }) {
  const [d, setD] = useState(null);
  const [open, setOpen] = useState(!collapsed);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [switching, setSwitching] = useState(false);
  const load = useCallback(async () => { try { setD(await act('crew_today', {})); } catch (x) { setErr(x.message); } }, []);
  useEffect(() => { load(); const t = setInterval(load, 60000); return () => clearInterval(t); }, [load]);
  if (!d) return null;
  const mine = d.mine?.[0];
  if (!mine && !(d.calls || []).length && !open) return null;
  async function checkIn(visitId) {
    setBusy(true); setErr(''); setMsg('');
    try {
      if (!navigator.onLine) throw new Error('Needs signal to check in (it checks you’re at the location).');
      const p = await T.position(8000);
      const r = await act('crew_check_in', { p_visit: visitId, p_lat: p?.lat ?? null, p_lon: p?.lon ?? null });
      setMsg(`Checked in on call #${r.number}.`); setSwitching(false); load();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  async function checkOut(sw) {
    setBusy(true); setErr(''); setMsg('');
    try {
      if (!navigator.onLine) throw new Error('Needs signal to check out (it checks you’re still at the location).');
      const p = await T.position(8000);
      const r = await act('crew_check_out', { p_crew: mine.id, p_lat: p?.lat ?? null, p_lon: p?.lon ?? null });
      setMsg(r.note || `Checked out of call #${mine.number}.${sw ? ' Pick your next job, then tap "I’m here" when you get there.' : ''}`);
      setSwitching(!!sw); load();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  return (
    <div className="sec stack" style={{ gap: 8 }}>
      {mine ? (
        <>
          <h3 style={{ margin: 0 }}>You&apos;re checked in</h3>
          <div><strong>Call #{mine.number} · {mine.site}</strong><div className="small">with {mine.lead} · since {since(mine.arrived_at)} · {ROLE[mine.role]}</div></div>
          <button className="primary big" disabled={busy} onClick={() => checkOut(false)}>Leaving</button>
          <button className="big" disabled={busy} onClick={() => checkOut(true)}>Switch to another job</button>
          <div className="small muted">Tap Leaving before you go: only time between your own check-in and check-out counts as verified.</div>
        </>
      ) : (
        <>
          <button type="button" className="linkish" style={{ textAlign: 'left' }} onClick={() => setOpen(!open)}><h3 style={{ margin: 0 }}>Helping on a job?{switching ? ' Pick your next one' : ''}</h3></button>
          {(open || switching) && ((d.calls || []).length === 0 ? <div className="small muted">Nobody from your company is on a call right now.</div> : d.calls.map((c) => (
            <div key={c.visit_id} className="jobcard">
              <div className="spread"><strong>#{c.number} · {c.site}</strong><span className="small">{c.lead} since {since(c.arrived_at)}</span></div>
              <div className="small muted">{c.address}</div>
              <button className="primary" disabled={busy} onClick={() => checkIn(c.visit_id)}>I&apos;m here</button>
            </div>
          )))}
        </>
      )}
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
    </div>
  );
}

export function CrewPanel({ visitId }) {
  const [d, setD] = useState(null);
  const [add, setAdd] = useState(null);
  const [err, setErr] = useState('');
  const load = useCallback(async () => { try { setD(await act('visit_crew_list', { p_visit: visitId })); } catch (x) { setErr(x.message); } }, [visitId]);
  useEffect(() => { load(); const t = setInterval(load, 60000); return () => clearInterval(t); }, [load]);
  if (!d) return null;
  const run = async (args) => { setErr(''); try { await act('crew_lead_mark', { p_visit: visitId, ...args }); setAdd(null); load(); } catch (x) { setErr(x.message); } };
  const here = d.crew.filter((c) => !c.left_at);
  const gone = d.crew.filter((c) => c.left_at);
  return (
    <div className="sec stack" style={{ gap: 6 }}>
      <div className="spread"><h3 style={{ margin: 0 }}>Crew checked in</h3><button type="button" className="linkbtn small" onClick={load}>Refresh</button></div>
      {here.length === 0 && <div className="small muted">Helpers and apprentices check in on their own phones: Home → &ldquo;Helping on a job?&rdquo; → I&apos;m here.</div>}
      {here.map((c) => (
        <div key={c.id} className="spread small">
          <span><strong>{c.name}</strong> · {ROLE[c.role]} · since {since(c.arrived_at)} {c.arrived_by === 'self' ? (c.arrived_ok ? '✓' : '(location not checked)') : <span className="muted">(recorded by you, not verified)</span>}</span>
          <button onClick={() => (c.arrived_by === 'self' ? window.confirm(`${c.name} should tap Leaving on his own phone (that's verified). Record it for him instead (not verified)?`) : true) && run({ p_event: 'left', p_crew: c.id })}>Left</button>
        </div>
      ))}
      {gone.length > 0 && <div className="small muted">{gone.map((c) => `${c.name} ${since(c.arrived_at)}–${since(c.left_at)}${c.verified ? ' ✓' : ''}`).join(' · ')}</div>}
      {add ? (
        <div className="stack small" style={{ gap: 6 }}>
          {(d.team || []).length > 0 && <select value="" onChange={(e) => e.target.value && run({ p_event: 'arrived', p_profile: e.target.value, p_role: d.team.find((t) => t.id === e.target.value)?.role })}>
            <option value="">Someone on your team (forgot his phone)…</option>{d.team.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select>}
          <div className="row" style={{ gap: 6 }}>
            <input value={add.name} onChange={(e) => setAdd({ ...add, name: e.target.value })} placeholder="or their name" />
            <select value={add.role} onChange={(e) => setAdd({ ...add, role: e.target.value })} style={{ width: 'auto' }}><option value="helper">Helper</option><option value="apprentice">Apprentice</option></select>
            <button className="primary" disabled={!add.name.trim()} onClick={() => run({ p_event: 'arrived', p_name: add.name, p_role: add.role })}>Add</button>
            <button onClick={() => setAdd(null)}>Cancel</button>
          </div>
          <div className="muted">Recorded by you, so it isn&apos;t verified: their hours show as &ldquo;not verified&rdquo; to the customer.</div>
        </div>
      ) : <button type="button" className="linkbtn small" style={{ alignSelf: 'flex-start' }} onClick={() => setAdd({ name: '', role: 'helper' })}>+ Someone here without the app</button>}
      {err && <div className="error small">{err}</div>}
    </div>
  );
}

// Before the lead leaves or finishes: anyone still checked in? Returns the open crew (empty when offline).
export async function openCrew(visitId) {
  if (!navigator.onLine) return [];
  try { const d = await act('visit_crew_list', { p_visit: visitId }); return (d.crew || []).filter((c) => !c.left_at); } catch { return []; }
}

export function CrewCloseout({ visitId, rows, onDone, onCancel }) {
  const [times, setTimes] = useState({});
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  async function save(allNow) {
    setBusy(true); setErr('');
    try {
      for (const c of rows) {
        const t = allNow ? null : times[c.id];
        let at = null;
        if (t) { const [hh, mm] = t.split(':').map(Number); const x = new Date(); x.setHours(hh, mm, 0, 0); at = x.toISOString(); }
        await act('crew_lead_mark', { p_visit: visitId, p_event: 'left', p_crew: c.id, p_at: at });
      }
      onDone();
    } catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  return (
    <div className="sec stack" style={{ gap: 8, borderColor: '#e6c98a', background: '#fffcf3' }}>
      <strong>{rows.map((c) => c.name).join(', ')} {rows.length > 1 ? 'are' : 'is'} still checked in here.</strong>
      <button className="primary big" disabled={busy} onClick={() => save(true)}>They stayed until now</button>
      <div className="small">Or when each one left:</div>
      {rows.map((c) => (
        <label key={c.id} className="row small" style={{ gap: 6, fontWeight: 400 }}>{c.name}<input type="time" value={times[c.id] || ''} onChange={(e) => setTimes({ ...times, [c.id]: e.target.value })} style={{ width: 130 }} /></label>
      ))}
      <div className="row" style={{ gap: 6 }}><button disabled={busy || rows.some((c) => !times[c.id])} onClick={() => save(false)}>Save the times</button><button onClick={onCancel}>Back</button></div>
      <div className="small muted">Times you enter here are marked &ldquo;entered at checkout&rdquo;, not verified. Next time, have them tap Leaving on their phones.</div>
      {err && <div className="error small">{err}</div>}
    </div>
  );
}
