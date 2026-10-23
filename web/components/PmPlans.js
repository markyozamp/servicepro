'use client';

// Preventive maintenance plans. Store: sees every plan at its locations, creates or changes them, accepts what
// contractors propose, and sees how each PM actually went (trips, technicians, hours, checklist, finished in its window).
// Contractor: sees its plans with a customer and proposes new ones.
import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money } from '@/lib/format';
import { ErrorBox, Notice } from './bits';

const date = (d) => (d ? new Date(`${String(d).slice(0, 10)}T12:00:00`).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }) : '');
const EVERY = { 1: 'Monthly', 2: 'Every 2 months', 3: 'Quarterly', 4: 'Every 4 months', 6: 'Twice a year', 12: 'Yearly', 24: 'Every 2 years' };
const every = (n) => EVERY[n] || `Every ${n} months`;

function Progress({ pg, compact }) {
  if (!pg) return null;
  if (!pg.trips) return <span className="small muted">Not started yet</span>;
  const bad = [];
  if (pg.dragging) bad.push(pg.done ? `took past its ${pg.finish_within_days}-day window` : `past its ${pg.finish_within_days}-day window (should have been done by ${date(pg.deadline)})`);
  if (pg.tech_changed) bad.push(`${pg.techs} different technicians`);
  if (pg.short) bad.push(`only ${pg.hours} h of about ${pg.expected_hours} h`);
  return (
    <span className="small">
      {pg.trips} trip{pg.trips === 1 ? '' : 's'} · {pg.tech_names} · {pg.hours} h{pg.expected_hours ? ` of about ${pg.expected_hours} h` : ''}
      {pg.items ? ` · checklist ${pg.items_done}/${pg.items}` : ''}
      {!compact && pg.longest_gap_days > 1 ? ` · longest gap between trips ${pg.longest_gap_days} days` : ''}
      {bad.length > 0 && <strong style={{ color: 'var(--red-fg)' }}> · ⚠ {bad.join('; ')}</strong>}
    </span>
  );
}

