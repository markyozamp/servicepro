'use client';

import { useEffect, useState, useCallback } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money, dateTime, time, date, FLAG_LABEL, PRIORITY, KIND, PO_KIND, poLabel, daysUntil } from '@/lib/format';
import { StatusChip, PriorityChip, KindChip, ErrorBox, Notice } from './bits';

const WO = `*, sites(name, address, access_notes, timezone, property_type), customers(name, kind, phone),
  equipment(id, manufacturer, model, serial, refrigerant, location_description, equipment_types(name)),
  repair_types(name), agreements(name, coverage, response_emergency_min, response_normal_min), issue_types(name)`;

// Everything about one job. side = 'store' | 'office'
export default function CallDetail({ id, side, techs = [], profile, onClose, onChanged }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  const [notes, setNotes] = useState({});
  const [techPick, setTechPick] = useState('');
  const [termPick, setTermPick] = useState('');

  const load = useCallback(async () => {
    try {
      const wo = await q(supabase.from('work_orders').select(WO).eq('id', id).single());
      const [visits, lines, parts, orders, photos, overrides, flags, warranties, codes, terms] = await Promise.all([
        q(supabase.from('visits').select('*, profiles(full_name, phone)').eq('work_order_id', id).order('visit_no')),
        q(supabase.from('po_lines').select('*, decider:profiles!po_lines_decided_by_fkey(full_name, title), owner:property_owners(name, phone, email)').eq('work_order_id', id).order('seq')),
        q(supabase.from('parts_used').select('id, quantity, unit_price, total_price, covered, parts(name, sku)').eq('work_order_id', id)),
        q(supabase.from('parts_orders').select('*').eq('work_order_id', id).order('created_at')),
        q(supabase.from('photos').select('id, kind, taken_at, storage_path').eq('work_order_id', id).order('taken_at')),
        q(supabase.from('time_overrides').select('*').eq('work_order_id', id).order('overridden_at')),
        q(supabase.from('guardrail_flags').select('*').eq('work_order_id', id).order('triggered_at')),
        wo.equipment ? q(supabase.from('warranties').select('*').eq('equipment_id', wo.equipment.id).gte('ends_on', new Date().toISOString().slice(0, 10)).order('ends_on')) : Promise.resolve([]),
        side === 'store' ? q(supabase.from('visit_codes').select('visit_id, code')) : Promise.resolve([]),
        side === 'office' ? q(supabase.from('warranty_terms').select('id, name').order('sort')) : Promise.resolve([]),
      ]);
      const cap = lines.length ? lines.filter((l) => l.status === 'approved').reduce((s, l) => s + Number(l.amount), 0) : null;
      const urls = {};
      const real = photos.filter((p) => p.storage_path && !p.storage_path.startsWith('demo/'));
      if (real.length) {
        const { data: signed } = await supabase.storage.from('job-photos').createSignedUrls(real.map((p) => p.storage_path), 3600);
        (signed || []).forEach((x, i) => { if (x.signedUrl) urls[real[i].id] = x.signedUrl; });
      }
      setD({ wo, visits, lines, parts, orders, photos, overrides, flags, warranties, codes, terms, cap, urls });
    } catch (e) {
      setErr(e.message);
    }
  }, [id, side]);

  useEffect(() => { load(); }, [load]);

  async function run(fn, args, after) {
    setBusy(true); setErr(''); setMsg('');
    try {
      const r = await act(fn, args);
      if (r && r.escalated) setMsg(r.message);
      if (after) after(r);
      await load();
      onChanged && onChanged();
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  const wo = d?.wo;
  const pending = d?.lines.find((l) => l.status === 'pending');
  const openFlags = d?.flags.filter((f) => !f.resolved_at) || [];
  const activeVisit = d?.visits.filter((v) => v.status !== 'cancelled').slice(-1)[0];
  const code = activeVisit && d?.codes.find((c) => c.visit_id === activeVisit.id);
  const openOrders = d?.orders.filter((o) => ['needed', 'ordered'].includes(o.status)) || [];
  const canApprove = side === 'store' && profile?.can_approve;
  const ownerWait = pending?.owner_status === 'pending';
  const oneOff = wo?.customers?.kind === 'residential';

  async function copyLink(line, who) {
    setBusy(true); setErr(''); setMsg('');
    try {
      const tok = await act('approval_link', { p_line: line.id });
      const url = `${window.location.origin}/approve/${tok}`;
      try { await navigator.clipboard.writeText(url); setMsg(`Link copied. Text or email it to ${who}: ${url}`); }
      catch { window.prompt(`Copy this link and send it to ${who}:`, url); }
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  function recordPhone(line, who) {
    const yes = window.confirm(`Did ${who} APPROVE ${money(line.amount)}?\n\nOK = approved · Cancel = declined`);
    const note = window.prompt(`Note who you spoke to and when (e.g. "${who} OK'd by phone 2:10 pm"):`);
    if (note && note.trim()) run('record_phone_approval', { p_line: line.id, p_approve: yes, p_note: note.trim() });
  }

  return (
    <>
      <div className="scrim" onClick={onClose} />
      <aside className="drawer" role="dialog" aria-label="Service call details">
        <div className="drawer-head spread">
          <div className="stack" style={{ gap: 4 }}>
            <div className="row" style={{ gap: 8 }}>
              <h2>{wo?.kind === 'pm' ? 'PM' : 'Call'} #{wo?.number ?? '…'}</h2>
              {wo && <StatusChip status={wo.status} />}
              {wo && <PriorityChip priority={wo.priority} />}
              {wo && <KindChip kind={wo.kind} />}
            </div>
            {wo && <div className="small muted">{wo.customers?.name} · {wo.sites?.name}{wo.unit ? `, unit ${wo.unit}` : ''}{wo.agreements ? ` · ${wo.agreements.name}` : ''}</div>}
          </div>
          <button onClick={onClose} aria-label="Close">✕</button>
        </div>

        <div className="drawer-body">
          <ErrorBox error={err} />
          <Notice>{msg}</Notice>
          {!d && !err && <div className="muted">Loading…</div>}
          {wo && (
            <>
              {/* ---- Store: approval ---- */}
              {pending && side === 'store' && (
                <div className="panel panel-pad stack" style={{ borderColor: '#e6b3ab' }}>
                  <h3>Approval needed: {poLabel(wo, pending.seq)} — not to exceed {money(pending.amount)}</h3>
                  <div><span className="chip tone-slate">{PO_KIND[pending.kind]}</span> {pending.description}</div>
                  {pending.breakdown && <QuoteBreakdown b={pending.breakdown} />}
                  <div className="small muted">
                    Approved limit so far {money(d.cap)}. Approving raises the limit to {money(Number(d.cap) + Number(pending.amount))}. You're billed actual labor and parts, never more than the limit without asking you.
                    {profile?.approval_limit != null && ` Your limit is ${money(profile.approval_limit)}.`}
                  </div>
                  {ownerWait ? (
                    <div className="stack" style={{ gap: 8 }}>
                      <div><span className="chip tone-amber">Waiting on owner</span> You approved this. It is over the owner's limit, so <strong>{pending.owner?.name}</strong> must OK it.
                        {pending.owner?.phone && <span className="muted"> · {pending.owner.phone}</span>}</div>
                      {canApprove && (
                        <div className="row">
                          <button className="primary" disabled={busy} onClick={() => copyLink(pending, pending.owner?.name || 'the owner')}>Copy owner approval link</button>
                          <button disabled={busy} onClick={() => recordPhone(pending, pending.owner?.name || 'the owner')}>Owner answered by phone</button>
                        </div>
                      )}
                    </div>
                  ) : canApprove ? (
                    <div className="row">
                      <button className="primary" disabled={busy} onClick={() => run('decide_po_line', { p_line: pending.id, p_approve: true })}>
                        Approve up to {money(pending.amount)}
                      </button>
                      <button className="danger" disabled={busy} onClick={() => {
                        const r = window.prompt('Reason for declining (the contractor will see this):');
                        if (r !== null) run('decide_po_line', { p_line: pending.id, p_approve: false, p_reason: r });
                      }}>Decline</button>
                    </div>
                  ) : <div className="small muted">You can see this request but are not set up to approve spending.</div>}
                </div>
              )}
              {pending && side === 'office' && (
                <div className="panel panel-pad stack" style={{ gap: 8 }}>
                  <div>
                    <span className="chip tone-amber">{ownerWait ? 'Waiting on building owner' : oneOff ? 'Waiting on homeowner' : 'Waiting on customer'}</span>{' '}
                    {poLabel(wo, pending.seq)} {money(pending.amount)} — {pending.description}
                  </div>
                  {ownerWait && <div className="small muted">The property manager approved it; {pending.owner?.name || 'the owner'} must OK it too.</div>}
                  {oneOff && !ownerWait && (
                    <div className="row">
                      <button className="primary" disabled={busy} onClick={() => copyLink(pending, wo.contact_name || wo.customers?.name)}>Copy approval link for homeowner</button>
                      <button disabled={busy} onClick={() => recordPhone(pending, wo.contact_name || wo.customers?.name)}>Homeowner answered by phone</button>
                    </div>
                  )}
                </div>
              )}

              {/* ---- Store: check-in code ---- */}
              {side === 'store' && code && activeVisit && !activeVisit.checkin_verified && activeVisit.status !== 'done' && (
                <div className="panel panel-pad spread">
                  <div>
                    <h3>Check-in code</h3>
                    <div className="small muted">Read this to the technician when they arrive. Don't share it before.</div>
                  </div>
                  <div style={{ fontSize: 34, fontWeight: 800, letterSpacing: 8 }}>{code.code}</div>
                </div>
              )}

              {/* ---- Flags (store sees only the ones meant for it) ---- */}
              {openFlags.length > 0 && (
                <div className="panel panel-pad stack">
                  <h3>{side === 'office' ? 'Review before invoicing' : 'Heads-up'}</h3>
                  {openFlags.map((f) => (
                    <div key={f.id} className="stack" style={{ gap: 6, paddingBottom: 10, borderBottom: '1px solid var(--line)' }}>
                      <div className="row" style={{ gap: 8 }}>
                        <span className={`chip ${f.blocking ? 'tone-red' : 'tone-amber'}`}>{FLAG_LABEL[f.flag] || f.flag}</span>
                        {side === 'office' && !f.blocking && <span className="small muted">info only</span>}
                      </div>
                      <div className="small">{f.description}</div>
                      {side === 'office' && f.blocking && f.flag !== 'billing_late' && (
                        <div className="row">
                          <input className="grow" placeholder="Note: why this is OK / what you changed"
                            value={notes[f.id] || ''} onChange={(e) => setNotes({ ...notes, [f.id]: e.target.value })} />
                          <button disabled={busy || !(notes[f.id] || '').trim()} onClick={() => run('resolve_flag', { p_flag: f.id, p_note: notes[f.id] })}>Resolve</button>
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              )}

              {/* ---- Office: dispatch ---- */}
              {side === 'office' && ['created', 'assigned', 'en_route', 'waiting_parts', 'return_needed', 'awaiting_approval'].includes(wo.status)
                && !d.visits.some((v) => v.status === 'on_site') && (
                <div className="panel panel-pad stack">
                  <div className="row">
                    <select className="grow" value={techPick} onChange={(e) => setTechPick(e.target.value)}>
                      <option value="">Choose technician…</option>
                      {techs.map((t) => <option key={t.id} value={t.id}>{t.full_name}</option>)}
                    </select>
                    <button className="primary" disabled={busy || !techPick} onClick={() => run('assign_work_order', { p_wo: wo.id, p_tech: techPick })}>
                      {['waiting_parts', 'return_needed', 'awaiting_approval'].includes(wo.status) ? 'Schedule return visit'
                        : activeVisit && activeVisit.status !== 'done' ? 'Reassign' : 'Assign'}
                    </button>
                  </div>
                  {wo.status === 'waiting_parts' && <div className="small muted">Parts are still on order. You can schedule the return now or mark parts received below.</div>}
                </div>
              )}

              {/* ---- Parts on order ---- */}
              {d.orders.length > 0 && (
                <div className="panel panel-pad stack">
                  <h3>Parts {openOrders.length ? 'on order' : 'ordered'}</h3>
                  {d.orders.map((o) => (
                    <div key={o.id} className="spread small" style={{ borderBottom: '1px solid var(--line)', paddingBottom: 6 }}>
                      <div>
                        <strong>{o.description}</strong> × {Number(o.quantity)}
                        <div className="muted">{o.supplier || 'Supplier not set'} · {o.status === 'received' ? `received ${date(o.received_at)}` : `expected ${o.expected_on ? date(o.expected_on) : '—'}`}</div>
                      </div>
                      {side === 'office' && ['needed', 'ordered'].includes(o.status) && (
                        <div className="row" style={{ gap: 6 }}>
                          <button disabled={busy} onClick={() => {
                            const dt = window.prompt('New expected date (YYYY-MM-DD):', o.expected_on || '');
                            if (dt) run('update_parts_order', { p_order: o.id, p_status: 'ordered', p_expected_on: dt });
                          }}>Change date</button>
                          <button className="primary" disabled={busy} onClick={() => run('update_parts_order', { p_order: o.id, p_status: 'received' })}>Received</button>
                        </div>
                      )}
                      {side === 'store' && <span className={`chip ${o.status === 'received' ? 'tone-green' : 'tone-amber'}`}>{o.status}</span>}
                    </div>
                  ))}
                </div>
              )}

              {/* ---- Office: closeout ---- */}
              {side === 'office' && ['completed', 'invoiced'].includes(wo.status) && wo.equipment && (
                <div className="panel panel-pad stack">
                  <h3>Warranty</h3>
                  <div className="row">
                    <select className="grow" value={termPick} onChange={(e) => setTermPick(e.target.value)}>
                      <option value="">Choose warranty…</option>
                      {d.terms.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                    </select>
                    <button disabled={busy || !termPick} onClick={() => run('set_warranty', { p_wo: wo.id, p_term: termPick })}>Set warranty</button>
                  </div>
                </div>
              )}
              {side === 'office' && wo.status === 'completed' && (
                <div className="panel panel-pad spread">
                  <div className="small">
                    {wo.invoice_ready ? 'Ready to invoice.' : 'Resolve the review items above to invoice.'}
                    <div className={daysUntil(wo.invoice_due_at) < 0 ? '' : 'muted'} style={daysUntil(wo.invoice_due_at) < 0 ? { color: 'var(--red-fg)', fontWeight: 700 } : {}}>
                      Invoice due {date(wo.invoice_due_at)}{daysUntil(wo.invoice_due_at) < 0 ? ' — LATE (the store has been told)' : ''}
                    </div>
                  </div>
                  <button className="primary" disabled={busy || !wo.invoice_ready} onClick={() => {
                    const n = window.prompt('QuickBooks invoice number:');
                    if (n && n.trim()) run('mark_invoiced', { p_wo: wo.id, p_invoice_id: n.trim() });
                  }}>Mark invoiced</button>
                </div>
              )}

              {/* ---- Store: bill pending ---- */}
              {side === 'store' && wo.status === 'completed' && (
                <Notice>Work complete. Bill pending — about <strong>{money(wo.total_cost)}</strong>. The contractor must send the invoice by {date(wo.invoice_due_at)}.</Notice>
              )}

              {/* ---- Warranty heads-up ---- */}
              {d.warranties.length > 0 && wo.status !== 'invoiced' && wo.status !== 'completed' && (
                <Notice>
                  <strong>Under warranty:</strong>{' '}
                  {d.warranties.map((w) => `${w.kind} until ${date(w.ends_on)} (${w.description})`).join('; ')}
                  {wo.warranty_claim === false && <div>Contractor says not covered: {wo.warranty_decline_reason}</div>}
                </Notice>
              )}

              {/* ---- The story ---- */}
              <div className="panel panel-pad stack">
                <h3>{wo.kind === 'pm' ? 'Maintenance' : 'Problem reported'}</h3>
                <div>{wo.issue_types?.name && wo.issue_types.name !== wo.issue_description ? <strong>{wo.issue_types.name}. </strong> : null}{wo.issue_description}</div>
                {wo.work_summary && (<><h3 style={{ marginTop: 6 }}>Work performed</h3><div>{wo.work_summary}</div></>)}
                {wo.kind === 'pm' && Array.isArray(wo.checklist) && wo.checklist.length > 0 && (
                  <ul className="timeline">
                    {wo.checklist.map((c, i) => {
                      const r = wo.checklist_results?.[String(i)];
                      return (
                        <li key={i} className={r?.done ? 'done' : ''}>
                          <span className="dot" /><span>{c.item}{r?.reading ? <strong> — {r.reading}</strong> : null}</span>
                          <span className="when">{r?.done ? '✓' : ''}</span>
                        </li>
                      );
                    })}
                  </ul>
                )}
              </div>

              {/* ---- Visits ---- */}
              <div className="panel panel-pad stack">
                <h3>Visits</h3>
                <ul className="timeline">
                  <Step done label={wo.kind === 'pm' ? `PM scheduled (due ${date(wo.due_on)})` : 'Call opened'} at={wo.created_at} />
                  {wo.response_due_at && (
                    <li className={wo.response_met == null ? '' : 'done'}>
                      <span className="dot" />
                      <span>Response time: arrive by {dateTime(wo.response_due_at)}
                        {wo.response_met === true && <span className="chip tone-green" style={{ marginLeft: 6 }}>met</span>}
                        {wo.response_met === false && <span className="chip tone-red" style={{ marginLeft: 6 }}>missed</span>}
                      </span>
                    </li>
                  )}
                </ul>
                {d.visits.length === 0 && <div className="small muted">No technician assigned yet.</div>}
                {d.visits.map((v) => (
                  <div key={v.id} className="stack" style={{ gap: 4, borderTop: '1px solid var(--line)', paddingTop: 8, opacity: v.status === 'cancelled' ? 0.5 : 1 }}>
                    <div className="spread">
                      <strong>Visit {v.visit_no} · {v.profiles?.full_name}</strong>
                      <span className="small muted">{v.status === 'cancelled' ? 'reassigned' : v.outcome ? v.outcome.replace('_', ' ') : v.status.replace('_', ' ')}</span>
                    </div>
                    <ul className="timeline">
                      <Step done label="Assigned" at={v.assigned_at} extra={!v.received_at && v.status === 'assigned' ? 'not yet received by tech' : null} />
                      <Step done={!!v.started_at} label="On the way" at={v.started_at} extra={v.status === 'en_route' && v.eta_at ? `ETA ${time(v.eta_at)}` : null} />
                      <Step done={!!v.arrived_at} label="Arrived (GPS)" at={v.arrived_at} />
                      {v.checkin_required && (
                        <Step done={!!v.checkin_at} label={v.checkin_at ? (v.checkin_verified ? `Checked in (${v.checkin_method === 'backup_code' ? 'backup code' : 'code'})` : 'Check-in NOT verified') : 'Check-in with store'} at={v.checkin_at}
                          extra={v.checkin_person ? `met ${v.checkin_person}` : null} />
                      )}
                      <Step done={!!v.completed_at} label={v.outcome === 'parts_needed' ? 'Left — parts needed' : v.outcome === 'return_needed' ? 'Left — return needed' : v.outcome === 'quote_needed' ? 'Left — quote sent' : 'Work completed'} at={v.completed_at} />
                      <Step done={!!v.departed_at} label="Left site (GPS)" at={v.departed_at} />
                    </ul>
                    {v.outcome_note && v.status !== 'cancelled' && <div className="small muted">{v.outcome_note}</div>}
                  </div>
                ))}
                {d.overrides.length > 0 && (
                  <Notice>
                    {d.overrides.map((o) => (
                      <div key={o.id} className="small">Time corrected: {o.field.replace('_at', '').replace('_', ' ')} {dateTime(o.old_value)} → {dateTime(o.new_value)}. Reason: {o.reason}</div>
                    ))}
                  </Notice>
                )}
              </div>

              {/* ---- PO ---- */}
              <div className="panel panel-pad">
                <h3 style={{ marginBottom: 8 }}>Purchase order</h3>
                {d.lines.length === 0 ? <div className="small muted">No spending limit on this call.</div> : (
                  <table>
                    <tbody>
                      {d.lines.map((l) => (
                        <tr key={l.id}>
                          <td><strong>{poLabel(wo, l.seq)}</strong><div className="small muted">{PO_KIND[l.kind]}</div></td>
                          <td className="small">{l.description}
                            {l.decider && <div className="muted">{l.owner_status === 'approved' || l.owner_status === 'declined' ? 'manager approved' : l.status} by {l.decider.full_name}{l.decider.title ? `, ${l.decider.title}` : ''} · {dateTime(l.manager_approved_at || l.decided_at)}</div>}
                            {(l.owner_status === 'approved' || l.owner_status === 'declined') && <div className="muted">owner ({l.owner?.name}) {l.owner_status}{l.owner_decided_via === 'phone' ? ' by phone' : ' by link'} · {dateTime(l.owner_decided_at)}{l.owner_note ? ` — “${l.owner_note}”` : ''}</div>}
                            {l.owner_status === 'pending' && <div className="muted">manager approved · waiting on owner ({l.owner?.name}) since {dateTime(l.owner_requested_at)}</div>}
                            {l.owner_status === 'emergency' && <div className="muted">emergency — approved without waiting; owner ({l.owner?.name}) to be told</div>}
                            {l.emergency_preapproved && <div className="muted">went ahead under the pre-approved emergency limit</div>}
                            {l.customer_decided_via && <div className="muted">{l.status} by {wo.contact_name || wo.customers?.name} {l.customer_decided_via === 'link' ? 'by link' : 'by phone'} · {dateTime(l.decided_at)}</div>}
                            {l.decline_reason && <div className="muted">Reason: {l.decline_reason}</div>}
                          </td>
                          <td className="num">
                            {money(l.amount)}
                            <div><span className={`chip ${l.status === 'approved' ? 'tone-green' : l.status === 'declined' ? 'tone-slate' : 'tone-red'}`}>{l.status}</span></div>
                          </td>
                        </tr>
                      ))}
                      <tr><td colSpan={2}><strong>Approved limit</strong> <span className="small muted">(not to exceed)</span></td><td className="num"><strong>{money(d.cap)}</strong></td></tr>
                    </tbody>
                  </table>
                )}
                {side === 'office' && !pending && !['completed', 'invoiced', 'cancelled'].includes(wo.status) && (
                  <button style={{ marginTop: 10 }} disabled={busy} onClick={() => {
                    const amt = window.prompt('Additional amount needed ($):');
                    if (!amt) return;
                    const why = window.prompt('What is it for? (the customer sees this)');
                    if (why) run('request_po_line', { p_wo: wo.id, p_kind: d.lines.some((l) => l.kind === 'repair') ? 'additional' : 'repair', p_amount: Number(amt), p_description: why });
                  }}>Request approval for more</button>
                )}
              </div>

              {/* ---- Cost ---- */}
              <div className="panel panel-pad">
                <h3 style={{ marginBottom: 8 }}>Cost {wo.status === 'completed' || wo.status === 'invoiced' ? '' : 'so far'}</h3>
                <table>
                  <tbody>
                    {Number(wo.flat_amount) > 0 && <tr><td>Preventive maintenance visit (flat)</td><td className="num">{money(wo.flat_amount)}</td></tr>}
                    {d.parts.map((p) => (
                      <tr key={p.id}>
                        <td>{p.parts?.name}<div className="small muted">{p.parts?.sku} · qty {Number(p.quantity)}{p.covered ? ' · covered' : ''}</div></td>
                        <td className="num">{money(p.total_price)}</td>
                      </tr>
                    ))}
                    {d.visits.some((v) => v.arrived_at) && (
                      <tr><td>Labor<div className="small muted">{(wo.labor_minutes_billed / 60).toFixed(2)} hr{Number(wo.total_labor) === 0 ? ' · covered' : ''}</div></td>
                        <td className="num">{money(wo.total_labor)}</td></tr>
                    )}
                    {Number(wo.total_trip) > 0 && <tr><td>Trip charge</td><td className="num">{money(wo.total_trip)}</td></tr>}
                    <tr><td><strong>Actual cost{wo.status === 'completed' || wo.status === 'invoiced' ? '' : ' so far'}</strong>
                      {d.cap != null && <div className={`small ${Number(wo.total_cost) > Number(d.cap) ? '' : 'muted'}`} style={Number(wo.total_cost) > Number(d.cap) ? { color: 'var(--red-fg)', fontWeight: 700 } : {}}>
                        {Number(wo.total_cost) > Number(d.cap) ? `Over the ${money(d.cap)} limit — needs approval` : `${money(Number(d.cap) - Number(wo.total_cost))} under the ${money(d.cap)} limit`}</div>}</td>
                      <td className="num"><strong>{money(wo.total_cost)}</strong></td></tr>
                    {side === 'office' && (Number(wo.cost_labor) + Number(wo.cost_parts) > 0) && (
                      <tr><td className="small muted">Your cost (labor + parts) · margin</td>
                        <td className="num small muted">{money(Number(wo.cost_labor) + Number(wo.cost_parts))} · {money(Number(wo.total_cost) - Number(wo.cost_labor) - Number(wo.cost_parts))}</td></tr>
                    )}
                  </tbody>
                </table>
              </div>

              {/* ---- Equipment & photos ---- */}
              <div className="panel panel-pad">
                <h3 style={{ marginBottom: 8 }}>Equipment</h3>
                {wo.equipment ? (
                  <dl className="kv">
                    <dt>Unit</dt><dd>{wo.equipment.equipment_types?.name}</dd>
                    <dt>Make / model</dt><dd>{wo.equipment.manufacturer} {wo.equipment.model}</dd>
                    <dt>Serial</dt><dd>{wo.equipment.serial}</dd>
                    {wo.equipment.refrigerant && (<><dt>Refrigerant</dt><dd>{wo.equipment.refrigerant}</dd></>)}
                    <dt>Location</dt><dd>{wo.equipment.location_description || '—'}</dd>
                  </dl>
                ) : <div className="small muted">The technician will photograph the nameplate on site.</div>}
                {d.photos.length > 0 && (
                  <div className="photos" style={{ marginTop: 10 }}>
                    {d.photos.map((p) => d.urls[p.id]
                      ? <a key={p.id} href={d.urls[p.id]} target="_blank" rel="noreferrer" className="photo-ph" style={{ background: `center/cover url(${d.urls[p.id]})`, color: '#fff', textShadow: '0 1px 2px #000' }}>{p.kind}</a>
                      : <div key={p.id} className="photo-ph">{p.kind}</div>)}
                  </div>
                )}
              </div>

              <div className="panel panel-pad">
                <dl className="kv">
                  <dt>Type</dt><dd>{KIND[wo.kind]}</dd>
                  <dt>Site</dt><dd>{wo.sites?.name}{wo.unit ? ` — unit ${wo.unit}` : ''}<div className="small muted">{wo.sites?.address}</div></dd>
                  {(wo.contact_name || wo.contact_phone) && (<><dt>{oneOff ? 'Homeowner' : 'Meet'}</dt><dd>{wo.contact_name}{wo.contact_phone ? <div className="small"><a href={`tel:${wo.contact_phone}`}>{wo.contact_phone}</a></div> : null}</dd></>)}
                  {wo.entry_notes && (<><dt>Entry</dt><dd>{wo.entry_notes}</dd></>)}
                  {wo.sites?.access_notes && (<><dt>Access</dt><dd>{wo.sites.access_notes}</dd></>)}
                  <dt>Priority</dt><dd>{PRIORITY[wo.priority]}{wo.after_hours ? ' · after hours' : ''}</dd>
                  {wo.repair_types && (<><dt>Repair</dt><dd>{wo.repair_types.name}</dd></>)}
                </dl>
              </div>

              {['created', 'assigned'].includes(wo.status) && (side === 'office' || profile?.can_open_calls || profile?.is_org_admin) && (
                <button className="danger" disabled={busy} onClick={() => {
                  const r = window.prompt('Reason for cancelling this call:');
                  if (r && r.trim()) run('cancel_work_order', { p_wo: wo.id, p_reason: r.trim() });
                }}>Cancel this call</button>
              )}
            </>
          )}
        </div>
      </aside>
    </>
  );
}

function QuoteBreakdown({ b }) {
  if (!b) return null;
  return (
    <div className="small" style={{ background: 'var(--bg)', borderRadius: 8, padding: 8 }}>
      {Array.isArray(b.parts) && b.parts.map((p, i) => <div key={i}>{p.name} × {p.qty ?? 1}{p.price != null ? ` — ${money(p.price)}` : ''}</div>)}
      {b.labor_hours != null && <div>Labor: up to {b.labor_hours} hr{b.labor != null ? ` — ${money(b.labor)}` : ''}</div>}
      {b.notes && <div className="muted">{b.notes}</div>}
    </div>
  );
}

function Step({ done, label, at, extra }) {
  return (
    <li className={done ? 'done' : ''}>
      <span className="dot" />
      <span>{label}{extra ? <span className="muted"> · {extra}</span> : null}</span>
      <span className="when">{done && at ? dateTime(at) : ''}</span>
    </li>
  );
}
