'use client';

// Follow-through report: how well each location follows through on what the app asks of it (giving the check-in code,
// answering requests for more money, confirming calls, approving bills, looking at flags, handling unexpected visitors,
// chasing late invoices, answering maintenance plans). The owner sees everything; everyone else sees their own locations.
// FollowThroughSettings sits in Settings & plan: on/off, the limit, and who gets the weekly alert.
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money, date } from '@/lib/format';
import { usePlace } from '@/lib/terms';
import Info from './Info';

const pct = (n) => `${Number(n || 0).toLocaleString(undefined, { maximumFractionDigits: 1 })}%`;
const hrs = (m) => (m >= 90 ? `${(m / 60).toFixed(1)} hours` : `${m} min`);

export function FollowThroughReport({ onClose, onOpenCall }) {
  const place = usePlace();
  const [days, setDays] = useState(30);
  const [r, setR] = useState(null);
  const [err, setErr] = useState('');
  useEffect(() => {
    setR(null); setErr('');
    supabase.rpc('followthrough_report', { p_days: days }).then(({ data, error }) => (error ? setErr(error.message) : setR(data)));
  }, [days]);
  const ok = r ? r.total - r.missed : 0;
  return (
    <div className="panel panel-pad stack work-panel" id="followthrough">
      <div className="spread">
        <h2>Follow-through report <Info title="Follow-through report">{`Repairs and maintenance are one of your largest controllable costs. Each step that's missed is where overbilling and downtime slip in. This report counts what Service Call Proof asked your people to do, each with a deadline: give the technician the check-in code within 10 minutes, answer a request for more money within 24 hours, confirm a call a contractor entered within 24 hours, approve a bill within 7 days, look at a flag within 3 days, take care of an unexpected visitor within a day, chase a late invoice within 2 days, and answer a maintenance plan within 7 days. Things still inside their deadline aren't counted yet. "People at this ${place.one}" are the people who can see it and get its alerts; we can't know who was on shift.`}</Info></h2>
        <div className="row" style={{ gap: 6 }}>
          <select value={days} onChange={(e) => setDays(Number(e.target.value))} style={{ width: 'auto' }} aria-label="Period">
            <option value={30}>Last 30 days</option><option value={90}>Last 90 days</option><option value={365}>Last 12 months</option>
          </select>
          {onClose && <button onClick={onClose}>Close</button>}
        </div>
      </div>
      {err && <div className="error">{err}</div>}
      {!r && !err && <div className="muted">Adding it up…</div>}
      {r && (
        <>
          {r.total === 0 ? <div className="muted">Nothing to count yet for this period. As service calls come in, this fills up.</div> : (
            <>
              <div className="row" style={{ gap: 10, alignItems: 'stretch' }}>
                <div className="tile" style={{ cursor: 'default' }}><span className="tile-n">{ok} of {r.total}</span><span>done on time</span></div>
                <div className={`tile${r.over ? ' bad' : ''}`} style={{ cursor: 'default' }}><span className="tile-n">{pct(r.pct)}</span><span>missed{r.on ? ` (your limit: ${pct(r.limit_pct)})` : ''}</span></div>
                {r.wait_min > 0 && <div className="tile warn" style={{ cursor: 'default' }}><span className="tile-n">{hrs(r.wait_min)}</span><span>technicians waited for codes{Number(r.wait_dollars) > 0 ? `, about ${money(r.wait_dollars)} of labor` : ''}</span></div>}
                {Number(r.bills_waiting) > 0 && <div className="tile warn" style={{ cursor: 'default' }}><span className="tile-n">{money(r.bills_waiting)}</span><span>in bills waited 7+ days</span></div>}
              </div>
              {r.over && <div className="notice small"><strong>Over the limit.</strong> {r.missed} missed is more than {pct(r.limit_pct)} of what was asked. The list below shows each one, where, and who was getting the alerts.</div>}

              <table className="small">
                <thead><tr><th>What was asked</th><th className="num">Items</th><th className="num">Missed</th></tr></thead>
                <tbody>{r.by_kind.map((k) => <tr key={k.kind}><td>{k.label}</td><td className="num">{k.total}</td><td className="num">{k.missed ? <strong style={{ color: 'var(--red-fg)' }}>{k.missed}</strong> : 0}</td></tr>)}</tbody>
              </table>

              <h3>By {place.one}</h3>
              <table className="small">
                <thead><tr><th>{place.One}</th><th className="num">Missed</th><th className="hide-sm">People at this {place.one}</th></tr></thead>
                <tbody>{r.by_site.map((s) => (
                  <tr key={s.site_id}><td>{s.name}</td><td className="num">{s.missed} of {s.total} <span className="muted">({pct(s.pct)})</span></td>
                    <td className="hide-sm">{s.people.length ? s.people.join(', ') : <span className="muted">Admins only</span>}</td></tr>
                ))}</tbody>
              </table>

              {r.misses.length > 0 && (
                <>
                  <h3>What was missed</h3>
                  <div className="stack" style={{ gap: 4 }}>
                    {r.misses.map((m, i) => (
                      <div key={i} className={`row small ft-miss${m.work_order_id && onOpenCall ? ' click' : ''}`} style={{ gap: 8, padding: '6px 8px', borderBottom: '1px solid var(--line)' }}
                        onClick={() => m.work_order_id && onOpenCall?.(m.work_order_id)}>
                        <span className="muted" style={{ minWidth: 70 }}>{date(m.at)}</span>
                        <span style={{ minWidth: 110 }}><strong>{m.site || '—'}</strong>{m.number ? ` · #${m.number}` : ''}</span>
                        <span className="grow">{m.detail}{Number(m.dollars) > 0 && m.kind === 'code' ? ` (about ${money(m.dollars)})` : ''}</span>
                      </div>
                    ))}
                  </div>
                </>
              )}
            </>
          )}
          {!r.on && <div className="small muted">The weekly alert to the owner is off. Turn it on under Settings &amp; plan → Follow-through report.</div>}
        </>
      )}
    </div>
  );
}

