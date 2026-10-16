'use client';

// No-login approval page for a building owner or a one-time homeowner.
// The link itself is the key: it opens this one quote and nothing else.
import { useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import { act } from '@/lib/supabase';
import { money, dateTime } from '@/lib/format';

export default function Approve() {
  const { token } = useParams();
  const [d, setD] = useState(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [declining, setDeclining] = useState(false);
  const [note, setNote] = useState('');

  async function load() {
    try {
      const r = await act('link_quote', { p_token: token });
      if (!r) setErr('This link is not valid. Ask whoever sent it for a new one.');
      setD(r);
    } catch (e) {
      setErr(e.message);
    }
  }
  useEffect(() => { load(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [token]);

  async function decide(approve) {
    setBusy(true); setErr('');
    try {
      await act('link_decide', { p_token: token, p_approve: approve, p_note: approve ? null : note });
      await load();
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  const owner = d?.audience === 'owner';
  const b = d?.breakdown;
  return (
    <main className="login-wrap">
      <div className="login stack" style={{ width: 'min(480px, 100%)' }}>
        <div style={{ textAlign: 'center' }}>
          <div className="brand" style={{ fontSize: 24, color: 'var(--ink)' }}>Service<span style={{ color: 'var(--brand)' }}>Pro</span></div>
          <div className="muted small">Repair approval</div>
        </div>
        {err && <div className="error">{err}</div>}
        {!d && !err && <div className="panel panel-pad muted">Loading…</div>}
        {d && (
          <div className="panel panel-pad stack">
            <div>
              <div className="small muted">{d.contractor} · Call #{d.call_number} · {d.po}</div>
              <h2 style={{ margin: '4px 0' }}>{d.property}{d.unit ? `, unit ${d.unit}` : ''}</h2>
              <div className="small muted">{d.address}</div>
            </div>
            <div><strong>Problem:</strong> {d.problem}</div>
            <div className="stack" style={{ gap: 4, background: 'var(--bg)', borderRadius: 8, padding: 12 }}>
              <div className="spread"><strong>{d.description}</strong><strong style={{ fontSize: 22 }}>{money(d.amount)}</strong></div>
              {b && Array.isArray(b.parts) && b.parts.map((p, i) => (
                <div key={i} className="small">{p.name} × {p.qty ?? 1}{p.price != null ? ` — ${money(p.price)}` : ''}</div>
              ))}
              {b?.labor_hours != null && <div className="small">Labor: {b.labor_hours} hr</div>}
            </div>
            <div className="small muted">
              Already approved on this call: {money(d.approved_so_far)}. With this, the call totals {money(d.total_if_approved)}.
              {owner && d.owner_limit != null && ` Your approval is needed above ${money(d.owner_limit)}.`}
              {owner && d.manager && ` ${d.manager} (${d.customer}) has already approved it.`}
              {d.photos > 0 && ` The technician took ${d.photos} photo${d.photos > 1 ? 's' : ''}.`}
            </div>

            {d.state === 'pending' ? (
              declining ? (
                <div className="stack">
                  <label>Why are you declining? <span className="muted" style={{ fontWeight: 400 }}>(the contractor will see this)</span>
                    <textarea value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Please call me first" />
                  </label>
                  <div className="row">
                    <button className="danger big grow" disabled={busy || note.trim().length < 3} onClick={() => decide(false)}>Decline</button>
                    <button className="big" disabled={busy} onClick={() => setDeclining(false)}>Back</button>
                  </div>
                </div>
              ) : (
                <div className="row">
                  <button className="primary big grow" disabled={busy} onClick={() => decide(true)}>{busy ? 'Saving…' : `Approve ${money(d.amount)}`}</button>
                  <button className="big" disabled={busy} onClick={() => setDeclining(true)}>Decline</button>
                </div>
              )
            ) : (
              <div className={`notice`} style={{ fontWeight: 600 }}>
                {d.state === 'approved' ? 'Approved' : d.state === 'declined' ? 'Declined' : 'Already handled'}
                {d.decided_at ? ` · ${dateTime(d.decided_at)}` : ''}. Thank you — the contractor has been told.
              </div>
            )}
            {d.contractor_phone && <div className="small muted">Questions? Call {d.contractor} at <a href={`tel:${d.contractor_phone}`}>{d.contractor_phone}</a>.</div>}
          </div>
        )}
      </div>
    </main>
  );
}
