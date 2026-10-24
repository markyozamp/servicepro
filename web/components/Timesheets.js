'use client';

// Base: timesheets. Techs clock in, out and take breaks on the phone; here the office sees each tech's week
// (paid hours, overtime over 40, time on site, driving, jobs), opens the punches, fixes one with a reason,
// approves the week and downloads the approved weeks for payroll.
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { date, time } from '@/lib/format';

const pad = (n) => String(n).padStart(2, '0');
const ymd = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const monday = (d) => { const x = new Date(d); const k = (x.getDay() + 6) % 7; x.setDate(x.getDate() - k); x.setHours(0, 0, 0, 0); return x; };
const hm = (m) => { const n = Math.round(Number(m || 0)); return `${Math.floor(n / 60)}:${pad(n % 60)}`; };
const local = (t) => { if (!t) return ''; const d = new Date(t); return `${ymd(d)}T${pad(d.getHours())}:${pad(d.getMinutes())}`; };

function Week({ tech, week, onBack, onChanged }) {
  const [w, setW] = useState(null);
  const [fix, setFix] = useState(null);
  const [err, setErr] = useState('');
  const load = useCallback(async () => { try { setW(await act('tech_week', { p_profile: tech.id, p_week: week })); } catch (x) { setErr(x.message); } }, [tech.id, week]);
  useEffect(() => { load(); }, [load]);
  if (!w) return err ? <div className="error">{err}</div> : <div className="muted">Loading…</div>;
  return (
    <div className="stack" style={{ gap: 10 }}>
      <button className="linkbtn small" style={{ alignSelf: 'flex-start' }} onClick={onBack}>← All technicians</button>
      <h3 style={{ margin: 0 }}>{w.name} · week of {date(week)}</h3>
      <div className="panel tablewrap">
        <table>
          <thead><tr><th>Day</th><th className="num">Clocked</th><th className="num">Breaks</th><th className="num">Paid</th><th className="num hide-sm">On site</th><th className="num hide-sm">Driving</th><th className="num hide-sm">Jobs</th><th className="num">Overtime</th></tr></thead>
          <tbody>
            {(w.days || []).map((x) => (
              <tr key={x.day}><td>{new Date(`${x.day}T12:00`).toLocaleDateString(undefined, { weekday: 'short', month: 'numeric', day: 'numeric' })}</td>
                <td className="num">{hm(x.shift_minutes)}</td><td className="num">{hm(x.break_minutes)}</td><td className="num"><strong>{hm(x.paid_minutes)}</strong></td>
                <td className="num hide-sm">{hm(x.onsite_minutes)}</td><td className="num hide-sm">{hm(x.drive_minutes)}</td><td className="num hide-sm">{x.jobs}</td>
                <td className="num">{Number(x.overtime_minutes) > 0 ? <strong style={{ color: 'var(--red-fg)' }}>{hm(x.overtime_minutes)}</strong> : '—'}</td></tr>
            ))}
          </tbody>
        </table>
      </div>
      <strong>Punches</strong>
      {(w.entries || []).length === 0 && <div className="small muted">No punches this week.</div>}
      {(w.entries || []).map((e) => (
        <div key={e.id} className="panel panel-pad small" style={{ padding: 10 }}>
          <div className="spread">
            <span><strong>{e.kind === 'shift' ? 'Shift' : 'Break'}</strong> {date(e.start)} {time(e.start)} – {e.end ? time(e.end) : <span className="chip tone-red">still open</span>}
              {e.note ? <span className="muted"> · {e.note}</span> : null}</span>
            {fix?.id !== e.id && <button className="small" onClick={() => setFix({ id: e.id, start: local(e.start), end: local(e.end), reason: '' })}>Fix</button>}
          </div>
          {fix?.id === e.id && (
            <form className="row" style={{ gap: 6, marginTop: 6, alignItems: 'flex-end' }} onSubmit={async (ev) => {
              ev.preventDefault(); setErr('');
              try {
                await act('correct_time_entry', { p_entry: e.id, p_start: new Date(fix.start).toISOString(), p_end: fix.end ? new Date(fix.end).toISOString() : null, p_reason: fix.reason });
                setFix(null); await load(); onChanged?.();
              } catch (x) { setErr(x.message); }
            }}>
              <label>Start<input type="datetime-local" value={fix.start} onChange={(x) => setFix({ ...fix, start: x.target.value })} /></label>
              <label>End<input type="datetime-local" value={fix.end} onChange={(x) => setFix({ ...fix, end: x.target.value })} /></label>
              <label className="grow">Why <span className="muted" style={{ fontWeight: 400 }}>(kept on the record)</span><input value={fix.reason} onChange={(x) => setFix({ ...fix, reason: x.target.value })} placeholder="e.g. Forgot to clock out, left at 4:30" /></label>
              <button className="primary" disabled={fix.reason.trim().length < 10}>Save</button><button type="button" onClick={() => setFix(null)}>Cancel</button>
            </form>
          )}
        </div>
      ))}
      {err && <div className="error">{err}</div>}
      <div className="small muted">Fixing a punch re-opens the week for approval.</div>
    </div>
  );
}

