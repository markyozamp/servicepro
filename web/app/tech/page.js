'use client';

import { useProfile } from '@/lib/useProfile';
import TopBar from '@/components/TopBar';

export default function TechPlaceholder() {
  const { profile, org } = useProfile('/tech');
  if (!profile) return <div className="page muted">Loading…</div>;
  return (
    <>
      <TopBar profile={profile} org={org} portal="Technician" />
      <main className="page">
        <div className="panel panel-pad stack">
          <h1>Technician app</h1>
          <div>The technician side runs on the phone app (coming next): job list, Start, automatic arrival, photos, and Complete.</div>
        </div>
      </main>
    </>
  );
}
