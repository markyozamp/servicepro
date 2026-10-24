'use client';

// Base: the week at a glance. One row per technician, a column per day, every trip on it; the calls that still
// need a trip on the side, each with Schedule (tech, day, from–to). Tap a trip to open the call.
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { time, date } from '@/lib/format';

const pad = (n) => String(n).padStart(2, '0');
const ymd = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const monday = (d) => { const x = new Date(d); const k = (x.getDay() + 6) % 7; x.setDate(x.getDate() - k); x.setHours(0, 0, 0, 0); return x; };
const STATUS = { assigned: 'st-blue', en_route: 'st-amber', on_site: 'st-green', done: 'st-slate' };
const STATUS_TXT = { assigned: 'scheduled', en_route: 'on the way', on_site: 'on site', done: 'done' };

function ScheduleForm({ call, techs, onDone, onCancel }) {
  const today = ymd(new Date());
  const [f, setF] = useState({ tech: techs[0]?.id || '', day: today, from: '08:00', to: '10:00' });
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  return (
    <form className="stack" style={{ gap: 6, marginTop: 6 }} onSubmit={async (e) => {
      e.preventDefault(); setBusy(true); setErr('');
      try {
        const start = new Date(`${f.day}T${f.from}`); const end = f.to ? new Date(`${f.day}T${f.to}`) : null;
        await act('schedule_trip', { p_wo: call.wo_id, p_tech: f.tech, p_start: start.toISOString(), p_end: end ? end.toISOString() : null });
        onDone();
      } catch (x) { setErr(x.message); } finally { setBusy(false); }
    }}>
      <div className="row" style={{ gap: 6 }}>
        <select value={f.tech} onChange={(e) => setF({ ...f, tech: e.target.value })} style={{ width: 'auto' }}>
          {techs.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
        </select>
        <input type="date" value={f.day} min={today} onChange={(e) => setF({ ...f, day: e.target.value })} style={{ width: 'auto' }} />
        <input type="time" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} style={{ width: 'auto' }} />–
        <input type="time" value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} style={{ width: 'auto' }} />
      </div>
      {err && <div className="error small">{err}{/customer times to pick/i.test(err) ? ' Open the call to send them times.' : ''}</div>}
      <div className="row" style={{ gap: 6 }}><button className="primary" disabled={busy || !f.tech}>Schedule</button><button type="button" onClick={onCancel}>Cancel</button></div>
    </form>
  );
}

export default function TechSchedule({ onOpenCall, refreshKey }) {
  const [start, setStart] = useState(() => monday(new Date()));
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [pick, setPick] = useState(null);
  const load = useCallback(async () => {
    try { setD(await act('tech_schedule', { p_from: ymd(start), p_days: 7 })); setErr(''); } catch (x) { setErr(x.message); }
  }, [start]);
  useEffect(() => { load(); }, [load, refreshKey]);

  const days = [...Array(7)].map((_, i) => { const x = new Date(start); x.setDate(x.getDate() + i); return x; });
  const shift = (n) => { const x = new Date(start); x.setDate(x.getDate() + n * 7); setStart(x); };
  const todayKey = ymd(new Date());
  if (err) return <div className="error">{err}</div>;
  if (!d) return <div className="muted">Loading the schedule…</div>;
  const byCell = (tech, day) => (d.visits || []).filter((v) => v.tech_id === tech && ymd(new Date(v.start)) === ymd(day));

  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="spread">
        <div className="row" style={{ gap: 6 }}>
          <button onClick={() => shift(-1)} aria-label="Previous week">‹</button>
          <strong>Week of {date(start)}</strong>
          <button onClick={() => shift(1)} aria-label="Next week">›</button>
          <button onClick={() => setStart(monday(new Date()))}>This week</button>
        </div>
        <span className="small muted">{(d.visits || []).length} trips this week</span>
      </div>

      {(d.unscheduled || []).length > 0 && (
        <div className="panel panel-pad stack" style={{ gap: 6, borderColor: '#e6c98a', background: '#fffcf3' }}>
          <strong>Needs a trip ({d.unscheduled.length})</strong>
          {d.unscheduled.map((c) => (
            <div key={c.wo_id} style={{ borderTop: '1px solid var(--line)', paddingTop: 6 }}>
              <div className="spread">
                <span><button type="button" className="linkbtn" onClick={() => onOpenCall(c.wo_id)}>#{c.number}</button> {c.customer} · {c.site}
                  {c.priority === 1 && <span className="chip tone-red" style={{ marginLeft: 6 }}>Emergency</span>}
                  <div className="small muted">{c.issue}{c.window_start ? ` · customer asks ${date(c.window_start)} ${time(c.window_start)}` : ''}{c.mode === 'verify' && !c.accepted ? ' · not accepted yet' : ''}</div></span>
                {pick !== c.wo_id && <button onClick={() => setPick(c.wo_id)}>Schedule</button>}
              </div>
              {pick === c.wo_id && <ScheduleForm call={c} techs={d.techs || []} onCancel={() => setPick(null)} onDone={() => { setPick(null); load(); }} />}
            </div>
          ))}
        </div>
      )}

      <div className="panel tablewrap">
        <table className="schedtable">
          <thead><tr><th>Technician</th>{days.map((x) => <th key={ymd(x)} className={ymd(x) === todayKey ? 'today' : ''}>{x.toLocaleDateString(undefined, { weekday: 'short', month: 'numeric', day: 'numeric' })}</th>)}</tr></thead>
          <tbody>
            {(d.techs || []).length === 0 && <tr><td colSpan={8} className="muted">No technicians yet. Add them under Team.</td></tr>}
            {(d.techs || []).map((t) => (
              <tr key={t.id}>
                <td><strong>{t.name}</strong></td>
                {days.map((x) => (
                  <td key={ymd(x)} className={ymd(x) === todayKey ? 'today' : ''}>
                    {byCell(t.id, x).map((v) => (
                      <button key={v.visit_id} type="button" className={`schedtrip ${STATUS[v.status] || ''}`} onClick={() => onOpenCall(v.wo_id)}
                        title={`${v.customer} · ${v.site}: ${v.issue || ''}`}>
                        <span className="small"><strong>{time(v.start)}{v.end ? `–${time(v.end)}` : ''}</strong> · {STATUS_TXT[v.status] || v.status}</span>
                        <span>#{v.number} {v.site}</span>
                      </button>
                    ))}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="small muted">Tap a trip to open the call (move it, change the tech or cancel from there). Times are when the trip is scheduled, or when it started.</div>
    </div>
  );
}
