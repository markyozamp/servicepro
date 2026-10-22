'use client';

// The link from the "Reset your password" email: set a new password, then sign straight in.
import { useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import { supabase } from '@/lib/supabase';
import { portalFor } from '@/lib/useProfile';
import { LegalFooter } from '@/components/Legal';

export default function Reset() {
  const { token } = useParams();
  const router = useRouter();
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  async function save(e) {
    e.preventDefault();
    setErr('');
    if (pw.length < 10) return setErr('Use at least 10 characters.');
    if (pw !== pw2) return setErr('The two passwords don\'t match.');
    setBusy(true);
    try {
      await supabase.auth.signOut().catch(() => {});
      const { data, error } = await supabase.rpc('reset_password_with_token', { p_token: token, p_password: pw });
      if (error) throw new Error(error.message);
      const { error: e2 } = await supabase.auth.signInWithPassword({ email: data.email, password: pw });
      if (e2) throw new Error(e2.message);
      const { data: p } = await supabase.rpc('me');
      router.replace(p?.is_technician && !(p.is_org_admin || p.can_dispatch || p.can_bill) ? '/tech' : portalFor(p));
    } catch (e2) { setErr(e2.message); setBusy(false); }
  }

  return (
    <main className="login-wrap">
      <div className="login stack">
        <div style={{ textAlign: 'center' }}>
          <div className="brand" style={{ fontSize: 28, color: 'var(--ink)' }}>Service Call <span style={{ color: 'var(--brand)' }}>Proof</span></div>
        </div>
        <form className="panel panel-pad stack" onSubmit={save}>
          <h2>Set a new password</h2>
          {err && <div className="error">{err}</div>}
          <label>New password<input id="reset-pw" type="password" autoComplete="new-password" value={pw} onChange={(e) => setPw(e.target.value)} required /></label>
          <label>Type it again<input id="reset-pw2" type="password" autoComplete="new-password" value={pw2} onChange={(e) => setPw2(e.target.value)} required /></label>
          <button className="primary big" disabled={busy}>{busy ? 'Saving…' : 'Save and sign in'}</button>
          <div className="small muted">At least 10 characters. The link works once and expires an hour after it was sent.</div>
        </form>
        <LegalFooter />
      </div>
    </main>
  );
}
