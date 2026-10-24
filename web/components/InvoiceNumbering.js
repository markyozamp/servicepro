'use client';

// Base and up: how your built bills are numbered (e.g. "PP-" then 1042, 1043 …).
import { useEffect, useState } from 'react';
import { supabase, act, q } from '@/lib/supabase';

export default function InvoiceNumbering({ profile }) {
  const [f, setF] = useState({ prefix: '', next: '' });
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  useEffect(() => {
    if (!profile?.contractor_id) return;
    q(supabase.from('contractors').select('invoice_prefix, next_invoice_no').eq('id', profile.contractor_id).single())
      .then((r) => setF({ prefix: r.invoice_prefix || '', next: r.next_invoice_no ?? '' })).catch(() => {});
  }, [profile]);
  if (!(profile?.is_org_admin || profile?.can_bill)) return null;
  return (
    <div className="panel panel-pad stack" style={{ gap: 8 }}>
      <h3>Invoice numbers</h3>
      <div className="small muted">Bills the app writes for you are numbered from here. Start where your own numbering leaves off, so nothing doubles up.</div>
      <form className="row" style={{ alignItems: 'flex-end' }} onSubmit={async (e) => {
        e.preventDefault(); setErr(''); setMsg('');
        try { const r = await act('set_invoice_numbering', { p_prefix: f.prefix, p_next: f.next === '' ? null : Number(f.next) }); setMsg(`Saved. Next bill: ${r.next}`); }
        catch (x) { setErr(x.message); }
      }}>
        <label style={{ flex: '0 0 120px' }}>Starts with<input value={f.prefix} onChange={(e) => setF({ ...f, prefix: e.target.value })} placeholder="e.g. PP-" /></label>
        <label style={{ flex: '0 0 140px' }}>Next number<input type="number" min="1" value={f.next} onChange={(e) => setF({ ...f, next: e.target.value })} placeholder="1001" /></label>
        <button>Save</button>
      </form>
      {err && <div className="error">{err}</div>}
      {msg && <div className="notice small">{msg}</div>}
    </div>
  );
}
