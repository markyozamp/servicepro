import Link from 'next/link';
import { LegalPage, LEGAL } from '@/components/Legal';

export const metadata = { title: 'Terms of Service · Service Call Proof' };

export default function Terms() {
  const { operator, email, site, state, county } = LEGAL;
  return (
    <LegalPage title="Terms of Service">
      <p>
        These terms are an agreement between you and {operator} (&ldquo;we,&rdquo; &ldquo;us&rdquo;) for the use of Service Call Proof at {site}
        and its phone app (the &ldquo;Service&rdquo;). If you use the Service for a company, you agree for that company and confirm you may do so.
        If you do not agree, do not use the Service.
      </p>

      <h2>1. What the Service does</h2>
      <p>
        Service Call Proof lets customers (businesses such as stores, restaurants, clinics and offices, property managers and homeowners) send service calls to contractors and keep a shared record
        of each visit: who was scheduled, when they arrived, checked in, left for parts and left, and how the invoice compares with the time
        recorded. Our <Link href="/privacy">Privacy Policy</Link> explains how we handle information.
      </p>

      <h2>2. We are a record, not a party to your work</h2>
      <p>
        The agreement for the repair or maintenance work is between the customer and the contractor. We do not perform, supervise or guarantee
        the work, and we are not responsible for its quality, safety, price or timing, or for any payment between customers and contractors.
        Rules a customer sets in the Service — for example, that time not checked in is not paid, travel terms, or how quickly calls must be
        accepted — are that customer&rsquo;s terms with its contractor. A contractor who accepts them through the Service agrees to them with that
        customer, not with us.
      </p>

      <h2>3. Accounts</h2>
      <ul>
        <li>Keep your sign-in, sign-in links and PINs to yourself. You are responsible for what is done under your account.</li>
        <li>Administrators are responsible for who they invite, the roles they give, and removing people who leave.</li>
        <li>Give accurate information, and tell us promptly at {email} if you think your account has been misused.</li>
      </ul>

      <h2>4. Fair use of the records</h2>
      <p>You agree not to:</p>
      <ul>
        <li>enter false visit times, check in for someone else, share check-in codes so a visit can be recorded without being on site, or alter photos or records to mislead;</li>
        <li>use the Service to track people outside of service calls, or for anything unlawful, harassing or unsafe;</li>
        <li>try to get into accounts or data that are not yours, disrupt the Service, or copy, resell or reverse-engineer it;</li>
        <li>send texts to people who have not agreed to receive them.</li>
      </ul>
      <p>We may suspend accounts that break these rules or put others at risk.</p>

      <h2>5. Accuracy of times and locations</h2>
      <p>
        Times come from the phone or computer used, and locations from the phone&rsquo;s GPS, which can be wrong, delayed or unavailable — for
        example with no signal, a dead battery, or location turned off. Offline actions are saved on the phone and sent when it reconnects.
        Where a trip started is shown to the customer as the nearest town and an estimated distance and drive time; these are estimates
        from map data, not exact road distances.
        The Service is a strong record of a visit, but customers and contractors should review flags and discuss differences with each other
        before acting on them. We are not liable for decisions made on records that turn out to be incomplete or inaccurate.
      </p>

      <h2>6. Safety</h2>
      <p>
        Showing who is expected and who is in the building helps customers stay aware of who is on site. It is not a security system and does not
        replace a customer&rsquo;s own check-in, key and safety procedures. In an emergency call 911.
      </p>

      <h2>7. Fees</h2>
      <ul>
        <li>Customers pay <strong>$395 per location per year</strong>, billed once a year in advance. It covers all trades, unlimited service calls and unlimited contractors.</li>
        <li><strong>Fair use.</strong> Phone notifications and email are included without limit. Text messages and automated phone calls are included up to a
          fair-use amount per location per year, shared across your company and shown in Settings &amp; plan. If you use more, you can add more for the
          rest of the year; we will not stop alerts for emergency calls.</li>
        <li>A location added during the year is charged for the rest of that year, so all of a customer&rsquo;s locations renew on the same date.</li>
        <li><strong>No refunds.</strong> You can cancel at any time; the account stays active to the end of the paid year and does not renew.</li>
        <li>Contractors and their technicians use the Service free of charge. Paid contractor plans, if chosen, are priced when offered.</li>
        <li>We will give at least 30 days&rsquo; notice before a price change takes effect at your renewal. Taxes are extra where they apply.</li>
      </ul>

      <h2>8. Text messages and alerts</h2>
      <p>
        If you give a mobile number and agree to texts, you will receive transactional messages about your service calls. Message frequency
        varies. Message and data rates may apply. Reply STOP to stop and HELP for help. Carriers are not liable for delayed or undelivered
        messages. Alerts depend on phones, networks and email providers we do not control, so do not rely on them alone for urgent matters.
      </p>

      <h2>9. Your information</h2>
      <p>
        Your organization owns the records it enters. You give us permission to store, process and display them to provide the Service, and to
        share call records with the other party on each call as the Service is designed to do. We may use anonymous, combined statistics (for
        example, average response times across all users) to run and improve the Service; these never identify you or your organization.
        You can export your PO log at any time.
      </p>

      <h2>10. Ending your use</h2>
      <p>
        You may stop using the Service at any time. We may end or suspend access for breaking these terms or non-payment, or stop offering the
        Service with at least 30 days&rsquo; notice. After an account closes you have 30 days to export its records; after that we delete them as
        described in the Privacy Policy.
      </p>

      <h2>11. Disclaimer</h2>
      <p>
        The Service is provided &ldquo;as is&rdquo; and &ldquo;as available.&rdquo; To the extent the law allows, we disclaim all warranties,
        express or implied, including merchantability, fitness for a particular purpose and non-infringement, and we do not promise that the
        Service will be uninterrupted or error-free.
      </p>

      <h2>12. Limits on liability</h2>
      <p>
        To the extent the law allows, we are not liable for indirect, incidental, special, consequential or punitive damages, or for lost profits,
        revenue or data. Our total liability for any claim about the Service is limited to the greater of the fees you paid us in the 12 months
        before the claim or $100.
      </p>

      <h2>13. Responsibility for your use</h2>
      <p>
        You agree to cover our reasonable costs, including legal fees, from claims by others arising from your work, your records or your
        breaking these terms — including disputes between customers and contractors.
      </p>

      <h2>14. Governing law</h2>
      <p>
        These terms are governed by the laws of the State of {state}, without regard to conflict-of-law rules. Any dispute will be heard in the
        state or federal courts in {county}, {state}, and you and we agree to those courts. Before filing a claim, each side agrees to try to
        resolve it informally for 30 days by contacting the other.
      </p>

      <h2>15. Changes and other terms</h2>
      <p>
        We may update these terms; we will post the new version with a new effective date and tell account administrators about important
        changes at least 30 days before they apply. Continuing to use the Service after that means you accept them. If part of these terms
        cannot be enforced, the rest still applies. Not enforcing a term is not a waiver of it. You may not transfer these terms without our
        consent; we may transfer them with our business.
      </p>

      <h2>16. Contact</h2>
      <p><a href={`mailto:${email}`}>{email}</a></p>
    </LegalPage>
  );
}