function PlanForm({ plan, side, sites, contractors, onSaved, onCancel }) {
  const [f, setF] = useState(() => ({
    site: plan?.site_id || sites[0]?.id || '', contractor: plan?.contractor_id || contractors[0]?.contractor_id || '', equipment: plan?.equipment_id || '',
    name: plan?.name || '', freq: plan?.frequency_months || 3, due: plan?.next_due_on || '', price: plan?.price ?? '', hours: plan?.expected_hours ?? '',
    within: plan?.finish_within_days ?? 2, same: plan ? !!plan.same_tech : true, lead: plan?.lead_days ?? 14, active: plan ? plan.active : true,
    list: (plan?.checklist || []).map((c) => c.item).join('\n'),
  }));
  const [eq, setEq] = useState([]);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (side !== 'store' || !f.site) { setEq([]); return; }
    q(supabase.from('equipment').select('id, location_description, manufacturer, model, equipment_types(name)').eq('site_id', f.site).is('retired_at', null).order('location_description'))
      .then(setEq).catch(() => setEq([]));
  }, [f.site, side]);
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  return (
    <form className="stack" style={{ gap: 6 }} onSubmit={async (e) => {
      e.preventDefault(); setBusy(true); setErr('');
      try {
        const r = await act('save_pm_plan', { p_id: plan?.id || null, p_site: f.site, p_contractor: side === 'store' ? f.contractor : null, p_name: f.name,
          p_frequency_months: Number(f.freq), p_next_due: f.due, p_checklist: f.list.split('\n').map((x) => x.trim()).filter(Boolean).map((item) => ({ item })),
          p_price: f.price === '' ? null : Number(f.price), p_expected_hours: f.hours === '' ? null : Number(f.hours), p_finish_within_days: Number(f.within),
          p_same_tech: f.same, p_equipment: f.equipment || null, p_trade: null, p_lead_days: Number(f.lead), p_active: f.active });
        onSaved(r);
      } catch (x) { setErr(x.message); } finally { setBusy(false); }
    }}>
      <div className="row">
        <label className="grow">Location<select value={f.site} onChange={set('site')} required>{sites.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
        {side === 'store' && <label className="grow">Contractor<select value={f.contractor} onChange={set('contractor')} required>{contractors.map((c) => <option key={c.contractor_id} value={c.contractor_id}>{c.contractors?.name}</option>)}</select></label>}
      </div>
      {side === 'store' && eq.length > 0 && (
        <label>Unit (optional)<select value={f.equipment} onChange={set('equipment')}><option value="">The whole location / several units</option>
          {eq.map((x) => <option key={x.id} value={x.id}>{[x.equipment_types?.name, x.location_description, x.manufacturer].filter(Boolean).join(' — ')}</option>)}</select></label>
      )}
      <label>Name<input value={f.name} onChange={set('name')} placeholder="e.g. Quarterly refrigeration PM" required /></label>
      <div className="row">
        <label className="grow">How often<select value={f.freq} onChange={set('freq')}>{[1, 2, 3, 4, 6, 12, 24].map((n) => <option key={n} value={n}>{every(n)}</option>)}</select></label>
        <label className="grow">Next due<input type="date" value={f.due} onChange={set('due')} required /></label>
        <label className="grow">Price per visit ($)<input type="number" min="0" step="0.01" value={f.price} onChange={set('price')} placeholder="blank = covered / T&M" /></label>
      </div>
      <div className="row">
        <label className="grow">Expected on-site hours<input type="number" min="0.5" step="0.5" value={f.hours} onChange={set('hours')} placeholder="e.g. 16" /></label>
        <label className="grow">Finish within (days of starting)<input type="number" min="1" max="30" value={f.within} onChange={set('within')} required /></label>
        <label className="grow">Open the PM call (days ahead)<input type="number" min="1" max="60" value={f.lead} onChange={set('lead')} /></label>
      </div>
      <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.same} onChange={set('same')} /> The same technician start to finish</label>
      <label>Checklist (one item per line)<textarea rows={5} value={f.list} onChange={set('list')} placeholder={'Clean condenser coils\nCheck refrigerant pressures\nInspect door gaskets'} /></label>
      {plan && <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.active} onChange={set('active')} /> Active (untick to pause the plan)</label>}
      {err && <div className="small" style={{ color: 'var(--red-fg)' }}>{err}</div>}
      <div className="small muted">The PM call opens by itself before each due date. Once the work starts, it should be finished within the days you set{f.same ? ', by the same technician' : ''}. If it isn't, you're told.</div>
      <div className="row"><button className="primary" disabled={busy}>{side === 'store' ? 'Save plan' : 'Send to them'}</button><button type="button" onClick={onCancel}>Cancel</button></div>
    </form>
  );
}

