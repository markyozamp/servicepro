'use client';

// Start link for a store that bought Service Call Proof: set up the company, the owner's login and the first location.
import { useEffect, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import { supabase, act } from '@/lib/supabase';
import AddressFinder from '@/components/AddressFinder';
import { LegalFooter } from '@/components/Legal';

export default function Start() {
  const { token } = useParams();
  const router = useRouter();
  const [info, setInfo] = useState(null);
  const [f, setF] = useState({ company: '', name: '', email: '', phone: '', pw: '', pw2: '', site: '', addr: '' });
  const [found, setFound] = useState(null);
  const [agree, setAgree] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });

  useEffect(() => { act('join_info', { p_token: token }).then(setInfo).catch((e) => setErr(e.message)); }, [token]);
  const bad = info && (!info.ok || info.kind !== 'customer_start' || info.used || info.expired);

  async function go(e) {
    e.preventDefault();
    setErr('');
    if (f.pw.length < 10) return setErr('Use a password of at least 10 characters.');
    if (f.pw !== f.pw2) return setErr('The two passwords don\'t match.');
    if (!found) return setErr('Tap Find next to the address so we can place your location on the map.');
    if (!agree) return setErr('Please agree to the Terms of Service and Privacy Policy.');
    setBusy(true);
    try {
      await supabase.auth.signOut().catch(() => {});
      const r = await act('start_customer', { p_token: token, p_company: f.company, p_owner_name: f.name, p_email: f.email, p_phone: f.phone,
        p_password: f.pw, p_site_name: f.site || f.company, p_address: found.address, p_zip: found.zip, p_lat: found.lat, p_lon: found.lon, p_timezone: found.timezone });
      const { error } = await supabase.auth.signInWithPassword({ email: r.email, password: f.pw });
      if (error) throw new Error(error.message);
      router.replace('/store?welcome=1');
    } catch (e2) { setErr(e2.message); setBusy(false); }
  }

  return (
    <main className="login-wrap">
      <div className="login stack" style={{ width: 'min(520px, 100%)' }}>
        <div style={{ textAlign: 'center' }}>
          <div className="brand" style={{ fontSize: 28, color: 'var(--ink)' }}>Service Call <span style={{ color: 'var(--brand)' }}>Proof</span></div>
          <div className="muted small">Know who's in your building, and for how long.</div>
        </div>
        {!info && !err && <div className="panel panel-pad muted">Checking your link…</div>}
        {bad && <div className="panel panel-pad"><div className="error">{info.used ? 'This link was already used. Sign in with the email and password you chose.' : info.expired ? 'This link has expired. Ask Service Call Proof for a new one.' : 'This link is not valid.'}</div>
          <button style={{ marginTop: 10 }} onClick={() => router.push('/')}>Go to sign in</button></div>}
        {info?.ok && !bad && (
          <form className="panel panel-pad stack" onSubmit={go}>
            <h2>Set up your account</h2>
            <div className="small muted">Takes about two minutes. You can add more locations and invite your contractors right after.</div>
            {err && <div className="error">{err}</div>}
            <h3 style={{ marginTop: 6 }}>Your company</h3>
            <label>Company name<input id="st-company" value={f.company} onChange={set('company')} placeholder="e.g. M&L Market" required /></label>
            <h3 style={{ marginTop: 6 }}>You (the owner)</h3>
            <label>Your name<input id="st-name" value={f.name} onChange={set('name')} autoComplete="name" required /></label>
            <div className="row">
              <label className="grow">Email (your sign-in)<input id="st-email" type="email" value={f.email} onChange={set('email')} autoComplete="email" required /></label>
              <label className="grow">Mobile<input id="st-phone" type="tel" value={f.phone} onChange={set('phone')} autoComplete="tel" /></label>
            </div>
            <div className="row">
              <label className="grow">Password<input id="st-pw" type="password" value={f.pw} onChange={set('pw')} autoComplete="new-password" required /></label>
              <label className="grow">Type it again<input id="st-pw2" type="password" value={f.pw2} onChange={set('pw2')} autoComplete="new-password" required /></label>
            </div>
            <h3 style={{ marginTop: 6 }}>Your first location</h3>
            <label>Location name<input id="st-site" value={f.site} onChange={set('site')} placeholder="e.g. M&L Market — Main St" /></label>
            <AddressFinder id="st-addr" value={f.addr} onChange={(v) => setF({ ...f, addr: v })} onFound={setFound} found={found} />
            <div className="small muted">$395 per location per year, all trades, unlimited service calls. Your contractors use it free.</div>
            <label className="row small" style={{ gap: 6, fontWeight: 400, flexWrap: 'nowrap', alignItems: 'flex-start' }}>
              <input id="st-agree" type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} style={{ width: 'auto', marginTop: 3 }} />
              <span>I agree to the <a href="/terms" target="_blank" rel="noreferrer">Terms of Service</a> and <a href="/privacy" target="_blank" rel="noreferrer">Privacy Policy</a>.</span>
            </label>
            <button className="primary big" disabled={busy}>{busy ? 'Setting up…' : 'Create my account'}</button>
          </form>
        )}
        {err && !info && <div className="error">{err}</div>}
        <LegalFooter />
      </div>
    </main>
  );
}
