'use client';

import { useRouter } from 'next/navigation';
import { signOut } from '@/lib/useProfile';
import AlertsButton from './AlertsButton';

export default function TopBar({ profile, org, portal }) {
  const router = useRouter();
  return (
    <header className="topbar">
      <div className="brand">
        All Service <span>Flow</span> <span className="small muted" style={{ color: '#9fb0c0', fontWeight: 500 }}>· {portal}</span>
      </div>
      <div className="who">
        <span className="hide-sm">
          {profile?.full_name}
          {org ? ` — ${org.name}` : ''}
        </span>
        <AlertsButton />
        {profile?.is_technician && portal === 'Office' && <button onClick={() => router.push('/tech')}>My jobs (tech app)</button>}
        <button onClick={() => signOut(router)}>Sign out</button>
      </div>
    </header>
  );
}
