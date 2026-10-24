'use client';

// The printable bill (Base): the contractor's itemized bill for one call, with the verified visits on it.
// Both sides can open it; Print or "Save as PDF" from the browser.
import { useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import { act } from '@/lib/supabase';
import { useProfile } from '@/lib/useProfile';
import BillDoc from '@/components/BillDoc';

export default function Bill() {
  const { id } = useParams();
  const { profile } = useProfile();
  const [b, setB] = useState(null);
  const [err, setErr] = useState('');
  useEffect(() => {
    if (!profile) return;
    act('bill_view', { p_wo: id }).then((r) => (r ? setB(r) : setErr('There is no bill for this call yet.'))).catch((e) => setErr(e.message));
  }, [profile, id]);

  if (err) return <main className="page"><div className="error">{err}</div></main>;
  if (!b) return <main className="page muted">Loading…</main>;
  return (
    <main className="page billpage">
      <div className="row noprint" style={{ justifyContent: 'flex-end', gap: 8 }}>
        <button className="primary" onClick={() => window.print()}>Print / save as PDF</button>
        <button onClick={() => window.close()}>Close</button>
      </div>
      {b.draft && <div className="notice noprint">Draft: not sent yet.</div>}
      <BillDoc b={b} />
    </main>
  );
}