export function FollowThroughSettings({ org, onOpen }) {
  const [f, setF] = useState({ on: !!org?.followthrough_on, pct: org?.followthrough_pct ?? 5, min: org?.followthrough_min ?? 3, to: org?.followthrough_to || [] });
  const [team, setTeam] = useState([]);
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!org?.id) return;
    q(supabase.from('profiles').select('id, full_name, is_org_admin, active').eq('customer_id', org.id).eq('active', true).order('full_name')).then(setTeam).catch(() => {});
  }, [org?.id]);
  const admins = team.filter((p) => p.is_org_admin).map((p) => p.full_name);
  const toggle = (id) => setF({ ...f, to: f.to.includes(id) ? f.to.filter((x) => x !== id) : [...f.to, id] });
  return (
    <div className="stack" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 12 }}>
      <h3>Follow-through report <Info title="Follow-through report">Counts what your people were asked to do in Service Call Proof (give the check-in code, answer requests for more money, approve bills, look at flags and more) and how much was missed. Turn on the weekly alert and you hear about it when more than your limit is missed in the last 30 days. An emergency call where the technician waits 15 minutes or more for the code alerts you right away. Your team can see the report for their own locations, so everyone knows what's counted.</Info></h3>
      <label className="row" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.on} onChange={(e) => setF({ ...f, on: e.target.checked })} />
        Alert me when follow-through slips</label>
      {f.on && (
        <>
          <div className="row" style={{ alignItems: 'flex-end' }}>
            <label style={{ maxWidth: 200 }}>More than (% missed)<input type="number" min="1" max="50" step="0.5" value={f.pct} onChange={(e) => setF({ ...f, pct: e.target.value })} /></label>
            <label style={{ maxWidth: 200 }}>and at least (misses)<input type="number" min="1" max="50" step="1" value={f.min} onChange={(e) => setF({ ...f, min: e.target.value })} /></label>
          </div>
          <div className="small"><strong>Who gets the alerts</strong> <span className="muted">(none ticked = your admins{admins.length ? `: ${admins.join(', ')}` : ''})</span></div>
          <div className="row" style={{ gap: 12, flexWrap: 'wrap' }}>
            {team.map((p) => <label key={p.id} className="row small" style={{ gap: 4, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.to.includes(p.id)} onChange={() => toggle(p.id)} />{p.full_name}</label>)}
          </div>
        </>
      )}
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
      <div className="row">
        <button type="button" className="primary" disabled={busy} onClick={async () => {
          setErr(''); setMsg(''); setBusy(true);
          try {
            await act('set_followthrough', { p_on: f.on, p_pct: Number(f.pct), p_min: Math.round(Number(f.min)), p_to: f.to });
            setMsg(f.on ? `Saved. You'll get an alert on Mondays when more than ${f.pct}% (and at least ${f.min}) are missed over the last 30 days.` : 'Saved. The weekly alert is off; the report is still there anytime.');
          } catch (x) { setErr(x.message); } finally { setBusy(false); }
        }}>Save</button>
        {onOpen && <button type="button" onClick={onOpen}>Open the report</button>}
      </div>
    </div>
  );
}
