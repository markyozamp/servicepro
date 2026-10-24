'use client';

// The bill itself (printable): used by the signed-in bill page and the customer's no-login link.
import { money, dateTime, date } from '@/lib/format';

const hm = (min) => { const m = Number(min || 0); return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`; };

export default function BillDoc({ b }) {
  return (
    <div className="panel panel-pad stack" style={{ gap: 14 }}>
        <div className="spread" style={{ alignItems: 'flex-start' }}>
          <div>
            {b.contractor?.logo ? <img src={b.contractor.logo} alt={b.contractor.name} style={{ maxHeight: 60, maxWidth: 220 }} /> : <h2 style={{ margin: 0 }}>{b.contractor?.name}</h2>}
            <div className="small">{[b.contractor?.phone, b.contractor?.email].filter(Boolean).join(' · ')}</div>
          </div>
          <div style={{ textAlign: 'right' }}>
            <h2 style={{ margin: 0 }}>Invoice {b.invoice_number}</h2>
            <div className="small">{date(b.date)}</div>
            <div className="small">Call #{b.call_number} · {b.po}</div>
          </div>
        </div>
        <div>
          <div className="small muted">Bill to</div>
          <strong>{b.customer}</strong>
          <div className="small">{b.site?.name}{b.unit ? `, unit ${b.unit}` : ''} · {b.site?.address}</div>
        </div>
        {(b.problem || b.summary) && <div className="small"><strong>Work:</strong> {b.summary || b.problem}</div>}
        <table className="billtable">
          <thead><tr><th>Description</th><th className="num">Qty</th><th className="num">Rate</th><th className="num">Amount</th></tr></thead>
          <tbody>
            {(b.lines || []).map((l, i) => (
              <tr key={i}><td>{l.description}</td><td className="num">{Number(l.qty)} {l.unit}</td><td className="num">{l.rate == null ? '' : money(l.rate)}</td><td className="num">{l.amount == null ? '' : money(l.amount)}</td></tr>
            ))}
            <tr><td colSpan={3}><strong>Total</strong>{b.paid_at ? <span className="chip tone-green" style={{ marginLeft: 8 }}>PAID {date(b.paid_at)}</span> : null}</td><td className="num"><strong>{money(b.total)}</strong></td></tr>
          </tbody>
        </table>
        {(b.visits || []).length > 0 && (
          <div className="small stack" style={{ gap: 4 }}>
            <strong>Time on site, verified{b.flat ? ' (flat-rate bill: shown for reference)' : ''}</strong>
            {b.visits.map((v, i) => (
              <div key={i}>{v.tech}: arrived {dateTime(v.arrived)}{v.left ? `, left ${dateTime(v.left)}` : ''} ({hm(v.onsite_min)} on site){v.verified ? ', checked in with the store’s code' : ''}{Number(v.helpers) > 0 ? `, ${v.helpers} helper${Number(v.helpers) > 1 ? 's' : ''}` : ''}</div>
            ))}
          </div>
        )}
        {b.note && <div className="small">{b.note}</div>}
        <div className="small muted">Built from the verified record in Service Call Proof.</div>
      </div>
  );
}
