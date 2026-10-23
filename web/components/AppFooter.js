'use client';

// Footer on every signed-in page: help, a useful tip, and the legal links.
import { useEffect, useState } from 'react';
import Link from 'next/link';

const TIPS = {
  store: [
    'Put a QR sticker on each unit: any employee can report a problem by scanning it, no login needed.',
    'Tap "Install on this computer" in the top bar to open Service Call Proof from your desktop like a program.',
    'Turn on alerts so you know the moment a technician arrives and needs the check-in code.',
    'List your warranties under Equipment: you\'ll be warned before paying for a repair that\'s still covered.',
    'Download your service calls anytime from Company & plan → Your data. It opens in Excel.',
    'A technician with no trip scheduled? Use "Someone\'s here we weren\'t expecting" and their office is told right away.',
  ],
  office: [
    'Schedule every trip with the store first: they\'ll see you under "Expected today" and your tech gets the check-in code ready.',
    'Enter your invoice against the store\'s PO: hours that match the verified time get approved faster.',
    'Your technicians can install the app on their phones from the menu: it works even with no signal.',
  ],
  tech: [
    'Tap "I\'m going" before you drive: the store sees you\'re on the way and your arrival is noticed automatically.',
    'No signal? Keep working: everything is saved on your phone and sent when you\'re back online.',
    'Going for parts? Use the parts run button so the time off site is explained on the invoice.',
  ],
};

export default function AppFooter({ kind = 'store' }) {
  const [tip, setTip] = useState('');
  useEffect(() => {
    const list = TIPS[kind] || TIPS.store;
    setTip(list[Math.floor(Math.random() * list.length)]);
  }, [kind]);
  return (
    <footer className="app-footer">
      <div className="app-footer-in">
        {tip && <div className="app-tip"><strong>Tip</strong> {tip}</div>}
        <div className="app-footer-row">
          <span><strong>Service Call Proof</strong> · Know who's in your building, and for how long.</span>
          <span className="app-footer-links">
            <Link href={`/help?for=${kind === 'office' ? 'contractor' : kind}`}><strong>How-to guide</strong></Link>
            <span>Need help? <a href="mailto:support@servicecallproof.com">support@servicecallproof.com</a></span>
            <Link href="/privacy">Privacy</Link>
            <Link href="/terms">Terms</Link>
          </span>
        </div>
      </div>
    </footer>
  );
}
