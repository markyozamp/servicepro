'use client';

// Phone / computer alerts (web push). On iPhone this works once All Service Flow is added to the Home Screen.
import { act } from './supabase';

export const VAPID_PUBLIC = 'BPA3sWa1d2hEphpa0xf8hRXStbDVc5sQas7SBtmM7Jcqo27JZe0tZi4cjui0VoxaBG4qjvcrMPkqSXf-CZj7MtE';

const b64 = (s) => {
  const pad = '='.repeat((4 - (s.length % 4)) % 4);
  const raw = atob((s + pad).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
};

export function pushSupported() {
  return typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
}

export async function pushState() {
  if (!pushSupported()) return 'unsupported';
  if (Notification.permission === 'denied') return 'blocked';
  const reg = await navigator.serviceWorker.getRegistration();
  const sub = reg && (await reg.pushManager.getSubscription());
  return sub ? 'on' : 'off';
}

export async function turnOnPush() {
  if (!pushSupported()) throw new Error('This browser cannot show alerts. On iPhone, add All Service Flow to your Home Screen first, then open it from there.');
  const perm = await Notification.requestPermission();
  if (perm !== 'granted') throw new Error('Alerts were not allowed. You can allow them in your phone settings.');
  const reg = (await navigator.serviceWorker.getRegistration()) || (await navigator.serviceWorker.register('/sw.js'));
  await navigator.serviceWorker.ready;
  let sub = await reg.pushManager.getSubscription();
  if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64(VAPID_PUBLIC) });
  const j = sub.toJSON();
  await act('save_push_subscription', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth });
  return 'on';
}
