'use client';

import { useEffect, useState } from 'react';
import { pushState, turnOnPush } from '@/lib/push';

// Small button: turn on phone/computer alerts for this device.
export default function AlertsButton() {
  const [st, setSt] = useState(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { pushState().then(setSt).catch(() => setSt('unsupported')); }, []);
  if (!st || st === 'on' || st === 'unsupported') return null;
  return (
    <button disabled={busy} title={st === 'blocked' ? 'Alerts are blocked in this browser’s settings' : ''} onClick={async () => {
      setBusy(true);
      try { setSt(await turnOnPush()); } catch (e) { window.alert(e.message); } finally { setBusy(false); }
    }}>🔔 {st === 'blocked' ? 'Alerts blocked' : 'Turn on alerts'}</button>
  );
}
