'use client';

// The temperature log for one location and dates: for a product claim, the insurer or the health inspector.
// Per unit: a graph of every reading (limits drawn, alarm periods shaded), hour by hour (reading, the hour's high and low,
// out of range flagged), the alarms, door openings per day, typed entries. Print / save as PDF, or download (CSV).
import { Suspense, useEffect, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import { act } from '@/lib/supabase';
import { useProfile } from '@/lib/useProfile';

const f1 = (n) => (n == null ? '' : `${Number(n).toFixed(1).replace(/\.0$/, '')}°F`);
const ALARM = { high: 'Too warm', low: 'Too cold', door: 'Door open', quiet: 'Not reporting', battery: 'Battery low' };

function fmt(t, tz, opt) { try { return new Date(t).toLocaleString('en-US', { timeZone: tz, ...opt }); } catch { return new Date(t).toLocaleString(); } }
const when = (t, tz) => (t ? fmt(t, tz, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '');
// The hour key from the database is local wall time ("2026-10-24T13:00:00")
const hourLabel = (h) => { const [d, t] = String(h).split('T'); const hr = Number(t.slice(0, 2)); return { day: d, label: `${((hr + 11) % 12) + 1}:00 ${hr < 12 ? 'AM' : 'PM'}` }; };
const dayLabel = (d) => new Date(`${d}T12:00`).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });

function Graph({ u, from, to, tz }) {
  const pts = (u.readings || []).filter((r) => r.temp_f != null);
  if (pts.length < 2) return <div className="small muted">Not enough readings to graph.</div>;
  const W = 760, H = 220, L = 44, B = 22;
  const t0 = new Date(`${from}T00:00`).getTime(), t1 = new Date(`${to}T23:59:59`).getTime();
  const ts = pts.map((p) => new Date(p.at).getTime());
  const a0 = Math.min(t0, ts[0]), a1 = Math.max(t1, ts[ts.length - 1]);
  const vals = pts.map((p) => Number(p.temp_f)).concat([u.low_f, u.high_f].filter((v) => v != null).map(Number));
  const lo = Math.floor(Math.min(...vals) - 3), hi = Math.ceil(Math.max(...vals) + 3);
  const x = (t) => L + ((t - a0) / Math.max(1, a1 - a0)) * (W - L - 6);
  const y = (v) => 6 + (1 - (v - lo) / Math.max(1, hi - lo)) * (H - B - 6);
  const days = []; for (let d = new Date(`${from}T00:00`); d.getTime() <= t1; d.setDate(d.getDate() + 1)) days.push(new Date(d));
  const step = Math.max(1, Math.ceil(days.length / 8));
  const ticks = [lo, Math.round((lo + hi) / 2), hi];
  return (
    <svg viewBox={`0 0 ${W} ${H}`} style={{ width: '100%', height: 'auto' }} role="img" aria-label={`${u.name} temperatures`}>
      {(u.alarms || []).filter((a) => ['high', 'low'].includes(a.kind)).map((a, i) => {
        const s = Math.max(a0, new Date(a.started_at).getTime()), e = Math.min(a1, a.cleared_at ? new Date(a.cleared_at).getTime() : Date.now());
        return <rect key={i} x={x(s)} y={6} width={Math.max(2, x(e) - x(s))} height={H - B - 6} fill="#d64545" opacity="0.12" />;
      })}
      {ticks.map((v) => <g key={v}><line x1={L} x2={W - 6} y1={y(v)} y2={y(v)} stroke="#ddd" /><text x={L - 6} y={y(v) + 4} fontSize="11" textAnchor="end" fill="#666">{v}°</text></g>)}
      {days.filter((_, i) => i % step === 0).map((d) => <text key={d.toISOString()} x={x(d.getTime())} y={H - 6} fontSize="11" fill="#666">{d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}</text>)}
      {u.high_f != null && <line x1={L} x2={W - 6} y1={y(u.high_f)} y2={y(u.high_f)} stroke="#d64545" strokeDasharray="5 4" />}
      {u.low_f != null && <line x1={L} x2={W - 6} y1={y(u.low_f)} y2={y(u.low_f)} stroke="#3b7dd8" strokeDasharray="5 4" />}
      <polyline fill="none" stroke="#222" strokeWidth="1.5" points={pts.map((p, i) => `${x(ts[i]).toFixed(1)},${y(Number(p.temp_f)).toFixed(1)}`).join(' ')} />
    </svg>
  );
}

