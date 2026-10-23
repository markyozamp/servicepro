'use client';

// One-page quick start for contractors and their technicians. Public, printable (prints on one sheet).
import Link from 'next/link';

export default function QuickStart() {
  return (
    <main className="qs">
      <div className="qs-head">
        <div className="brand" style={{ fontSize: 24, color: 'var(--ink)' }}>Service Call <span style={{ color: 'var(--brand)' }}>Proof</span></div>
        <div className="qs-actions no-print">
          <button type="button" className="primary" onClick={() => window.print()}>Print this page</button>
          <Link href="/help?for=contractor">Full how-to guide</Link>
        </div>
      </div>
      <h1>Quick start for contractors and technicians</h1>
      <p className="qs-lead">Your customer sends service calls through Service Call Proof. <strong>It's free for you.</strong> Setup takes about 5 minutes.</p>

      <div className="qs-cols">
        <section>
          <h2>Owner / office: set up once</h2>
          <ol>
            <li><strong>Open the sign-in link</strong> your customer sent you (text or email). No password needed. Read their terms and tap <em>I agree — sign in</em>.</li>
            <li><strong>Add your office phone:</strong> Team → Who gets the calls → Office phone → Save.</li>
            <li><strong>Add your technicians:</strong> Team → add each tech with their mobile number → <em>Text it</em>. Each tech gets their own link.</li>
            <li><strong>Put the app on your phone:</strong> menu → <em>Install on this phone</em> (iPhone: Share → Add to Home Screen).</li>
          </ol>
          <h2>Every call</h2>
          <ol>
            <li>A new call arrives: phone alert, email, and the <strong>Today</strong> list.</li>
            <li><strong>Accept it</strong> before the customer's deadline shown on the call: <em>on the way now</em> or a scheduled time.</li>
            <li><strong>Send a tech</strong> (or go yourself).</li>
            <li>Job done: open the call, <strong>agree to the verified hours</strong> and that you're within the PO, then type <strong>your invoice # and total</strong>. About 15 seconds.</li>
          </ol>
        </section>
        <section>
          <h2>Technicians: on the job</h2>
          <ol>
            <li><strong>Open your own link</strong> on your phone, once. Then <em>Install</em> so it's on your home screen.</li>
            <li>Leaving for the job? Tap <strong>I'm going</strong> when you actually leave. Your drive time counts from that tap, and the customer sees the town you're starting from.</li>
            <li>On site, the app notices you've arrived (or tap <strong>I'm here</strong>). <strong>Ask the person on site for the check-in code</strong> and type it in.</li>
            <li>Need the customer to OK more money? Tap <strong>Request approval for more</strong> and wait for the answer on your phone.</li>
            <li>Going for parts? Tap <strong>🚚 Parts run</strong> so the time away is explained.</li>
            <li>Done? Tap <strong>Leaving</strong> and say whether the job is finished or needs another trip.</li>
          </ol>
          <div className="qs-box">
            <strong>Good to know</strong>
            <ul>
              <li>No signal? Keep going. Taps are saved and sent when you're back online.</li>
              <li>Your location is saved only when you tap a button or arrive. The customer sees the town only, never the exact spot. You're never tracked between calls.</li>
              <li>Link expired or lost your phone? Ask your office for a new sign-in link.</li>
            </ul>
          </div>
        </section>
      </div>
      <p className="qs-foot">Help: servicecallproof.com/help · support@servicecallproof.com</p>
    </main>
  );
}
