'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabase } from './supabase';

// Which portal a person belongs in
export const portalFor = (p) => {
  if (!p) return '/';
  if (p.customer_id) return '/store';
  if (p.contractor_id) {
    const office = p.is_org_admin || p.can_dispatch || p.can_bill;
    return office ? '/office' : '/tech';
  }
  if (p.is_platform_admin) return '/office';
  return '/';
};

// Loads the signed-in person. Sends them to sign-in if not signed in,
// or to their own portal if they opened the wrong one.
export function useProfile(portal) {
  const router = useRouter();
  const [profile, setProfile] = useState(null);
  const [org, setOrg] = useState(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data: s } = await supabase.auth.getSession();
      if (!s.session) return router.replace('/');
      const { data: p } = await supabase.rpc('me');
      if (!alive) return;
      if (!p || !p.id) {
        await supabase.auth.signOut({ scope: 'local' }).catch(() => {});
        return router.replace('/?e=noprofile');
      }
      if (portal && portalFor(p) !== portal) return router.replace(portalFor(p));
      setProfile(p);
      const table = p.contractor_id ? 'contractors' : 'customers';
      const id = p.contractor_id || p.customer_id;
      if (id) {
        const { data: o } = await supabase.from(table).select('*').eq('id', id).single();
        if (alive) setOrg(o);
      }
    })();
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return { profile, org };
}

export const isDemoEmail = (e) => /\.demo$/i.test(e || '');

// Sign out of THIS browser only (never other devices — demo logins are shared), and leave right away even on a slow network.
export async function signOutLocal() {
  await Promise.race([supabase.auth.signOut({ scope: 'local' }).catch(() => {}), new Promise((r) => setTimeout(r, 1500))]);
  try { localStorage.removeItem('sp_me'); } catch { /* fine */ }
}

export async function signOut(router, profile) {
  const demo = isDemoEmail(profile?.email);
  await signOutLocal();
  window.location.replace(demo ? '/demo' : '/');
}
