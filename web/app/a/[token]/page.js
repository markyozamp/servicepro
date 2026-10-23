'use client';

// One-tap answer page. The link in an alert email opens this one item (pick a time, confirm a crew, approve a repair
// or an invoice, confirm a call, let a contractor in during busy hours, see the check-in code) with no password.
// The link is the key: only for that person and that item, and it stops working once used or after 3 days.
import { useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import { act } from '@/lib/supabase';
import { money, dateTime, time } from '@/lib/format';
import { LegalFooter } from '@/components/Legal';

const optText = (o) => `${dateTime(o.start)}${o.end ? `–${time(o.end)}` : ''}`;
const DONE = {
  yes: 'Confirmed', no: 'Answered no', approve: 'Approved', decline: 'Declined', pick: 'Time picked', none: 'Sent: none of those times work',
};

export default function Answer() {
  const { token } = useParams();
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState('');
  const [po, setPo] = useState('');
  const [ask, setAsk] = useState('');     // which answer needs a note first
  const [done, setDone] = useState('');

  async function load() {
    try {
      const r = await act('action_link_info', { p_token: token });
      if (!r) setErr('This link isn’t valid. Open Service Call Proof to see what’s waiting.');
      setD(r);
    } catch (e) { setErr(e.message); }
  }
  useEffect(() => { load(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [token]);

  async function answer(choice, option) {
    setBusy(true); setErr('');
    try {
      const r = await act('action_link_do', { p_token: token, p_choice: choice, p_option: option ?? null, p_note: note.trim() || null, p_po: po.trim() || null });
      const res = r?.result || {};
      setDone(res.escalated ? res.message : res.declined ? 'Sent. They’ll offer new times.' : 'Done. Thank you, they’ve been told.');
      setAsk('');
      await load();
    } catch (e) { setErr(e.message); } finally { setBusy(false); }
  }

  const x = d?.details || {};
  const needNote = (choice, label, placeholder, min = 5) => (
    ask === choice ? (
      <div className="stack" style={{ gap: 6 }}>
        <label>{label}<textarea value={note} onChange={(e) => setNote(e.target.value)} placeholder={placeholder} /></label>
        <div className="row">
          <button className="big grow danger" disabled={busy || note.trim().length < min} onClick={() => answer(choice)}>Send</button>
          <button className="big" disabled={busy} onClick={() => setAsk('')}>Back</button>
        </div>
      </div>
    ) : null
  );

  const actions = () => {
    if (!d?.open) return null;
    if (ask) {
      return needNote(ask, ask === 'none' ? 'What would work? (they get this and send new times)' : 'What’s wrong? (the contractor sees this)',
        ask === 'none' ? 'e.g. After 2 pm, or Tuesday before 10' : 'Say what’s wrong', ask === 'none' ? 3 : 5);
    }
    switch (d.kind) {
      case 'door':
        return (
          <div className="stack" style={{ gap: 6, alignItems: 'center' }}>
            <div className="small muted">Meet {x.tech || 'the technician'} and give them this code:</div>
            <div className="doorcode">{x.code || '—'}</div>
          </div>
        );
      case 'crew':
        return (
          <div className="row">
            <button className="primary big grow" disabled={busy} onClick={() => answer('yes')}>Yes, that&apos;s right</button>
            <button className="big" disabled={busy} onClick={() => answer('no')}>No, that&apos;s not right</button>
          </div>
        );
      case 'approval':
        return (
          <div className="row">
            <button className="primary big grow" disabled={busy || !x.can_approve} onClick={() => answer('approve')}>Approve up to {money(x.amount)}</button>
            <button className="big" disabled={busy || !x.can_approve} onClick={() => setAsk('decline')}>Decline</button>
          </div>
        );
      case 'trip':
        return (
          <div className="stack" style={{ gap: 8 }}>
            {(x.options || []).map((o, i) => (
              <button key={i} className="primary big" disabled={busy} onClick={() => answer('pick', i + 1)}>✓ {optText(o)}</button>
            ))}
            <button className="big" disabled={busy} onClick={() => setAsk('none')}>None of these work</button>
          </div>
        );
      case 'confirm':
        return (
          <div className="stack" style={{ gap: 8 }}>
            <label>Your PO number <span className="muted" style={{ fontWeight: 400 }}>(optional)</span>
              <input value={po} onChange={(e) => setPo(e.target.value)} placeholder={x.po_number || ''} /></label>
            <div className="row">
              <button className="primary big grow" disabled={busy} onClick={() => answer('yes')}>Yes, this is our call</button>
              <button className="big" disabled={busy} onClick={() => setAsk('no')}>Something&apos;s wrong</button>
            </div>
          </div>
        );
      case 'invoice':
        return (
          <div className="row">
            <button className="primary big grow" disabled={busy} onClick={() => answer('approve')}>Approve the invoice</button>
            <button className="big" disabled={busy} onClick={() => setAsk('decline')}>Question it</button>
          </div>
        );
      case 'busy':
        return (
          <div className="row">
            <button className="primary big grow" disabled={busy} onClick={() => answer('yes')}>Let them come now</button>
            <button className="big" disabled={busy} onClick={() => answer('no')}>Not yet</button>
          </div>
        );
      default: return null;
    }
  };

  const detail = () => {
    switch (d.kind) {
      case 'crew': return <div><strong>{x.tech}</strong> says {x.helpers === 1 ? '1 helper is' : `${x.helpers} helpers are`} working with them{x.helper_names ? ` (${x.helper_names})` : ''}. Is that right?</div>;
      case 'approval': return (
        <div className="stack" style={{ gap: 4, background: 'var(--bg)', borderRadius: 8, padding: 12 }}>
          <div className="spread"><strong>{x.description}</strong><strong style={{ fontSize: 22 }}>{money(x.amount)}</strong></div>
          <div className="small muted">With this, the call totals {money(x.total_after)}.{x.my_limit != null && Number(x.total_after) > Number(x.my_limit) ? ` That's above your ${money(x.my_limit)} limit, so approving sends it up for approval.` : ''}</div>
          {!x.can_approve && <div className="small" style={{ color: 'var(--red-fg)' }}>You aren&apos;t set up to approve spending. Ask your admin.</div>}
        </div>
      );
      case 'trip': return <div>{d.contractor} wants to come back{x.tech ? ` (${x.tech})` : ''}. Pick the time that works for you.{x.note ? <span className="muted"> “{x.note}”</span> : null}{x.busy_hours ? <div className="small muted">Your busy hours: {x.busy_hours}</div> : null}</div>;
      case 'invoice': return (
        <div className="stack" style={{ gap: 4, background: 'var(--bg)', borderRadius: 8, padding: 12 }}>
          <div className="spread"><strong>Invoice {x.invoice_number}</strong><strong style={{ fontSize: 22 }}>{money(x.total)}</strong></div>
          <div className="small">{x.agreed_hours ? '✓ They agreed to the verified hours' : '✎ They billed different hours than were verified'}
            {x.nte != null ? ` · ${x.agreed_cap ? '✓ within your PO' : '⚠ over your PO'} of ${money(x.nte)}` : ''}</div>
          <div className="small muted">Open the call in Service Call Proof for the full time check.</div>
        </div>
      );
      case 'busy': return <div>{x.who || d.contractor} ({d.contractor}) wants to come now, during your busy hours ({x.busy_hours}).{x.note ? <span className="muted"> “{x.note}”</span> : null}</div>;
      case 'confirm': return <div>{d.contractor} entered this call for your location. Is it yours?</div>;
      default: return null;
    }
  };

  return (
    <main className="login-wrap">
      <div className="login stack" style={{ width: 'min(480px, 100%)' }}>
        <div style={{ textAlign: 'center' }}>
          <div className="brand" style={{ fontSize: 24, color: 'var(--ink)' }}>Service Call <span style={{ color: 'var(--brand)' }}>Proof</span></div>
          <div className="muted small">{d?.name ? `For ${d.name}` : 'Waiting on you'}</div>
        </div>
        {err && <div className="error">{err}</div>}
        {!d && !err && <div className="panel panel-pad muted">Loading…</div>}
        {d?.expired && <div className="panel panel-pad">This link has expired. Open Service Call Proof to see what&apos;s waiting.</div>}
        {d && !d.expired && (
          <div className="panel panel-pad stack">
            <div>
              <div className="small muted">{[d.contractor, d.call_number ? `Call #${d.call_number}` : null].filter(Boolean).join(' · ')}</div>
              <h2 style={{ margin: '4px 0' }}>{d.site}{d.unit ? `, unit ${d.unit}` : ''}</h2>
              {d.problem && <div className="small"><strong>Problem:</strong> {d.problem}</div>}
            </div>
            {d.open && d.label && <div className={d.urgent ? 'notice' : ''} style={{ fontWeight: 600 }}>{d.label}</div>}
            {d.open && detail()}
            {done && <div className="notice" style={{ fontWeight: 600 }}>{done}</div>}
            {actions()}
            {!d.open && !done && (
              <div className="notice" style={{ fontWeight: 600 }}>
                {d.used_at ? `${DONE[d.used_action] || 'Answered'} · ${dateTime(d.used_at)}. Thank you.` : 'This was already taken care of. Nothing more to do.'}
              </div>
            )}
            <a className="small" href={`/store${d.call_id ? `?call=${d.call_id}` : ''}`}>Open the call in Service Call Proof</a>
          </div>
        )}
        <LegalFooter />
      </div>
    </main>
  );
}
