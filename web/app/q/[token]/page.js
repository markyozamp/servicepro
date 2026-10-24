'use client';

// A customer's quote from the emailed link (no login): every line, the total, and Approve / No thanks (they type their name).
import { useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import { act } from '@/lib/supabase';
import { money, date, dateTime } from '@/lib/format';
import { LegalFooter } from '@/components/Legal';

export default function CustomerQuote() {
  const { token } = useParams();
  const [qt, setQt] = useState(null);
  const [err, setErr] = useState('');
  const [name, setName] = useState('');
  const [no, setNo] = useState(false);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState('');
  const load = () => act('quote_public', { p_token: token }).then((r) => (r ? setQt(r) : setErr('This link isn’t valid. Ask whoever sent it for a new one.'))).catch((e) => setErr(e.message));
  useEffect(() => { load(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [token]);
  async function decide(approve) {
    setBusy(true); setErr('');
    try { await act('quote_link_decide', { p_token: token, p_approve: approve, p_name: name, p_note: approve ? null : note }); setDone(approve ? 'Approved. Thank you, they’ve been told and will be in touch to schedule.' : 'Sent. Thank you, they’ve been told.'); load(); }
    catch (x) { setErr(x.message); } finally { setBusy(false); }
  }
  if (err && !qt) return <main className="page"><div className="error">{err}</div></main>;
  if (!qt) return <main className="page muted">Loading…</main>;
  const c = qt.contractor || {};
  return (
    <main className="page billpage">
      <div className="row noprint" style={{ justifyContent: 'flex-end' }}><button onClick={() => window.print()}>Print / save as PDF</button></div>
      <div className="panel panel-pad stack" style={{ gap: 14 }}>
        <div className="spread" style={{ alignItems: 'flex-start' }}>
          <div>{c.logo ? <img src={c.logo} alt={c.name} style={{ maxHeight: 60, maxWidth: 220 }} /> : <h2 style={{ margin: 0 }}>{c.name}</h2>}
            <div className="small">{[c.phone, c.email].filter(Boolean).join(' · ')}</div></div>
          <div style={{ textAlign: 'right' }}><h2 style={{ margin: 0 }}>Quote {qt.number}</h2><div className="small">{date(qt.sent_at)}</div>
            {qt.valid_until && <div className="small">Good until {date(qt.valid_until)}</div>}</div>
        </div>
        <div><div className="small muted">For</div><strong>{qt.customer}</strong><div className="small">{qt.site?.name} · {qt.site?.address}</div></div>
        <h3 style={{ margin: 0 }}>{qt.title}</h3>
        <table className="billtable">
          <thead><tr><th>Description</th><th className="num">Qty</th><th className="num">Price</th><th className="num">Amount</th></tr></thead>
          <tbody>
            {(qt.lines || []).map((l, i) => <tr key={i}><td>{l.description}</td><td className="num">{Number(l.qty)} {l.unit}</td><td className="num">{money(l.rate)}</td><td className="num">{money(l.amount)}</td></tr>)}
            <tr><td colSpan={3}><strong>Total</strong></td><td className="num"><strong>{money(qt.total)}</strong></td></tr>
          </tbody>
        </table>
        {qt.notes && <div className="small">{qt.notes}</div>}
      </div>
      <div className="panel panel-pad stack noprint" style={{ gap: 8, marginTop: 12 }}>
        {done && <div className="notice" style={{ fontWeight: 600 }}>{done}</div>}
        {qt.status === 'sent' && !qt.expired && !done && (
          <>
            <label>Your name <span className="muted" style={{ fontWeight: 400 }}>(to sign)</span><input value={name} onChange={(e) => setName(e.target.value)} /></label>
            {no && <label>What would work instead? <span className="muted" style={{ fontWeight: 400 }}>(they see this)</span><textarea rows={2} value={note} onChange={(e) => setNote(e.target.value)} /></label>}
            <div className="row">
              {!no ? <><button className="primary big grow" disabled={busy || name.trim().length < 2} onClick={() => decide(true)}>Approve {money(qt.total)}</button>
                <button className="big" disabled={busy} onClick={() => setNo(true)}>No thanks</button></>
                : <><button className="big grow" disabled={busy || name.trim().length < 2 || note.trim().length < 3} onClick={() => decide(false)}>Send</button><button className="big" onClick={() => setNo(false)}>Back</button></>}
            </div>
          </>
        )}
        {qt.status === 'sent' && qt.expired && <div className="notice">This quote expired on {date(qt.valid_until)}. Call {c.name}{c.phone ? ` at ${c.phone}` : ''} for an updated one.</div>}
        {qt.status !== 'sent' && !done && <div className="notice">{qt.status === 'approved' ? `Approved${qt.decided_name ? ` by ${qt.decided_name}` : ''} ${dateTime(qt.decided_at)}.` : 'This quote is closed.'}</div>}
        {err && <div className="error">{err}</div>}
      </div>
      <div className="noprint"><LegalFooter /></div>
    </main>
  );
}