export default function Timesheets({ profile }) {
  const [week, setWeek] = useState(() => ymd(monday(new Date())));
  const [rows, setRows] = useState(null);
  const [open, setOpen] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const load = useCallback(async () => { try { setRows(await act('team_week', { p_week: week })); setErr(''); } catch (x) { setErr(x.message); } }, [week]);
  useEffect(() => { load(); }, [load]);
  const shift = (n) => { const x = new Date(`${week}T12:00`); x.setDate(x.getDate() + n * 7); setWeek(ymd(monday(x))); };
  const canPayroll = profile?.is_org_admin || profile?.can_bill;

  if (open) return <Week tech={open} week={week} onBack={() => { setOpen(null); load(); }} onChanged={load} />;
  const approved = (rows || []).filter((r) => r.approved_at);
  function download() {
    const head = ['Technician', 'Week of', 'Paid hours', 'Overtime hours', 'On site hours', 'Driving hours', 'Jobs', 'Approved by'];
    const lines = approved.map((r) => [r.name, week, (r.paid_min / 60).toFixed(2), (r.overtime_min / 60).toFixed(2), (r.onsite_min / 60).toFixed(2), (r.drive_min / 60).toFixed(2), r.jobs, r.approved_by || '']);
    const csv = [head, ...lines].map((l) => l.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(',')).join('\n');
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' })); a.download = `timesheets-${week}.csv`; a.click();
  }
  return (
    <div className="stack" style={{ gap: 12 }}>
      <div className="spread">
        <div className="row" style={{ gap: 6 }}>
          <button onClick={() => shift(-1)} aria-label="Previous week">‹</button>
          <strong>Week of {date(`${week}T12:00`)}</strong>
          <button onClick={() => shift(1)} aria-label="Next week">›</button>
          <button onClick={() => setWeek(ymd(monday(new Date())))}>This week</button>
        </div>
        {canPayroll && approved.length > 0 && (
          <button onClick={async () => { download(); try { const n = await act('mark_payroll_exported', { p_week: week }); setMsg(`Downloaded. ${n} week${n === 1 ? '' : 's'} marked as sent to payroll.`); load(); } catch (x) { setErr(x.message); } }}>Download for payroll (CSV)</button>
        )}
      </div>
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
      {!rows ? <div className="muted">Loading…</div> : (
        <div className="panel tablewrap">
          <table>
            <thead><tr><th>Technician</th><th className="num">Paid</th><th className="num">Overtime</th><th className="num hide-sm">On site</th><th className="num hide-sm">Driving</th><th className="num hide-sm">Jobs</th><th>Week</th></tr></thead>
            <tbody>
              {rows.length === 0 && <tr><td colSpan={7} className="muted">No technicians yet.</td></tr>}
              {rows.map((r) => (
                <tr key={r.id} className="click" onClick={() => setOpen(r)}>
                  <td><strong>{r.name}</strong>{r.open && <div><span className="chip tone-amber">clocked in now</span></div>}</td>
                  <td className="num"><strong>{hm(r.paid_min)}</strong></td>
                  <td className="num">{Number(r.overtime_min) > 0 ? <strong style={{ color: 'var(--red-fg)' }}>{hm(r.overtime_min)}</strong> : '—'}</td>
                  <td className="num hide-sm">{hm(r.onsite_min)}</td><td className="num hide-sm">{hm(r.drive_min)}</td><td className="num hide-sm">{r.jobs}</td>
                  <td onClick={(e) => e.stopPropagation()}>
                    {r.exported_at ? <span className="chip tone-slate">Sent to payroll</span>
                      : r.approved_at ? <span className="chip tone-green">Approved{r.approved_by ? ` by ${r.approved_by}` : ''}</span>
                      : r.id === profile?.id ? <span className="small muted">Someone else approves yours</span>
                      : <button className="primary small" onClick={async () => { setErr(''); try { await act('approve_timesheet', { p_profile: r.id, p_week: week }); load(); } catch (x) { setErr(x.message); } }}>Approve</button>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <div className="small muted">Paid = clocked time minus breaks. Overtime counts past 40 paid hours in the week. On site and driving come from the trips (verified), so you can compare them with the clock. Tap a tech to see their days and punches.</div>
    </div>
  );
}