export default function PmPlans({ side = 'store', customerId, sites: sitesProp, canEdit = false, onOpenCall }) {
  const [plans, setPlans] = useState(null);
  const [sites, setSites] = useState(sitesProp || []);
  const [contractors, setContractors] = useState([]);
  const [edit, setEdit] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [hist, setHist] = useState({});
  const load = useCallback(() => act('pm_plans_list', {}).then((r) => setPlans(customerId ? r.filter((p) => p.customer_id === customerId) : r)).catch((e) => setErr(e.message)), [customerId]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    if (side !== 'store' || !canEdit) return;
    q(supabase.from('sites').select('id, name').order('name')).then(setSites).catch(() => {});
    q(supabase.from('customer_contractors').select('contractor_id, contractors(name)').is('store_removed_at', null).is('contractor_removed_at', null)).then(setContractors).catch(() => {});
  }, [side, canEdit]);
  async function decide(p, ok) {
    setErr(''); setMsg('');
    const note = ok ? null : window.prompt('Why not? (the contractor sees this)');
    if (!ok && !(note && note.trim())) return;
    try { await act('decide_pm_plan', { p_id: p.id, p_accept: ok, p_note: note }); setMsg(ok ? 'Accepted. The PM calls will open by themselves before each due date.' : 'Declined. The contractor is told why.'); load(); }
    catch (x) { setErr(x.message); }
  }
  if (!plans) return <ErrorBox error={err} />;
  return (
    <div className="stack">
      <ErrorBox error={err} /><Notice>{msg}</Notice>
      {edit ? (
        <div className="panel panel-pad stack" style={{ gap: 6 }}>
          <strong>{edit === 'new' ? (side === 'store' ? 'New maintenance plan' : 'Propose a maintenance plan') : `Change: ${edit.name}`}</strong>
          <PlanForm plan={edit === 'new' ? null : edit} side={side} sites={sites} contractors={contractors} onCancel={() => setEdit(null)}
            onSaved={(r) => { setEdit(null); setMsg(r.approval === 'proposed' ? 'Sent. They review it, and you\'re told when they accept.' : 'Saved.'); load(); }} />
        </div>
      ) : canEdit && <div><button className="primary" onClick={() => setEdit('new')}>{side === 'store' ? '+ New maintenance plan' : '+ Propose a maintenance plan'}</button></div>}
      {plans.length === 0 && <div className="small muted">No maintenance plans yet.{side === 'store' ? ' Add one, or ask your contractor to propose them.' : ''}</div>}
      {plans.map((p) => {
        const open = p.open; const pg = open?.progress;
        return (
          <div key={p.id} className={`panel panel-pad stack pm-plan${p.approval === 'proposed' ? ' proposed' : ''}`} style={{ gap: 6 }}>
            <div className="spread" style={{ alignItems: 'flex-start' }}>
              <div>
                <strong>{p.name}</strong>
                <div className="small muted">{p.site}{side === 'store' ? ` · ${p.contractor}` : ` · ${p.customer}`}{p.equipment ? ` · ${p.equipment}` : ''}</div>
              </div>
              <div className="row" style={{ gap: 4 }}>
                {p.approval === 'proposed' && <span className="chip tone-amber">{side === 'store' ? 'Proposed by contractor' : 'Waiting for them'}</span>}
                {p.approval === 'declined' && <span className="chip tone-slate">Declined{p.decided_note ? `: ${p.decided_note}` : ''}</span>}
                {p.approval === 'accepted' && !p.active && <span className="chip tone-slate">Paused</span>}
                {p.approval === 'accepted' && p.active && <span className="chip tone-green">Active</span>}
              </div>
            </div>
            <div className="small">{every(p.frequency_months)} · next due <strong>{date(p.next_due_on)}</strong>
              {' · '}{p.price != null ? `${money(p.price)} per visit` : 'covered / time and materials'}
              {p.expected_hours ? ` · about ${Number(p.expected_hours)} h on site` : ''} · finish within {p.finish_within_days} day{p.finish_within_days === 1 ? '' : 's'} of starting{p.same_tech ? ', same technician' : ''}
              {p.checklist?.length ? ` · ${p.checklist.length}-item checklist` : ''}</div>
            {open && (
              <div className={`small pm-now${pg?.dragging || pg?.tech_changed ? ' bad' : ''}`} onClick={() => onOpenCall?.(open.id)} style={onOpenCall ? { cursor: 'pointer' } : {}}>
                <strong>This PM: #{open.number}</strong>, due {date(open.due_on)}{new Date(`${open.due_on}T23:59:00`) < new Date() ? <strong style={{ color: 'var(--red-fg)' }}> (overdue)</strong> : ''} · <Progress pg={pg} />
              </div>
            )}
            {p.history.length > 0 && (
              <>
                <button className="linkish small" style={{ alignSelf: 'flex-start' }} onClick={() => setHist({ ...hist, [p.id]: !hist[p.id] })}>
                  {hist[p.id] ? 'Hide' : 'Show'} the last {p.history.length} PM{p.history.length === 1 ? '' : 's'}
                  {p.history.some((h) => h.progress?.dragging || h.progress?.tech_changed || h.progress?.on_time === false) ? ' ⚠' : ''}</button>
                {hist[p.id] && (
                  <table><tbody>{p.history.map((h) => (
                    <tr key={h.id} className={onOpenCall ? 'click' : ''} onClick={() => onOpenCall?.(h.id)}>
                      <td className="small">#{h.number}<div className="muted">due {date(h.due_on)}</div></td>
                      <td className="small">{h.progress?.on_time ? <span className="chip tone-green">on time</span> : <span className="chip tone-red">late</span>}{' '}<Progress pg={h.progress} compact /></td>
                    </tr>
                  ))}</tbody></table>
                )}
              </>
            )}
            <div className="row">
              {side === 'store' && p.approval === 'proposed' && canEdit && <>
                <button className="primary" onClick={() => decide(p, true)}>Accept</button><button onClick={() => decide(p, false)}>Decline</button></>}
              {canEdit && (side === 'store' || p.approval !== 'accepted') && <button onClick={() => setEdit(p)}>Change</button>}
              {side === 'contractor' && p.approval === 'accepted' && <span className="small muted">In force. To change it, ask {p.customer}.</span>}
            </div>
          </div>
        );
      })}
    </div>
  );
}
