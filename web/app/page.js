'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabase } from '@/lib/supabase';
import { portalFor } from '@/lib/useProfile';

// Demo logins — remove this list before real customers use the site.
const DEMO = [
  { email: 'store@northside.demo', who: 'Store manager (Store #114)', org: 'Northside Grocers · approves up to $500' },
  { email: 'maint@northside.demo', who: 'Maintenance manager', org: 'Northside Grocers · all stores · up to $2,500' },
  { email: 'director@northside.demo', who: 'Director of operations', org: 'Northside Grocers · no limit' },
  { email: 'dispatch@arcticair.demo', who: 'Dispatcher', org: 'Arctic Air Mechanical' },
  { email: 'tech@arcticair.demo', who: 'Technician (phone app)', org: 'Arctic Air Mechanical · Mike' },
  { email: 'office@arcticair.demo', who: 'Owner / billing', org: 'Arctic Air Mechanical' },
  { email: 'pm@redriverpm.demo', who: 'Property manager', org: 'Red River Property Mgmt · up to $2,500 · owners approve above their limit' },
  { email: 'maint@redriverpm.demo', who: 'Maintenance coordinator', org: 'Red River Property Mgmt · up to $500' },
];
const DEMO_PASSWORD = 'DemoService2026!';

export default function SignIn() {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  useEffect(() => {
    if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
    if (typeof window !== 'undefined' && window.location.search.includes('e=noprofile')) {
      setErr('This login is not set up with a company yet. Contact your administrator.');
    }
    supabase.auth.getSession().then(async ({ data }) => {
      if (data.session) {
        const { data: p } = await supabase.rpc('me');
        if (p && p.id) router.replace(portalFor(p));
      }
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function signIn(e, as) {
    if (e) e.preventDefault();
    setBusy(true);
    setErr('');
    const creds = as ? { email: as, password: DEMO_PASSWORD } : { email: email.trim(), password };
    const { error } = await supabase.auth.signInWithPassword(creds);
    if (error) {
      setErr(error.message === 'Invalid login credentials' ? 'Email or password is incorrect.' : error.message);
      setBusy(false);
      return;
    }
    const { data: p } = await supabase.rpc('me');
    if (!p || !p.id) {
      setErr('This login is not set up with a company yet.');
      await supabase.auth.signOut();
      setBusy(false);
      return;
    }
    router.replace(portalFor(p));
  }

  return (
    <main className="login-wrap">
      <div className="login stack">
        <div style={{ textAlign: 'center', marginBottom: 8 }}>
          <div className="brand" style={{ fontSize: 28, color: 'var(--ink)' }}>
            Service<span style={{ color: 'var(--brand)' }}>Pro</span>
          </div>
          <div className="muted small">Proof of work. No surprise invoices.</div>
        </div>

        <form className="panel panel-pad stack" onSubmit={signIn}>
          <h2>Sign in</h2>
          {err && <div className="error">{err}</div>}
          <label>
            Email
            <input type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </label>
          <label>
            Password
            <input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
          </label>
          <button className="primary big" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
        </form>

        <div className="panel panel-pad stack demo-list">
          <div>
            <h3>Demo accounts</h3>
            <div className="muted">One tap signs in as each side of the same service calls.</div>
          </div>
          {DEMO.map((d) => (
            <button key={d.email} type="button" disabled={busy} onClick={() => signIn(null, d.email)}>
              <span><strong>{d.who}</strong> <span className="muted">· {d.org}</span></span>
              <span className="muted">→</span>
            </button>
          ))}
        </div>
      </div>
    </main>
  );
}
