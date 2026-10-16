'use client';

import { useEffect, useState, useCallback } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money, dateTime, time, FLAG_LABEL, EQUIPMENT_LABEL, PRIORITY } from '@/lib/format';
import { StatusChip, PriorityChip, ErrorBox } from './bits';

const WO_SELECT = `*,
  sites(name, address, access_notes),
  customers(name),
  equipment(type, manufacturer, model, serial, refrigerant, location_description),
  technician:profiles!work_orders_technician_id_fkey(full_name, phone),
  repair_types(name)`;

// Side panel with everything about one service call. `side` is 'store' or 'office'.
export default function CallDetail({ id, side, techs = [], onClose, onChanged }) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [notes, setNotes] = useState({});
  const [techPick, setTechPick] = useState('');

  const load = useCallback(async () => {
    try {
      const [wo, parts, photos, approvals, overrides, flags] = await Promise.all([
        q(supabase.from('work_orders').select(WO_SELECT).eq('id', id).single()),
        q(supabase.from('parts_used').select('id, quantity, unit_price, total_price, source, parts(name, sku)').eq('work_order_id', id)),
        q(supabase.from('photos').select('id, kind, taken_at').eq('work_order_id', id).order('taken_at')),
        q(supabase.from('approvals').select('*').eq('work_order_id', id).order('created_at')),
        q(supabase.from('time_overrides').select('*').eq('work_order_id', id).order('overridden_at')),
        side === 'office'
          ? q(supabase.from('guardrail_flags').select('*').eq('work_order_id', id).order('triggered_at'))
          : Promise.resolve([]),
      ]);
      const cap = wo.po_cap == null ? null :
        Number(wo.po_cap) + approvals.filter((a) => a.status === 'approved').reduce((s, a) => s + Number(a.requested_amount), 0);
      setD({ wo, parts, photos, approvals, overrides, flags, cap });
      setTechPick(wo.technician_id || '');
    } catch (e) {
      setErr(e.message);
    }
  }, [id, side]);

  useEffect(() => { load(); }, [load]);

  async function run(fn, args) {
    setBusy(true);
    setErr('');
    try {
      await act(fn, args);
      await load();
      onChanged && onChanged();
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  const wo = d?.wo;
  const pending = d?.approvals.find((a) => a.status === 'pending');
  const openFlags = d?.flags.filter((f) => !f.resolved_at) || [];

  return (
    <>
      <div className="scrim" onClick={onClose} />
      <aside className="drawer" role="dialog" aria-label="Service call details">
        <div className="drawer-head spread">
          <div className="stack" style={{ gap: 4 }}>
            <div className="row" style={{ gap: 8 }}>
              <h2>Call #{wo?.number ?? '…'}</h2>
              {wo && <StatusChip status={wo.status} />}
              {wo && <PriorityChip priority={wo.priority} />}
            </div>
            {wo && <div className="small muted">{wo.customers?.name} · {wo.sites?.name}</div>}
          </div>
          <button onClick={onClose} aria-label="Close">✕</button>
        </div>

        <div className="drawer-body">
          <ErrorBox error={err} />
          {!d && !err && <div className="muted">Loading…</div>}
          {wo && (
            <>
              {/* Customer approval */}
              {pending && side === 'store' && (
                <div className="panel panel-pad stack" style={{ borderColor: '#e6b3ab' }}>
                  <h3>Approval needed: {money(pending.requested_amount)} more</h3>
                  <div>{pending.reason}</div>
                  <div className="small muted">
                    Your PO cap is {money(wo.po_cap)}. Current cost {money(wo.total_cost)}. Approving raises the cap to {money(Number(d.cap) + Number(pending.requested_amount))}.
                  </div>
                  <div className="row">
                    <button className="primary" disabled={busy} onClick={() => run('decide_approval', { p_approval: pending.id, p_approve: true })}>Approve {money(pending.requested_amount)}</button>
                    <button className="danger" disabled={busy} onClick={() => run('decide_approval', { p_approval: pending.id, p_approve: false })}>Decline</button>
                  </div>
                </div>
              )}
              {pending && side === 'office' && (
                <div className="notice">Waiting on the store to approve {money(pending.requested_amount)} more: {pending.reason}</div>
              )}

              {/* Office: review flags */}
              {side === 'office' && openFlags.length > 0 && (
                <div className="panel panel-pad stack">
                  <h3>Review before invoicing</h3>
                  {openFlags.map((f) => (
                    <div key={f.id} className="stack" style={{ gap: 6, paddingBottom: 10, borderBottom: '1px solid var(--line)' }}>
                      <div className="row" style={{ gap: 8 }}>
                        <span className={`chip ${f.blocking ? 'tone-red' : 'tone-amber'}`}>{FLAG_LABEL[f.flag] || f.flag}</span>
                        {!f.blocking && <span className="small muted">info only</span>}
                      </div>
                      <div className="small">{f.description}</div>
                      {f.blocking && (
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

              {/* Office: assign */}
              {side === 'office' && ['created', 'assigned', 'en_route'].includes(wo.status) && (
                <div className="panel panel-pad row">
                  <select className="grow" value={techPick} onChange={(e) => setTechPick(e.target.value)}>
                    <option value="">Choose technician…</option>
                    {techs.map((t) => <option key={t.id} value={t.id}>{t.full_name}</option>)}
                  </select>
                  <button className="primary" disabled={busy || !techPick || techPick === wo.technician_id}
                    onClick={() => run('assign_work_order', { p_wo: wo.id, p_tech: techPick })}>
                    {wo.technician_id ? 'Reassign' : 'Assign'}
                  </button>
                </div>
              )}

              {/* Office: invoice */}
              {side === 'office' && wo.status === 'completed' && (
                <div className="panel panel-pad spread">
                  <div className="small">
                    {wo.invoice_ready ? 'Ready to invoice.' : 'Resolve the review items above to invoice.'}
                    <div className="muted">QuickBooks connection comes in a later phase; for now record the invoice number.</div>
                  </div>
                  <button className="primary" disabled={busy || !wo.invoice_ready} onClick={() => {
                    const n = window.prompt('QuickBooks invoice number for this call:');
                    if (n && n.trim()) run('mark_exported', { p_wo: wo.id, p_qbo_invoice_id: n.trim() });
                  }}>Mark invoiced</button>
                </div>
              )}

              {/* What happened */}
              <div className="panel panel-pad stack">
                <h3>Problem reported</h3>
                <div>{wo.issue_description}</div>
                {wo.work_summary && (
                  <>
                    <h3 style={{ marginTop: 6 }}>Work performed</h3>
                    <div>{wo.work_summary}</div>
                  </>
                )}
              </div>

              <div className="panel panel-pad">
                <h3 style={{ marginBottom: 8 }}>Timeline</h3>
                <ul className="timeline">
                  <Step done label="Call opened" at={wo.created_at} />
                  <Step done={!!wo.assigned_at} label={wo.technician ? `Assigned to ${wo.technician.full_name}` : 'Assigned'} at={wo.assigned_at} />
                  <Step done={!!wo.started_at} label="On the way" at={wo.started_at}
                    extra={wo.status === 'en_route' && wo.eta_at ? `ETA ${time(wo.eta_at)}` : null} />
                  <Step done={!!wo.arrived_at} label="Arrived on site (GPS)" at={wo.arrived_at} />
                  <Step done={!!wo.completed_at} label="Work completed" at={wo.completed_at} />
                  <Step done={!!wo.departed_at} label="Left site (GPS)" at={wo.departed_at} />
                  {wo.status === 'invoiced' && <Step done label={`Invoiced (${wo.qbo_invoice_id})`} at={wo.exported_at} />}
                </ul>
                {d.overrides.length > 0 && (
                  <div className="notice" style={{ marginTop: 8 }}>
                    {d.overrides.map((o) => (
                      <div key={o.id} className="small">
                        Time corrected: {o.field.replace('_at', '').replace('_', ' ')} {dateTime(o.old_value)} → {dateTime(o.new_value)}. Reason: {o.reason}
                      </div>
                    ))}
                  </div>
                )}
              </div>

              <div className="panel panel-pad">
                <h3 style={{ marginBottom: 8 }}>Equipment</h3>
                {wo.equipment ? (
                  <dl className="kv">
                    <dt>Unit</dt><dd style={{ textTransform: 'capitalize' }}>{EQUIPMENT_LABEL(wo.equipment.type)}</dd>
                    <dt>Make / model</dt><dd>{wo.equipment.manufacturer} {wo.equipment.model}</dd>
                    <dt>Serial</dt><dd>{wo.equipment.serial}</dd>
                    {wo.equipment.refrigerant && (<><dt>Refrigerant</dt><dd>{wo.equipment.refrigerant}</dd></>)}
                    <dt>Location</dt><dd>{wo.equipment.location_description || '—'}</dd>
                  </dl>
                ) : <div className="muted small">Technician will photograph the nameplate on site.</div>}
              </div>

              {d.photos.length > 0 && (
                <div className="panel panel-pad">
                  <h3 style={{ marginBottom: 8 }}>Photos ({d.photos.length})</h3>
                  <div className="photos">
                    {d.photos.map((p) => <div key={p.id} className="photo-ph">{p.kind}</div>)}
                  </div>
                  <div className="small muted" style={{ marginTop: 6 }}>Photo viewing turns on with the technician app.</div>
                </div>
              )}

              <div className="panel panel-pad">
                <h3 style={{ marginBottom: 8 }}>Cost</h3>
                <table>
                  <tbody>
                    {d.parts.map((p) => (
                      <tr key={p.id}>
                        <td>{p.parts?.name}<div className="small muted">{p.parts?.sku} · qty {Number(p.quantity)}</div></td>
                        <td className="num">{money(p.total_price)}</td>
                      </tr>
                    ))}
                    {wo.arrived_at && (
                      <tr>
                        <td>Labor<div className="small muted">{(wo.labor_minutes_billed / 60).toFixed(2)} hr billed</div></td>
                        <td className="num">{money(wo.total_labor)}</td>
                      </tr>
                    )}
                    {Number(wo.total_trip) > 0 && <tr><td>Trip charge</td><td className="num">{money(wo.total_trip)}</td></tr>}
                    <tr><td><strong>Total</strong></td><td className="num"><strong>{money(wo.total_cost)}</strong></td></tr>
                  </tbody>
                </table>
                {wo.po_cap != null && (
                  <div className="small muted" style={{ marginTop: 8 }}>
                    PO {wo.po_number || '(no number)'} · approved up to {money(d.cap)}
                  </div>
                )}
              </div>

              <div className="panel panel-pad">
                <dl className="kv">
                  <dt>Site</dt><dd>{wo.sites?.name}<div className="small muted">{wo.sites?.address}</div></dd>
                  {wo.sites?.access_notes && (<><dt>Access</dt><dd>{wo.sites.access_notes}</dd></>)}
                  <dt>Technician</dt><dd>{wo.technician ? `${wo.technician.full_name}${wo.technician.phone ? ' · ' + wo.technician.phone : ''}` : 'Not assigned yet'}</dd>
                  <dt>Priority</dt><dd>{PRIORITY[wo.priority]}</dd>
                  {wo.repair_types && (<><dt>Repair</dt><dd>{wo.repair_types.name}</dd></>)}
                </dl>
              </div>

              {['created', 'assigned'].includes(wo.status) && (
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

function Step({ done, label, at, extra }) {
  return (
    <li className={done ? 'done' : ''}>
      <span className="dot" />
      <span>{label}{extra ? <span className="muted"> · {extra}</span> : null}</span>
      <span className="when">{done ? dateTime(at) : ''}</span>
    </li>
  );
}
