'use client';

// A customer's statement (Base): every open invoice with what's been paid and what's left. Print or save as PDF.
import { useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import { act } from '@/lib/supabase';
import { useProfile } from '@/lib/useProfile';
import { money, date } from '@/lib/format';

export default function Statement() {
  const { id } = useParams();
  const { profile } = useProfile();
  const [s, setS] = useState(null);
  const [err, setErr] = useState('');
  useEffect(() => { if (profile) act('customer_statement', { p_customer: id }).then(setS).catch((e) => setErr(e.message)); }, [profile, id]);
  if (err) return <main className="page"><div className="error">{err}</div></main>;
  if (!s) return <main className="page muted">Loading…</main>;
  const c = s.contractor || {};
  const total = s.invoices.reduce((t, i) => t + Number(i.balance), 0);
  const late = s.invoices.filter((i) => i.days_late > 0).reduce((t, i) => t + Number(i.balance), 0);
  return (
    <main className="page billpage">
      <div className="row noprint" style={{ justifyContent: 'flex-end', gap: 8 }}>
        <button className="primary" onClick={() => window.print()}>Print / save as PDF</button>
        <button onClick={() => window.close()}>Close</button>
      </div>
      <div className="panel panel-pad stack" style={{ gap: 14 }}>
        <div className="spread" style={{ alignItems: 'flex-start' }}>
          <div>{c.logo ? <img src={c.logo} alt={c.name} style={{ maxHeight: 60, maxWidth: 220 }} /> : <h2 style={{ margin: 0 }}>{c.name}</h2>}
            <div className="small">{[c.phone, c.email].filter(Boolean).join(' · ')}</div></div>
          <div style={{ textAlign: 'right' }}><h2 style={{ margin: 0 }}>Statement</h2><div className="small">{date(s.date)}</div></div>
        </div>
        <div><div className="small muted">For</div><strong>{s.customer.name}</strong>{s.customer.contact && <div className="small">{s.customer.contact}</div>}{s.customer.address && <div className="small">{s.customer.address}</div>}</div>
        <table className="billtable">
          <thead><tr><th>Invoice</th><th>Date</th><th>Location</th><th>Due</th><th className="num">Total</th><th className="num">Paid</th><th className="num">Owed</th></tr></thead>
          <tbody>
            {s.invoices.length === 0 && <tr><td colSpan={7} className="muted">Nothing owed. Thank you!</td></tr>}
            {s.invoices.map((i) => (
              <tr key={i.work_order_id}><td>{i.invoice_number}</td><td>{date(i.date)}</td><td>{i.site}</td>
                <td>{date(i.due_on)}{i.days_late > 0 ? <strong style={{ color: '#b00' }}> ({i.days_late} days past due)</strong> : ''}</td>
                <td className="num">{money(i.total)}</td><td className="num">{Number(i.paid) > 0 ? money(i.paid) : ''}</td><td className="num">{money(i.balance)}</td></tr>
            ))}
            <tr><td colSpan={6}><strong>Total owed</strong>{late > 0 ? <span className="small"> · {money(late)} of it past due</span> : ''}</td><td className="num"><strong style={{ fontSize: 18 }}>{money(total)}</strong></td></tr>
          </tbody>
        </table>
        <div className="small">Questions? Call {c.name}{c.phone ? ` at ${c.phone}` : ''}. If you&apos;ve already paid, thank you.</div>
      </div>
    </main>
  );
}