function Unit({ u, r }) {
  const tz = r.timezone;
  const byDay = (u.hours || []).reduce((m, h) => { const { day } = hourLabel(h.hour); (m[day] = m[day] || []).push(h); return m; }, {});
  const outHours = (u.hours || []).filter((h) => h.out).length;
  const [show, setShow] = useState(Object.keys(byDay).length <= 3);
  return (
    <section className="panel panel-pad stack templog-unit" style={{ gap: 10 }}>
      <div className="spread"><h2 style={{ margin: 0 }}>{u.name}{u.kind === 'door' ? ' door' : ''}</h2>
        <span className="small">{u.kind === 'door' ? 'Door sensor' : `Limits ${u.low_f != null ? f1(u.low_f) : 'none'} to ${u.high_f != null ? f1(u.high_f) : 'none'}`}{u.kind === 'manual' ? ' · typed log' : ''}</span></div>
      {u.kind !== 'door' && (
        <>
          <Graph u={u} from={r.from} to={r.to} tz={tz} />
          <div className="small">{(u.hours || []).length} hours recorded{u.kind !== 'manual' ? ` (${(u.readings || []).length} readings)` : ''} · <strong style={outHours ? { color: '#b00' } : {}}>{outHours} hour{outHours === 1 ? '' : 's'} out of range</strong></div>
        </>
      )}
      {(u.alarms || []).length > 0 && (
        <div className="stack small" style={{ gap: 2 }}><strong>Alarms</strong>
          {u.alarms.map((a, i) => <div key={i}>{ALARM[a.kind] || a.kind}{a.value != null && ['high', 'low'].includes(a.kind) ? ` (${f1(a.value)})` : ''}: {when(a.started_at, tz)} to {a.cleared_at ? when(a.cleared_at, tz) : 'still open'}
            {a.ack_at ? ` · acknowledged by ${a.ack_name || 'staff'} ${when(a.ack_at, tz)}` : ''}{a.call_number ? ` · service call #${a.call_number}` : ''}</div>)}
        </div>
      )}
      {u.kind === 'door' && (
        <table className="small"><thead><tr><th>Day</th><th className="num">Times opened</th><th className="num">Longest open</th></tr></thead>
          <tbody>{(u.doors || []).length === 0 ? <tr><td colSpan={3} className="muted">No openings recorded.</td></tr>
            : u.doors.map((d) => <tr key={d.day}><td>{dayLabel(d.day)}</td><td className="num">{d.opened}</td><td className="num">{d.longest_min} min</td></tr>)}</tbody></table>
      )}
      {u.kind !== 'door' && Object.keys(byDay).length > 0 && (
        <div className="small">
          <button type="button" className="linkbtn small noprint" onClick={() => setShow(!show)}>{show ? 'Hide' : 'Show'} hour by hour</button>
          <div className={show ? '' : 'printonly'}>
            {Object.entries(byDay).map(([day, hrs]) => (
              <table key={day} className="small" style={{ marginTop: 6 }}>
                <thead><tr><th colSpan={5}>{dayLabel(day)}</th></tr><tr><th>Hour</th><th className="num">Reading</th><th className="num">Low</th><th className="num">High</th><th /></tr></thead>
                <tbody>{hrs.map((h) => <tr key={h.hour} style={h.out ? { color: '#b00', fontWeight: 600 } : {}}><td>{hourLabel(h.hour).label}</td><td className="num">{f1(h.last)}</td><td className="num">{f1(h.low)}</td><td className="num">{f1(h.high)}</td><td>{h.out ? 'OUT OF RANGE' : ''}</td></tr>)}</tbody>
              </table>
            ))}
          </div>
        </div>
      )}
      {(u.typed || []).length > 0 && (
        <div className="stack small" style={{ gap: 2 }}><strong>Typed entries</strong>
          {u.typed.map((t, i) => <div key={i}>{when(t.at, tz)}: {f1(t.temp_f)}{t.by ? ` by ${t.by}` : ''}{t.note ? ` (${t.note})` : ''}</div>)}</div>
      )}
    </section>
  );
}

function csv(r) {
  const c = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;
  const rows = [['Location', 'Unit', 'Date and hour (local)', 'Reading °F', 'Hour low °F', 'Hour high °F', 'Out of range', 'Low limit', 'High limit']];
  for (const u of r.units) for (const h of u.hours || []) rows.push([r.site.name, u.name, String(h.hour).replace('T', ' ').slice(0, 16), h.last, h.low, h.high, h.out ? 'yes' : '', u.low_f, u.high_f]);
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([rows.map((x) => x.map(c).join(',')).join('\r\n')], { type: 'text/csv' }));
  a.download = `temperature-log-${r.site.name.replace(/[^\w]+/g, '-')}-${r.from}-to-${r.to}.csv`; a.click();
}

function Log() {
  const sp = useSearchParams();
  const { profile } = useProfile();
  const [r, setR] = useState(null);
  const [err, setErr] = useState('');
  const site = sp.get('site'), from = sp.get('from'), to = sp.get('to'), unit = sp.get('unit');
  useEffect(() => {
    if (!profile || !site) return;
    act('monitor_report', { p_site: site, p_from: from, p_to: to, p_device: unit || null }).then(setR).catch((x) => setErr(x.message));
  }, [profile, site, from, to, unit]);
  if (err) return <main className="page"><div className="error">{err}</div></main>;
  if (!r) return <main className="page muted">Loading…</main>;
  return (
    <main className="page billpage">
      <div className="row noprint" style={{ justifyContent: 'flex-end', gap: 8 }}>
        <button className="primary" onClick={() => window.print()}>Print / save as PDF</button>
        <button onClick={() => csv(r)}>Download (CSV)</button>
        <button onClick={() => window.close()}>Close</button>
      </div>
      <div className="panel panel-pad stack" style={{ gap: 4 }}>
        <h1 style={{ margin: 0 }}>Temperature log</h1>
        <div><strong>{r.customer}</strong> · {r.site.name} · {r.site.address}</div>
        <div className="small">{dayLabel(r.from)} to {dayLabel(r.to)} · times are {r.timezone.replace('_', ' ')} · printed {when(r.made_at, r.timezone)}</div>
        <div className="small muted">Recorded automatically by the sensors (and typed entries where marked), kept unchanged in Service Call Proof.</div>
      </div>
      {r.units.length === 0 ? <div className="panel panel-pad muted">No sensors or logs at this location.</div> : r.units.map((u) => <Unit key={u.id} u={u} r={r} />)}
    </main>
  );
}

export default function TemperatureLog() {
  return <Suspense fallback={<main className="page muted">Loading…</main>}><Log /></Suspense>;
}
