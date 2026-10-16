'use client';

import { useRouter } from 'next/navigation';
import { signOut } from '@/lib/useProfile';

export default function TopBar({ profile, org, portal }) {
  const router = useRouter();
  return (
    <header className="topbar">
      <div className="brand">
        Service<span>Pro</span> <span className="small muted" style={{ color: '#9fb0c0', fontWeight: 500 }}>· {portal}</span>
      </div>
      <div className="who">
        <span className="hide-sm">
          {profile?.full_name}
          {org ? ` — ${org.name}` : ''}
        </span>
        <button onClick={() => signOut(router)}>Sign out</button>
      </div>
    </header>
  );
}
