import { LegalPage, LEGAL } from '@/components/Legal';

export const metadata = { title: 'Privacy Policy · Service Call Proof' };

export default function Privacy() {
  const { operator, email, site } = LEGAL;
  return (
    <LegalPage title="Privacy Policy">
      <p>
        Service Call Proof ({site}) is operated by {operator} (&ldquo;we,&rdquo; &ldquo;us&rdquo;). It helps stores, property managers,
        homeowners and their service contractors keep a shared record of service calls: who was sent, when they arrived and left,
        and what was billed. This policy explains what information we collect, why, and the choices you have.
      </p>

      <h2>Who uses Service Call Proof</h2>
      <ul>
        <li><strong>Customers</strong> — stores, property managers and homeowners who open service calls and check the work.</li>
        <li><strong>Contractors</strong> — service companies that accept calls, dispatch technicians and send invoices.</li>
        <li><strong>Technicians</strong> — the people who go on calls, using the phone app.</li>
      </ul>
      <p>
        A customer or contractor (&ldquo;your organization&rdquo;) sets up most accounts. Your organization decides what information it
        enters and who on its team can see it. For that information we act on your organization&rsquo;s behalf.
      </p>

      <h2>Information we collect</h2>
      <ul>
        <li><strong>Account details:</strong> name, job title, work email, mobile number, company, and which locations or teams you belong to.</li>
        <li><strong>Service call records:</strong> PO numbers, problem descriptions, equipment, scheduled times, notes, quotes, invoices and approvals.</li>
        <li>
          <strong>Visit times:</strong> when a technician taps &ldquo;I&rsquo;m going,&rdquo; arrives, checks in with the store&rsquo;s code,
          leaves for parts, returns and leaves the site.
        </li>
        <li>
          <strong>Location at those moments only:</strong> when a technician taps one of those buttons, or arrives at the site, the phone&rsquo;s
          location at that moment is saved with the record so the arrival or departure can be confirmed. While a technician is on the way to
          a call with the app open, the phone compares its own position with the site to notice arrival automatically; that route is
          <strong> not</strong> saved or sent to us. <strong>We do not track technicians in the background, between calls, or after hours.</strong>{' '}
          A technician can deny location access in the phone&rsquo;s settings; arrival is then confirmed by the check-in code instead.
        </li>
        <li><strong>Photos</strong> a technician chooses to take for a call, such as equipment nameplates or finished work.</li>
        <li><strong>Visitor log entries</strong> a store adds when someone arrives who wasn&rsquo;t expected.</li>
        <li><strong>Alert settings:</strong> if you turn on phone alerts, a notification address from your browser so we can send them.</li>
        <li><strong>Technical information:</strong> sign-in records, device and browser type, and error logs needed to keep the service working and secure.</li>
      </ul>
      <p>We do not collect payment card numbers in the app, and we do not use advertising trackers or sell ad space.</p>

      <h2>How we use it</h2>
      <ul>
        <li>To run the service: deliver service calls, show who is expected and who is in the building, check invoices against verified time, and keep the PO log.</li>
        <li>To send the alerts you or your organization turn on, by phone notification, email or text message.</li>
        <li>To bill the customer account for its locations.</li>
        <li>To keep accounts secure, prevent misuse, fix problems and improve the service.</li>
        <li>To meet legal obligations.</li>
      </ul>

      <h2>Who can see it</h2>
      <p>
        Records about a service call are shared between the customer and the contractor on that call, as the service is designed to do —
        for example, the store sees which technician was sent and when he checked in; the contractor sees the store&rsquo;s PO and approvals.
        Within each organization, what a person can see depends on the role their administrator gives them.
      </p>
      <p>We share information outside those parties only:</p>
      <ul>
        <li>
          With service providers that host and run the service for us — database and hosting (Supabase, Vercel), email delivery (Resend),
          text message delivery (Twilio), and accounting connections your organization chooses to turn on (such as QuickBooks). They may use
          the information only to provide their services to us.
        </li>
        <li>When required by law, or to protect the safety, rights or property of our users, the public or us.</li>
        <li>As part of a merger, sale or transfer of our business, with notice to you.</li>
      </ul>
      <p>
        <strong>We do not sell personal information. Mobile numbers and text message consent are never shared with or sold to third parties
        or affiliates for their marketing or promotional purposes.</strong> Text messaging originator opt-in data and consent are not shared
        with any third parties, except the text message providers that deliver our messages.
      </p>

      <h2>Text messages</h2>
      <p>
        If you give a mobile number and agree to receive texts, we send transactional messages about service calls: new calls, a technician on
        the way, a technician waiting for your check-in code, job finished, quotes to approve and invoice notices. We do not send marketing texts.
        Message frequency varies with your service calls. Message and data rates may apply. Reply <strong>STOP</strong> to stop or{' '}
        <strong>HELP</strong> for help, or contact {email}.
      </p>

      <h2>How long we keep it</h2>
      <p>
        We keep service call records for as long as your organization&rsquo;s account is active, because stores and contractors rely on them for
        invoices, disputes, warranties and audits. When an account closes we delete or anonymize its records within 12 months, unless the law
        requires us to keep them longer. Error and security logs are kept for a shorter time.
      </p>

      <h2>Security</h2>
      <p>
        Information is sent over encrypted connections and stored with access controls, so each organization sees only its own records and the
        calls it shares. Store PINs are stored in scrambled (hashed) form, check-in codes are good for one visit only, and sign-in links work once and expire. No system is perfectly
        secure; if we learn of a breach affecting your information, we will notify you as the law requires.
      </p>

      <h2>Your choices and rights</h2>
      <ul>
        <li>Ask your organization&rsquo;s administrator to correct your details or remove your account.</li>
        <li>Turn phone alerts off at any time, and reply STOP to stop texts.</li>
        <li>Turn off location access for the app in your phone&rsquo;s settings.</li>
        <li>
          Contact us at {email} to ask for a copy of your information, a correction or deletion. Depending on where you live you may have
          further rights under state privacy laws; we will honor them. Because service records also belong to the other party on the call,
          we may need to keep a record of a visit even after your account is removed, with your name replaced.
        </li>
      </ul>

      <h2>Children</h2>
      <p>Service Call Proof is a business tool and is not meant for anyone under 16. We do not knowingly collect information from children.</p>

      <h2>Changes</h2>
      <p>If we change this policy we will post the new version here with a new effective date, and tell account administrators about important changes before they take effect.</p>

      <h2>Contact</h2>
      <p>Questions or requests: <a href={`mailto:${email}`}>{email}</a>.</p>
    </LegalPage>
  );
}
