'use client';

// A customer's bill from the emailed link (no login): the itemized bill with the verified visits, to print or save as a PDF.
import { useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import { act } from '@/lib/supabase';
import BillDoc from '@/components/BillDoc';
import { dateTime } from '@/lib/format';
import { LegalFooter } from '@/components/Legal';

export default function CustomerBill() {
  const { token } = useParams();
  const [b, setB] = useState(null);
  const [err, setErr] = useState('');
  useEffect(() => {
    act('bill_public', { p_token: token }).then((r) => (r ? setB(r) : setErr('This link isn’t valid. Ask whoever sent it for a new one.'))).catch((e) => setErr(e.message));
  }, [token]);
  if (err) return <main className="page"><div className="error">{err}</div></main>;
  if (!b) return <main className="page muted">Loading…</main>;
  return (
    <main className="page billpage">
      <div className="row noprint" style={{ justifyContent: 'space-between', gap: 8 }}>
        <span>{b.paid ? <span className="chip tone-green">Paid {dateTime(b.paid_at)}</span> : <span className="small muted">Pay {b.contractor?.name} the way you usually do. Paying online here is coming.</span>}</span>
        <button className="primary" onClick={() => window.print()}>Print / save as PDF</button>
      </div>
      <BillDoc b={b} />
      <div className="noprint"><LegalFooter /></div>
    </main>
  );
}
