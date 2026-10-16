'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabase } from './supabase';

export const homeFor = (role) =>
  ({
    contractor_admin: '/office',
    dispatcher: '/office',
    technician: '/tech',
    customer_admin: '/store',
    customer_user: '/store',
    platform_admin: '/office',
  })[role] || '/';

// Loads the signed-in person's profile. Sends them to sign-in if not signed in,
// or to their own portal if they opened the wrong one.
export function useProfile(allowedRoles) {
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
        await supabase.auth.signOut();
        return router.replace('/?e=noprofile');
      }
      if (allowedRoles && !allowedRoles.includes(p.role)) return router.replace(homeFor(p.role));
      setProfile(p);
      const table = p.contractor_id ? 'contractors' : 'customers';
      const id = p.contractor_id || p.customer_id;
      if (id) {
        const { data: o } = await supabase.from(table).select('id, name').eq('id', id).single();
        if (alive) setOrg(o);
      }
    })();
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return { profile, org };
}

export async function signOut(router) {
  await supabase.auth.signOut();
  router.replace('/');
}
