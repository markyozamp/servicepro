'use client';

// Time Verify on a call: acceptance, confirming contractor-entered calls, verified hours and the invoice check.
import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money, dateTime, time, date } from '@/lib/format';

const h = (n) => (n == null ? '—' : `${Number(n).toFixed(2)} h`);
const hm = (m) => `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, '0')} m`;

export function VerifyPanel({ wo, side, profile, busy, run: runOuter }) {
  const [chk, setChk] = useState(null);
  const [runs, setRuns] = useState([]);
  const [contractors, setContractors] = useState([]);
  const [sched, setSched] = useState(null);
  const [po, setPo] = useState('');
  const [reroute, setReroute] = useState('');

  const load = useCallback(async () => {
    try {
      const [c, r] = await Promise.all([
        act('invoice_check', { p_wo: wo.id }),
        q(supabase.from('parts_runs').select('*').eq('work_order_id', wo.id).order('left_at')),
      ]);
      setChk(c); setRuns(r);
      if (side === 'store') {
        setContractors(await q(supabase.from('customer_contractors').select('contractor_id, mode, contractors(name)').eq('customer_id', wo.customer_id)));
      }
    } catch { /* shown elsewhere */ }
  }, [wo.id, wo.customer_id, side]);
  useEffect(() => { load(); }, [load, wo.status, wo.updated_at]);
  // After any action here, refresh this panel too (an invoice change doesn't touch the call itself)
  const run = (fn, args, after) => runOuter(fn, args, (r) => { if (after) after(r); setTimeout(load, 300); });

  const office = side === 'office';
  const isStoreAdmin = side === 'store' && (profile?.can_open_calls || profile?.is_org_admin);
  const billingStore = side === 'store' && (profile?.can_see_billing || profile?.can_approve || profile?.is_org_admin);
  const closed = ['completed', 'invoiced', 'cancelled'].includes(wo.status);
  const late = !wo.accepted_at && !wo.declined_at && wo.accept_due_at && new Date(wo.accept_due_at) < new Date();
  const noVisit = !(chk?.visits || []).length && ['created'].includes(wo.status);
  const inv = chk?.invoice;

  return (
    <div className="panel panel-pad stack" style={{ borderColor: 'var(--blue-fg)' }}>
      <div className="spread">
        <h3>Time Verify · PO {wo.store_po_number || `PO${wo.number}`}</h3>
        <span className="small muted">{wo.contractors?.name}</span>
      </div>
      {wo.nte != null && <div className="small">Not to exceed <strong>{money(wo.nte)}</strong> (the store's limit — checked against the invoice)</div>}
      {wo.reported_by_name && wo.source === 'qr' && <div className="small">Reported by <strong>{wo.reported_by_name}</strong> from the unit's QR sticker</div>}

      {/* Accepted? */}
      {wo.status !== 'cancelled' && (
        <div className="small">
          {wo.declined_at ? <span className="chip tone-red">Declined: {wo.decline_reason}</span>
            : wo.accepted_at ? <span className="chip tone-green">Accepted {dateTime(wo.accepted_at)}
              {wo.scheduled_start ? ` — scheduled ${dateTime(wo.scheduled_start)}${wo.scheduled_end ? `–${time(wo.scheduled_end)}` : ''}` : ''}</span>
            : wo.accept_due_at ? <span className={`chip ${late ? 'tone-red' : 'tone-amber'}`}>{late ? 'NOT accepted — was due' : 'Waiting to be accepted by'} {dateTime(wo.accept_due_at)}</span> : null}
          {wo.accept_note && <span className="muted"> · {wo.accept_note}</span>}
        </div>
      )}

      {office && !closed && !wo.accepted_at && (
        sched ? (
          <div className="stack" style={{ gap: 6 }}>
            <div className="row">
              <label className="grow">From<input type="datetime-local" value={sched.start} onChange={(e) => setSched({ ...sched, start: e.target.value })} /></label>
              <label className="grow">To<input type="datetime-local" value={sched.end} onChange={(e) => setSched({ ...sched, end: e.target.value })} /></label>
            </div>
            <div className="row">
              <button className="primary" disabled={busy || !sched.start} onClick={() => run('accept_call', { p_wo: wo.id, p_when: 'scheduled',
                p_start: new Date(sched.start).toISOString(), p_end: sched.end ? new Date(sched.end).toISOString() : null }, () => setSched(null))}>Accept — scheduled</button>
              <button onClick={() => setSched(null)}>Back</button>
            </div>
          </div>
        ) : (
          <div className="row">
            <button className="primary" disabled={busy} onClick={() => run('accept_call', { p_wo: wo.id, p_when: 'now' })}>Accept — on the way now</button>
            <button disabled={busy} onClick={() => setSched({ start: '', end: '' })}>Accept — schedule a time</button>
            <button className="danger" disabled={busy} onClick={() => {
              const r = window.prompt("Why can't you take it? (the store sees this)");
              if (r && r.trim()) run('decline_call', { p_wo: wo.id, p_reason: r.trim() });
            }}>Can't take it</button>
          </div>
        )
      )}
      {office && !closed && <div className="small muted">Any of your technicians can take it from their phone ("I'm going"), or assign one below.</div>}

      {/* Store: confirm a call the contractor entered from a phone call */}
      {side === 'store' && wo.source === 'contractor' && !wo.store_confirmed_at && (
        <div className="notice stack" style={{ gap: 6 }}>
          <div><strong>{wo.contractors?.name} entered this call{wo.contact_name ? ` — requested by ${wo.contact_name}` : ''}.</strong> Did your store request it?
            {wo.store_disputed && <span className="chip tone-red" style={{ marginLeft: 6 }}>You questioned it</span>}</div>
          {isStoreAdmin && (
            <div className="row">
              <input className="grow" value={po} onChange={(e) => setPo(e.target.value)} placeholder="Your PO number (optional)" />
              <button className="primary" disabled={busy} onClick={() => run('store_confirm_call', { p_wo: wo.id, p_confirm: true, p_po_number: po || null })}>Yes, confirm</button>
              <button className="danger" disabled={busy} onClick={() => {
                const n = window.prompt('What is wrong with this call? (the contractor sees this)');
                if (n && n.trim()) run('store_confirm_call', { p_wo: wo.id, p_confirm: false, p_note: n.trim() });
              }}>We didn't request this</button>
            </div>
          )}
        </div>
      )}

      {/* Store: send it to someone else if declined or not accepted */}
      {side === 'store' && isStoreAdmin && noVisit && (wo.declined_at || late) && contractors.length > 1 && (
        <div className="row">
          <select className="grow" value={reroute} onChange={(e) => setReroute(e.target.value)}>
            <option value="">Send to another contractor…</option>
            {contractors.filter((c) => c.contractor_id !== wo.contractor_id).map((c) => <option key={c.contractor_id} value={c.contractor_id}>{c.contractors?.name}</option>)}
          </select>
          <button disabled={busy || !reroute} onClick={() => run('reroute_call', { p_wo: wo.id, p_contractor: reroute })}>Send</button>
        </div>
      )}

      {/* Verified time */}
      {chk && chk.visits.length > 0 && (
        <>
          <h3 style={{ marginTop: 6 }}>Verified time</h3>
          <table>
            <tbody>
              {chk.visits.map((v) => (
                <tr key={v.visit_id}>
                  <td>
                    <strong>Visit {v.visit_no} · {v.tech}</strong>
                    <div className="small muted">
                      {v.started_at ? `left for the job ${time(v.started_at)} · ` : ''}arrived {time(v.arrived_at)}{v.arrival_by_store ? ' (recorded by the store)' : ' (GPS)'}
                      {v.left_at ? ` · left ${time(v.left_at)}` : ' · still on site'} · {date(v.arrived_at)}
                    </div>
                    <div className="small">On site {hm(v.onsite_min)}{v.travel_min ? ` · travel ${hm(v.travel_min)}${v.travel_counted_min ? '' : ' (not paid)'}` : ''}
                      {v.parts_run_min ? ` · parts run ${hm(v.parts_run_min)}${v.parts_run_unverified_min ? ' (supplier not confirmed by GPS)' : ''}` : ''}
                      {v.checkin_verified === false ? ' · check-in NOT verified' : ''}</div>
                    {runs.filter((r) => r.visit_id === v.visit_id).map((r) => (
                      <div key={r.id} className="small muted">🚚 {time(r.left_at)} → {r.supplier || 'supplier'}{r.at_supplier_at ? ` (GPS ${time(r.at_supplier_at)})` : ''} → back {r.returned_at ? time(r.returned_at) : '—'}</div>
                    ))}
                  </td>
                  <td className="num">{hm(v.billable_min)}<div className="small muted">billable</div></td>
                </tr>
              ))}
              <tr>
                <td><strong>Verified total</strong>
                  <div className="small muted">{chk.pays_travel === 'no' ? 'Travel not paid (your setting)' : chk.pays_travel === 'after_hours' ? 'Travel paid after hours only' : 'Travel included'}
                    {' · '}contractor minimum {Number(chk.min_hours)} h per visit, billed in {chk.increment_min}-minute steps</div></td>
                <td className="num"><strong>{h(chk.billable_h)}</strong></td>
              </tr>
            </tbody>
          </table>
        </>
      )}

      {/* Invoice check */}
      {inv && (
        <div className="stack" style={{ gap: 6, borderTop: '1px solid var(--line)', paddingTop: 8 }}>
          <div className="spread">
            <h3>Invoice {inv.number}</h3>
            <span className={`chip ${inv.status === 'approved' ? 'tone-green' : inv.status === 'disputed' ? 'tone-red' : 'tone-amber'}`}>{inv.status === 'submitted' ? 'to review' : inv.status}</span>
          </div>
          <table>
            <tbody>
              <tr><td>Hours billed</td><td className="num"><strong>{h(chk.billed_h)}</strong></td></tr>
              <tr><td>Verified (GPS + store check-in)</td><td className="num">{h(chk.billable_h)}</td></tr>
              {Number(chk.other_h) > 0 && <tr><td>Explained by the contractor<div className="small muted">{chk.other_reason}</div></td><td className="num">{h(chk.other_h)}</td></tr>}
              <tr><td><strong>Not explained</strong></td>
                <td className="num"><strong style={{ color: Number(chk.unexplained_h) > 0 ? 'var(--red-fg)' : 'var(--green-fg)' }}>{Number(chk.unexplained_h) > 0 ? h(chk.unexplained_h) : 'none ✓'}</strong></td></tr>
              {Number(chk.under_h) > 0 && office && <tr><td className="small muted">You billed less time than was verified</td><td className="num small muted">{h(chk.under_h)}</td></tr>}
              <tr><td>Invoice total{wo.nte != null ? <span className="small muted"> · limit {money(wo.nte)}</span> : ''}</td>
                <td className="num"><strong style={chk.over_nte ? { color: 'var(--red-fg)' } : {}}>{money(inv.total)}</strong>{chk.over_nte && <div className="small" style={{ color: 'var(--red-fg)' }}>over by {money(chk.over_nte_by)}</div>}</td></tr>
            </tbody>
          </table>
          {billingStore && inv.status !== 'approved' && (
            <div className="row">
              <button className="primary" disabled={busy} onClick={() => run('store_review_invoice', { p_wo: wo.id, p_ok: true })}>Approve invoice</button>
              <button className="danger" disabled={busy} onClick={() => {
                const n = window.prompt('What is wrong with the invoice? (the contractor sees this)');
                if (n && n.trim()) run('store_review_invoice', { p_wo: wo.id, p_ok: false, p_note: n.trim() });
              }}>Question it</button>
            </div>
          )}
        </div>
      )}

      {/* Enter the invoice: required for the contractor; the store can type in a paper/emailed one */}
      {['completed', 'invoiced'].includes(wo.status) && inv?.status !== 'approved' && (office || (billingStore && !inv)) && (
        <InvoiceForm wo={wo} chk={chk} side={side} busy={busy} run={run} />
      )}
      {side === 'store' && wo.status === 'completed' && !inv && (
        <div className="small muted">Waiting for {wo.contractors?.name} to enter their invoice (due {date(wo.invoice_due_at)}).</div>
      )}
    </div>
  );
}

function InvoiceForm({ wo, chk, side, busy, run }) {
  const inv = chk?.invoice;
  const [f, setF] = useState({ number: inv?.number || '', total: inv?.total ?? '', hours: chk?.billed_h ?? '', other: chk?.other_h ? String(chk.other_h) : '', reason: chk?.other_reason || '' });
  const [open, setOpen] = useState(!inv);
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  if (!open) return <button onClick={() => setOpen(true)}>{side === 'office' ? 'Change the invoice' : 'Enter the invoice'}</button>;
  const billable = Number(chk?.billable_h || 0);
  const extra = Number(f.hours || 0) - billable - Number(f.other || 0);
  return (
    <form className="stack" style={{ gap: 6, borderTop: '1px solid var(--line)', paddingTop: 8 }} onSubmit={(e) => {
      e.preventDefault();
      run('submit_invoice', { p_wo: wo.id, p_invoice_number: f.number, p_total: Number(f.total), p_hours_billed: Number(f.hours),
        p_other_hours: Number(f.other || 0), p_other_reason: f.reason || null }, () => setOpen(false));
    }}>
      <h3>{side === 'office' ? 'Your invoice for this PO' : "Enter the contractor's invoice (from their paper or email)"}</h3>
      {side === 'office' && <div className="small muted">The store requires it here. Verified time on this call: <strong>{h(billable)}</strong>. Shop work or other time? Enter it with a reason so it isn't flagged.</div>}
      <div className="row">
        <label className="grow">Invoice #<input value={f.number} onChange={set('number')} required /></label>
        <label className="grow">Total ($)<input type="number" step="0.01" min="0" value={f.total} onChange={set('total')} required /></label>
        <label className="grow">Hours billed<input type="number" step="0.25" min="0" value={f.hours} onChange={set('hours')} required /></label>
      </div>
      <div className="row">
        <label style={{ flex: '0 0 120px' }}>Other hours<input type="number" step="0.25" min="0" value={f.other} onChange={set('other')} placeholder="0" /></label>
        <label className="grow">What for<input value={f.reason} onChange={set('reason')} placeholder="e.g. Shop: rebuilt valve; picked up special-order part" /></label>
      </div>
      {f.hours !== '' && (
        <div className={`small ${extra > 0.009 ? '' : 'muted'}`} style={extra > 0.009 ? { color: 'var(--red-fg)', fontWeight: 600 } : {}}>
          {extra > 0.009 ? `${extra.toFixed(2)} h more than verified + explained — the store will see this as not explained.` : 'Hours match what was verified.'}
          {wo.nte != null && Number(f.total) > Number(wo.nte) ? ` Total is over the store's ${money(wo.nte)} limit.` : ''}
        </div>
      )}
      <div className="row">
        <button className="primary" disabled={busy}>Save invoice</button>
        {inv && <button type="button" onClick={() => setOpen(false)}>Cancel</button>}
      </div>
    </form>
  );
}

// Store: the tech is standing here but hasn't tapped "I'm here" — record it from the store side.
export function TechHereButton({ wo, visits, busy, run }) {
  if (['completed', 'invoiced', 'cancelled'].includes(wo.status)) return null;
  if ((visits || []).some((v) => v.status === 'on_site')) return null;
  return (
    <button disabled={busy} onClick={() => {
      if (window.confirm('Record that the technician is here now? Their time starts now, their office is told, and you will be asked for the check-in code.')) {
        run('store_tech_here', { p_wo: wo.id });
      }
    }}>🙋 The technician is here but hasn't checked in</button>
  );
}
