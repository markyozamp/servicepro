'use client';

import { useRouter } from 'next/navigation';
import { signOut } from '@/lib/useProfile';
import AlertsButton from './AlertsButton';
import PasswordButton from './PasswordButton';
import HeaderMenu from './HeaderMenu';
import InstallButton from './InstallButton';
import UpgradeButton from './UpgradeButton';

export default function TopBar({ profile, org, portal }) {
  const router = useRouter();
  return (
    <header className="topbar">
      <div className="brand">
        Service Call <span>Proof</span> <span className="small muted" style={{ color: '#9fb0c0', fontWeight: 500 }}>· {portal}</span>
      </div>
      <HeaderMenu name={`${profile?.full_name || ''}${org ? ` — ${org.name}` : ''}`}>
        <div className="hdr-who">{profile?.full_name}{org ? ` — ${org.name}` : ''}</div>
        <AlertsButton />
        {profile?.is_technician && portal === 'Office' && <button onClick={() => router.push('/tech')}>My jobs (tech app)</button>}
        {profile?.contractor_id && profile?.is_org_admin && <UpgradeButton />}
        <InstallButton />
        <PasswordButton />
        <button onClick={() => signOut(router)}>Sign out</button>
      </HeaderMenu>
    </header>
  );
}
