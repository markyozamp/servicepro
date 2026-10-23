'use client';

// QR sticker on a unit: any employee scans it, enters the location PIN (in the customer's own word), picks the problem. No login.
import { placeTerms } from '@/lib/terms';
import { useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import { act } from '@/lib/supabase';
import { LegalFooter } from '@/components/Legal';

export default function Report() {
  const { token } = useParams();
  const [d, setD] = useState(null);
  const [f, setF] = useState({ pin: '', issue: '', details: '', name: '', emergency: false });
  const [err, setErr] = useState('');
  const [done, setDone] = useState(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    try { const n = localStorage.getItem('sp_reporter'); if (n) setF((x) => ({ ...x, name: n })); } catch { /* none */ }
    act('qr_info', { p_token: token }).then(setD).catch((e) => setErr(e.message));
  }, [token]);

  async function send(e) {
    e.preventDefault();
    setBusy(true); setErr('');
    try {
      const r = await act('qr_report', { p_token: token, p_pin: f.pin, p_issue_type: f.issue || null, p_details: f.details || null,
        p_name: f.name, p_emergency: f.emergency });
      if (!r.ok) { setErr(r.error); setBusy(false); return; }
      try { localStorage.setItem('sp_reporter', f.name); } catch { /* none */ }
      setDone(r);
    } catch (x) { setErr(x.message); setBusy(false); }
  }

  return (
    <main className="login-wrap">
      <div className="login stack">
        <div style={{ textAlign: 'center' }}><div className="brand" style={{ fontSize: 24, color: 'var(--ink)' }}>Service Call <span style={{ color: 'var(--brand)' }}>Proof</span></div></div>
        <div className="panel panel-pad stack">
          {!d && !err && <div className="muted">Loading…</div>}
          {d && !d.ok && <div className="error">This sticker isn't recognized. Tell your manager.</div>}
          {d?.ok && (
            <>
              <div><div className="small muted">{d.store} · {d.site}</div><h2>{d.unit || 'This unit'}</h2></div>
              {d.open_calls.length > 0 && (
                <div className="notice small">Already reported: {d.open_calls.map((c) => `call #${c.number} (${c.problem}, ${c.opened})`).join('; ')}. A contractor is on it.</div>
              )}
              {done ? (
                <div className="stack">
                  <div className="notice"><strong>Sent.</strong> Call #{done.number} ({done.po}) went to {done.contractor}. Your manager can follow it on Service Call Proof.</div>
                </div>
              ) : !d.has_pin ? <div className="error">Your {placeTerms(d.place_word).one} hasn't set a reporting PIN yet. Ask your manager.</div> : (
                <form className="stack" onSubmit={send}>
                  {err && <div className="error">{err}</div>}
                  <label>What's wrong?
                    <select value={f.issue} onChange={(e) => setF({ ...f, issue: e.target.value })}>
                      <option value="">Something else (describe below)</option>
                      {d.issues.map((i) => <option key={i.id} value={i.id}>{i.name}{i.priority === 1 ? ' — urgent' : ''}</option>)}
                    </select></label>
                  <label>Details<textarea value={f.details} onChange={(e) => setF({ ...f, details: e.target.value })} placeholder="e.g. Reading 20°F, should be -5°F" /></label>
                  <label className="row small" style={{ gap: 6, fontWeight: 400 }}><input type="checkbox" style={{ width: 'auto' }} checked={f.emergency} onChange={(e) => setF({ ...f, emergency: e.target.checked })} /> Emergency (product at risk, leak, safety)</label>
                  <label>Your name<input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required /></label>
                  <label>{placeTerms(d.place_word).pin}<input className="codebox" inputMode="numeric" maxLength={6} value={f.pin} onChange={(e) => setF({ ...f, pin: e.target.value.replace(/\D/g, '') })} required /></label>
                  <button className="primary big" disabled={busy || f.pin.length < 4}>{busy ? 'Sending…' : 'Report problem'}</button>
                </form>
              )}
            </>
          )}
          {err && !d && <div className="error">{err}</div>}
        </div>
        <LegalFooter />
      </div>
    </main>
  );
}
