'use client';

// Time Verify on a call: acceptance, confirming contractor-entered calls, verified hours and the invoice check.
import { useCallback, useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';
import { money, dateTime, time, date } from '@/lib/format';
import RateCard from './RateCard';

const h = (n) => (n == null ? '—' : `${Number(n).toFixed(2)} h`);
const hm = (m) => `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, '0')} m`;

export function VerifyPanel({ wo, side, profile, busy, run: runOuter, visits = [], techs = [] }) {
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
        setContractors(await q(supabase.from('customer_contractors').select('contractor_id, mode, contractors(name)').eq('customer_id', wo.customer_id).is('store_removed_at', null).is('contractor_removed_at', null)));
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

      {/* Reaching the contractor by phone (store), and what the store noted (both sides) */}
      {wo.store_phoned_at && (
        <div className="small">📞 <strong>Store talked to them:</strong> {wo.store_phone_note} <span className="muted">— {wo.store_phoned_by_name || 'store'}, {dateTime(wo.store_phoned_at)}</span></div>
      )}
      {side === 'store' && !closed && !wo.declined_at && (
        <div className={`reach${wo.priority === 1 && !wo.accepted_at ? ' urgent' : ''}`}>
          <div className="row" style={{ gap: 8 }}>
            {wo.contractors?.phone
              ? <a className="callbtn" href={`tel:${wo.contractors.phone.replace(/[^\d+]/g, '')}`}>📞 Call {wo.contractors?.name} now · {wo.contractors.phone}</a>
              : <span className="small muted">No office phone on file for {wo.contractors?.name}.</span>}
            <button disabled={busy} onClick={() => {
              const n = window.prompt('Who did you talk to, and when? (for example "Dana, 2:10 pm — on the way")');
              if (n && n.trim()) run('store_log_phone_contact', { p_wo: wo.id, p_note: n.trim() });
            }}>I talked to them</button>
          </div>
          {!wo.accepted_at && <div className="small muted">Coming soon: if they don't accept in time, Service Call Proof will phone them automatically, then their backup number, and let you know.</div>}
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
      {/* Trips: every trip is announced to the store before it happens */}
      <Trips wo={wo} visits={visits} techs={techs} office={office} closed={closed} busy={busy} run={run} />

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
                    {v.trip && (
                      <div className="small muted">📍 {v.trip.known
                        ? <>Trip started near <strong>{v.trip.town || 'an unknown town'}</strong>, about {v.trip.miles} mi away{v.trip.expected_min ? ` (usually ~${v.trip.expected_min} min)` : ''}{v.trip.in_area ? ' · already in the area' : ''}{v.trip.slow ? <span style={{ color: 'var(--red-fg)' }}> · drive took {v.trip.drive_min} min</span> : ''}</>
                        : 'Starting town not known (phone location was off when they left)'}</div>
                    )}
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
          {chk.travel_notes?.length > 0 && (
            <div className="notice small stack" style={{ gap: 4 }}>
              <strong>Travel check</strong>
              {chk.travel_notes.map((n) => <div key={n}>{n}</div>)}
            </div>
          )}
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
              <tr><td>Invoice total{chk.cap != null ? <span className="small muted"> · allowed {money(chk.cap)}{Number(chk.approved_more) ? ` (PO ${money(wo.nte)} + approved ${money(chk.approved_more)})` : ''}</span> : ''}</td>
                <td className="num"><strong style={chk.over_nte ? { color: 'var(--red-fg)' } : {}}>{money(inv.total)}</strong>{chk.over_nte && <div className="small" style={{ color: 'var(--red-fg)' }}>over by {money(chk.over_nte_by)}</div>}</td></tr>
            </tbody>
          </table>
          {inv.side === 'contractor' && inv.agreed_hours != null && (
            <div className="small">{inv.agreed_hours ? '✓ Contractor agreed to the verified hours' : '✎ Contractor billed different hours (see above)'}
              {' · '}{chk.cap == null ? 'no PO limit' : inv.agreed_cap ? '✓ within the PO' : '⚠ sent over the PO'}
              {' · '}{chk.trips} trip{chk.trips === 1 ? '' : 's'}</div>
          )}
          {inv.auto_approved && <div className="small"><span className="chip tone-green">Approved automatically</span> <span className="muted">it matched: hours agreed, within the PO</span></div>}
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

      {/* Reference: what this contractor charges this customer, as of the call */}
      {(office || billingStore) && wo.contractor_id && (
        <details className="small">
          <summary style={{ cursor: 'pointer' }}>💲 {office ? 'Your rates for this customer' : 'Their rates'} (for reference)</summary>
          <div style={{ paddingTop: 6 }}><RateCard customerId={wo.customer_id} contractorId={wo.contractor_id} side={office ? 'contractor' : 'store'} at={(wo.created_at || '').slice(0, 10) || null} canEdit={false} title={null} /></div>
        </details>
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
  if (side !== 'office') return <StoreInvoiceForm wo={wo} chk={chk} busy={busy} run={run} />;
  return <LightBill wo={wo} chk={chk} busy={busy} run={run} />;
}

// Contractor: the light bill. Agree to the verified hours and that the bill stays within the PO, then invoice # and total.
function LightBill({ wo, chk, busy, run }) {
  const inv = chk?.invoice;
  const [f, setF] = useState({ number: inv?.number || '', total: inv?.total ?? '', agreeHours: false, agreeCap: false, differ: false, hours: '', reason: '', overOk: false });
  const [open, setOpen] = useState(!inv);
  if (!chk) return null;
  if (!open) return <button onClick={() => setOpen(true)}>Change the bill</button>;
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  const cap = chk.cap == null ? null : Number(chk.cap);
  const more = Number(chk.approved_more || 0);
  const total = f.total === '' ? null : Number(f.total);
  const over = cap != null && total != null && total > cap;
  const billable = Number(chk.billable_h || 0);
  const extraH = f.differ && f.hours !== '' ? Number(f.hours) - billable : 0;
  const hoursOk = f.differ ? f.hours !== '' && (extraH <= 0.009 || f.reason.trim().length >= 5) : f.agreeHours;
  const capOk = cap == null || (over ? f.overOk : f.agreeCap);
  const ready = f.number.trim() && total != null && hoursOk && capOk;
  const parts = Number(chk.parts_run_h) > 0 ? ` + ${h(chk.parts_run_h)} parts runs` : '';
  return (
    <form className="stack lightbill" style={{ gap: 8, borderTop: '1px solid var(--line)', paddingTop: 8 }} onSubmit={(e) => {
      e.preventDefault();
      run('send_bill', { p_wo: wo.id, p_invoice_number: f.number.trim(), p_total: total, p_agree_hours: !f.differ && f.agreeHours,
        p_hours: f.differ ? Number(f.hours) : null, p_reason: f.differ ? f.reason.trim() || null : null, p_over_ok: over && f.overOk }, () => setOpen(false));
    }}>
      <h3>Send your bill · PO {wo.store_po_number || `PO${wo.number}`}</h3>
      {!f.differ ? (
        <label className="lb-check"><input type="checkbox" checked={f.agreeHours} onChange={set('agreeHours')} />
          <span>Labor: <strong>{h(chk.billable_h)}</strong> over <strong>{chk.trips} trip{chk.trips === 1 ? '' : 's'}</strong>
            <span className="small muted"> ({h(chk.onsite_h)} on site + {h(chk.travel_counted_h)} travel{parts}, with your minimum and rounding)</span></span></label>
      ) : (
        <div className="row">
          <label style={{ flex: '0 0 130px' }}>Hours on your bill<input type="number" step="0.25" min="0" value={f.hours} onChange={set('hours')} required /></label>
          {extraH > 0.009 && <label className="grow">What were the other {extraH.toFixed(2)} h for?<input value={f.reason} onChange={set('reason')} placeholder="e.g. Shop: rebuilt valve; second tech" /></label>}
        </div>
      )}
      <button type="button" className="linkish small" style={{ alignSelf: 'flex-start' }} onClick={() => setF({ ...f, differ: !f.differ, agreeHours: false })}>
        {f.differ ? `Use the verified hours (${h(chk.billable_h)})` : 'My hours are different'}</button>
      {cap == null ? <div className="small muted">No PO limit on this call.</div> : (
        <label className="lb-check"><input type="checkbox" checked={f.agreeCap} disabled={over} onChange={set('agreeCap')} />
          <span>My bill doesn&apos;t go over <strong>{money(cap)}</strong>
            <span className="small muted"> (PO {money(Number(wo.nte))}{more ? ` + approved additions ${money(more)}` : ''}; parts are included under the PO)</span></span></label>
      )}
      <div className="row">
        <label className="grow">Your invoice #<input value={f.number} onChange={set('number')} required placeholder="From your own invoice" /></label>
        <label className="grow">Total ($)<input type="number" step="0.01" min="0" value={f.total} onChange={set('total')} required /></label>
      </div>
      {over && (
        <div className="notice small stack" style={{ gap: 6 }}>
          <div><strong>That&apos;s {money(total - cap)} over what this call allows.</strong> Best: ask the store first with <em>Request approval for more</em>.</div>
          <label className="row" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.overOk} onChange={set('overOk')} /> Send it anyway, marked over the PO (the store will see it flagged)</label>
        </div>
      )}
      <div className="row">
        <button className="primary" disabled={busy || !ready}>Agree and send</button>
        {inv && <button type="button" onClick={() => setOpen(false)}>Cancel</button>}
      </div>
      <div className="small muted">Your invoice # ties this bill to your own paperwork, so the store matches it in one step.</div>
    </form>
  );
}

// Store: type in a contractor's paper or emailed invoice.
function StoreInvoiceForm({ wo, chk, busy, run }) {
  const inv = chk?.invoice;
  const [f, setF] = useState({ number: inv?.number || '', total: inv?.total ?? '', hours: chk?.billed_h ?? '', other: chk?.other_h ? String(chk.other_h) : '', reason: chk?.other_reason || '' });
  const [open, setOpen] = useState(!inv);
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  if (!open) return <button onClick={() => setOpen(true)}>Enter the invoice</button>;
  const billable = Number(chk?.billable_h || 0);
  const extra = Number(f.hours || 0) - billable - Number(f.other || 0);
  const cap = chk?.cap == null ? null : Number(chk.cap);
  return (
    <form className="stack" style={{ gap: 6, borderTop: '1px solid var(--line)', paddingTop: 8 }} onSubmit={(e) => {
      e.preventDefault();
      run('submit_invoice', { p_wo: wo.id, p_invoice_number: f.number, p_total: Number(f.total), p_hours_billed: Number(f.hours),
        p_other_hours: Number(f.other || 0), p_other_reason: f.reason || null }, () => setOpen(false));
    }}>
      <h3>Enter the contractor&apos;s invoice (from their paper or email)</h3>
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
          {extra > 0.009 ? `${extra.toFixed(2)} h more than verified + explained — shows as not explained.` : 'Hours match what was verified.'}
          {cap != null && Number(f.total) > cap ? ` Total is over the ${money(cap)} this call allows.` : ''}
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

// Every trip to the store, announced ahead: who, when. The office (or owner) schedules; the store sees it as Expected.
function Trips({ wo, visits, techs, office, closed, busy, run }) {
  const [f, setF] = useState(null);
  const trips = (visits || []).filter((v) => v.status !== 'cancelled');
  const upcoming = trips.find((v) => ['assigned', 'en_route'].includes(v.status));
  const onSite = trips.some((v) => v.status === 'on_site');
  const when = (v) => (v.scheduled_start ? `${dateTime(v.scheduled_start)}${v.scheduled_end ? `–${time(v.scheduled_end)}` : ''}` : 'no time set');
  return (
    <div className="stack" style={{ gap: 6 }}>
      {upcoming && (
        <div className="small"><span className={`chip ${upcoming.status === 'en_route' ? 'tone-amber' : 'tone-blue'}`}>{upcoming.status === 'en_route' ? 'On the way' : 'Trip scheduled'}</span>{' '}
          <strong>{upcoming.profiles?.full_name}</strong> · {when(upcoming)}{upcoming.visit_no > 1 ? ' · return trip' : ''}
          {upcoming.missed_alert_at && <span className="chip tone-red" style={{ marginLeft: 6 }}>missed the window</span>}
          {upcoming.outcome_note && <span className="muted"> · {upcoming.outcome_note}</span>}</div>
      )}
      {office && !closed && !onSite && !wo.declined_at && (upcoming?.status !== 'en_route') && (
        f ? (
          <form className="stack" style={{ gap: 6 }} onSubmit={(e) => {
            e.preventDefault();
            run('schedule_trip', { p_wo: wo.id, p_tech: f.tech, p_start: f.now ? null : new Date(f.start).toISOString(),
              p_end: !f.now && f.end ? new Date(f.end).toISOString() : null, p_note: f.note || null }, () => setF(null));
          }}>
            <div className="row">
              <label className="grow">Technician
                <select value={f.tech} onChange={(e) => setF({ ...f, tech: e.target.value })} required>
                  <option value="">Choose…</option>{techs.map((t) => <option key={t.id} value={t.id}>{t.full_name}</option>)}
                </select></label>
              <label className="row small" style={{ gap: 4, fontWeight: 400, alignSelf: 'flex-end' }}>
                <input type="checkbox" style={{ width: 'auto' }} checked={f.now} onChange={(e) => setF({ ...f, now: e.target.checked })} /> Going now</label>
            </div>
            {!f.now && (
              <div className="row">
                <label className="grow">From<input type="datetime-local" value={f.start} onChange={(e) => setF({ ...f, start: e.target.value })} required /></label>
                <label className="grow">To<input type="datetime-local" value={f.end} onChange={(e) => setF({ ...f, end: e.target.value })} /></label>
              </div>
            )}
            <input value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} placeholder="Note for the store (optional), e.g. Coming back with the part" />
            <div className="row"><button className="primary" disabled={busy}>{upcoming ? 'Reschedule — tell the store' : 'Schedule — tell the store'}</button>
              <button type="button" onClick={() => setF(null)}>Cancel</button></div>
            <div className="small muted">The store sees who is coming and when, with a check-in code for this trip. The technician gets it on his phone, with a reminder that morning.</div>
          </form>
        ) : (
          <button className={upcoming ? '' : 'primary'} onClick={() => setF({ tech: upcoming?.technician_id || '', now: false, start: '', end: '', note: '' })}>
            {upcoming ? 'Reschedule this trip' : trips.some((v) => v.arrived_at) ? 'Schedule the next trip' : 'Schedule a trip'}</button>
        )
      )}
      {office && !closed && !upcoming && !onSite && <div className="small muted">Every trip is announced to the store before it happens. A tech can also tap "I'm going" on his phone — the store is told he's coming now.</div>}
    </div>
  );
}
