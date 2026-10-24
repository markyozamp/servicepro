'use client';

// Base, on a call for your own customer: write the bill (BillBuilder), then see where it went (emailed / in their
// portal), email it again, and mark it paid.
import { useCallback, useEffect, useState } from 'react';
import { act } from '@/lib/supabase';
import { money, dateTime } from '@/lib/format';
import BillBuilder from './BillBuilder';

export default function OwnBill({ wo, busy, onChanged }) {
  const [chk, setChk] = useState(null);
  const [edit, setEdit] = useState(false);
  const [to, setTo] = useState('');
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const load = useCallback(async () => { try { setChk(await act('invoice_check', { p_wo: wo.id })); } catch (x) { setErr(x.message); } }, [wo.id]);
  useEffect(() => { load(); }, [load]);
  async function run(fn, args, m) {
    setErr(''); setMsg('');
    try { await act(fn, args); setMsg(m); await load(); onChanged?.(); } catch (x) { setErr(x.message); }
  }
  const inv = chk?.invoice;
  if (!chk) return null;
  if (!inv || edit) {
    return (
      <div className="panel panel-pad">
        <BillBuilder wo={wo} busy={busy} onSent={() => { setEdit(false); setMsg('Sent.'); load(); onChanged?.(); }} />
        {inv && <button type="button" className="linkish small" onClick={() => setEdit(false)}>Cancel changes</button>}
      </div>
    );
  }
  const paid = !!inv.paid_at;
  return (
    <div className="panel panel-pad stack" style={{ gap: 8 }}>
      <div className="spread">
        <h3 style={{ margin: 0 }}>Invoice {inv.number} · {money(inv.total)}</h3>
        <span className={`chip ${paid ? 'tone-green' : 'tone-amber'}`}>{paid ? `Paid ${dateTime(inv.paid_at)}` : 'Not paid yet'}</span>
      </div>
      <div className="small">{inv.emailed_to ? <>Emailed to <strong>{inv.emailed_to}</strong>{inv.emailed_at ? ` · ${dateTime(inv.emailed_at)}` : ''}</> : 'Sent to their portal.'}{inv.flat ? ' · flat rate' : ''}</div>
      <div className="row" style={{ gap: 6 }}>
        <a className="btnlink" href={`/bill/${wo.id}`} target="_blank" rel="noreferrer"><button type="button">View / print</button></a>
        {!paid && <button className="primary" onClick={() => { const n = window.prompt('Paid how? (optional, e.g. check 2210)', ''); if (n !== null) run('mark_bill_paid', { p_wo: wo.id, p_paid: true, p_note: n.trim() || null }, 'Marked paid.'); }}>Mark paid</button>}
        {paid && <button onClick={() => run('mark_bill_paid', { p_wo: wo.id, p_paid: false }, 'Marked not paid.')}>Not paid after all</button>}
        {!paid && <button onClick={() => setEdit(true)}>Change the bill</button>}
      </div>
      <form className="row" style={{ alignItems: 'flex-end' }} onSubmit={(e) => { e.preventDefault(); run('email_bill', { p_wo: wo.id, p_to: to.trim() || null }, 'Emailed.'); setTo(''); }}>
        <label className="grow">Email it again <span className="muted" style={{ fontWeight: 400 }}>(blank = their email on file)</span><input type="email" value={to} onChange={(e) => setTo(e.target.value)} placeholder="someone@example.com" /></label>
        <button>Email</button>
      </form>
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
    </div>
  );
}
