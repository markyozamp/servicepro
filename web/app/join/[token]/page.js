'use client';

// Sign-in link for contractors and technicians: opening it signs this phone in. No password to remember.
import { useEffect, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import { supabase, act } from '@/lib/supabase';
import { portalFor } from '@/lib/useProfile';

export default function Join() {
  const { token } = useParams();
  const router = useRouter();
  const [info, setInfo] = useState(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    act('join_info', { p_token: token }).then(setInfo).catch((e) => setErr(e.message));
  }, [token]);

  async function go() {
    setBusy(true); setErr('');
    try {
      await supabase.auth.signOut().catch(() => {});
      const r = await act('join_redeem', { p_token: token });
      const { error } = await supabase.auth.signInWithPassword({ email: r.email, password: r.password });
      if (error) throw new Error(error.message);
      const { data: p } = await supabase.rpc('me');
      router.replace(p?.is_technician && !(p.is_org_admin || p.can_dispatch || p.can_bill) ? '/tech' : portalFor(p));
    } catch (e) {
      setErr(e.message); setBusy(false);
    }
  }

  const bad = info && (!info.ok || info.used || info.expired);
  return (
    <main className="login-wrap">
      <div className="login stack">
        <div style={{ textAlign: 'center' }}>
          <div className="brand" style={{ fontSize: 28, color: 'var(--ink)' }}>All Service <span style={{ color: 'var(--brand)' }}>Flow</span></div>
        </div>
        <div className="panel panel-pad stack">
          {!info && !err && <div className="muted">Checking your link…</div>}
          {err && <div className="error">{err}</div>}
          {bad && <div className="error">{!info.ok ? 'This link is not valid.' : info.used ? 'This link was already used.' : 'This link has expired.'} Ask whoever sent it for a new one.</div>}
          {info?.ok && !bad && (
            <>
              <h2>Welcome{info.name ? `, ${info.name.split(' ')[0]}` : ''}</h2>
              {info.kind === 'contractor_owner'
                ? <div><strong>{info.invited_by}</strong> will send their service calls to <strong>{info.company}</strong> through All Service Flow. It's free for you: you'll get each call as a PO, your techs tap "I'm going", "I'm here" and "Leaving", and you enter your invoice against the PO.</div>
                : <div>Sign in to <strong>{info.company}</strong> on this phone.</div>}
              {info.kind === 'contractor_owner' && info.terms && (
                <div className="notice small stack" style={{ gap: 4 }}>
                  <strong>{info.invited_by}'s terms — by signing in you agree to them:</strong>
                  <span>• Every trip is scheduled with the store before you go, and your technician checks in with the store's code when he arrives.</span>
                  <span>• The store pays for time verified in All Service Flow. {info.terms.unverified_time === 'no_pay' ? 'Time not checked in is not paid.' : 'Time not checked in is paid only if the store approves it.'}</span>
                  <span>• Travel time: {info.terms.pays_travel === 'yes' ? 'paid' : info.terms.pays_travel === 'no' ? 'not paid' : 'paid after hours only'}.</span>
                  <span>• Accept new calls within {info.terms.accept_emergency_min} minutes for emergencies and {Math.round(info.terms.accept_normal_min / 60)} hours otherwise.</span>
                  <span>• Enter your invoice against the store's PO.</span>
                </div>
              )}
              <div className="small muted">No password: this link signs in this phone and keeps it signed in. It works once — if you change phones, ask for a new link.</div>
              <button className="primary big" disabled={busy} onClick={go}>{busy ? 'Signing in…' : info.kind === 'contractor_owner' ? 'I agree — sign in on this phone' : 'Sign in on this phone'}</button>
              <div className="small muted">Tip: after signing in, use your browser's "Add to Home Screen" so All Service Flow opens like an app.</div>
            </>
          )}
        </div>
      </div>
    </main>
  );
}
