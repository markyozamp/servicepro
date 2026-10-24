-- Quotes (Base), and quote requests from customers.
-- A customer (store) asks one or more of its contractors to quote a job (a new unit, a remodel, a repair).
-- Contractors answer with an itemized quote on their own letterhead. The customer compares them side by side and
-- approves one with a tap: it becomes the job (a call to that contractor, with the quote total as the limit), and
-- the others are told they weren't chosen.
-- A Base contractor can also quote their own customers without being asked. A customer without a login gets an
-- email with a link to the quote and approves or declines it there (typing their name).

create table if not exists quote_requests (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(id) on delete cascade,
  site_id     uuid not null references sites(id) on delete cascade,
  title       text not null,
  details     text,
  due_on      date,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  closed_at   timestamptz
);
alter table quote_requests enable row level security;

create table if not exists quote_request_contractors (
  request_id    uuid not null references quote_requests(id) on delete cascade,
  contractor_id uuid not null references contractors(id) on delete cascade,
  invited_at    timestamptz not null default now(),
  passed_at     timestamptz,
  pass_note     text,
  primary key (request_id, contractor_id)
);
alter table quote_request_contractors enable row level security;

create table if not exists quotes (
  id              uuid primary key default gen_random_uuid(),
  contractor_id   uuid not null references contractors(id) on delete cascade,
  customer_id     uuid not null references customers(id) on delete cascade,
  site_id         uuid not null references sites(id) on delete cascade,
  request_id      uuid references quote_requests(id) on delete set null,
  number          text,
  title           text not null,
  notes           text,
  lines           jsonb not null default '[]',
  total           numeric(12,2) not null default 0,
  valid_until     date,
  status          text not null default 'draft' check (status in ('draft', 'sent', 'approved', 'declined', 'not_chosen', 'withdrawn')),
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  sent_at         timestamptz,
  decided_at      timestamptz,
  decided_by      uuid,
  decided_name    text,
  decided_via     text,
  decline_note    text,
  work_order_id   uuid
);
create index if not exists quotes_contractor on quotes (contractor_id, status);
create index if not exists quotes_customer on quotes (customer_id, status);
alter table quotes enable row level security;

create table if not exists quote_links (
  token      uuid primary key default gen_random_uuid(),
  quote_id   uuid not null references quotes(id) on delete cascade,
  created_at timestamptz not null default now(),
  viewed_at  timestamptz
);
alter table quote_links enable row level security;

alter table contractors add column if not exists next_quote_no int;

-- ============ The customer asks for quotes ============
create or replace function request_quotes(p_site uuid, p_title text, p_details text, p_contractors uuid[], p_due date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites; r quote_requests; c uuid; n int := 0;
begin
  select * into s from sites where id = p_site;
  if s.id is null or m.customer_id is distinct from s.customer_id or not profile_sees_site(m.id, s.id) then raise exception 'That location is not yours.'; end if;
  if not (m.can_open_calls or m.can_approve or m.is_org_admin) then raise exception 'You are not set up to ask for quotes.'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'Say what you want quoted.'; end if;
  if coalesce(array_length(p_contractors, 1), 0) = 0 then raise exception 'Pick at least one contractor.'; end if;
  insert into quote_requests (customer_id, site_id, title, details, due_on, created_by)
  values (s.customer_id, s.id, trim(p_title), nullif(trim(p_details), ''), p_due, m.id) returning * into r;
  foreach c in array p_contractors loop
    if exists (select 1 from customer_contractors where customer_id = s.customer_id and contractor_id = c and store_removed_at is null) then
      insert into quote_request_contractors (request_id, contractor_id) values (r.id, c) on conflict do nothing;
      perform _notify(p.id, null, 'new_call', format('%s asks you to quote: %s at %s%s.', (select name from customers where id = s.customer_id),
        r.title, s.name, coalesce(' (by ' || to_char(p_due, 'Mon DD') || ')', '')), 'qreq:' || r.id)
        from profiles p where p.contractor_id = c and p.active and (p.is_org_admin or p.can_dispatch or p.can_bill);
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception 'None of those contractors work for you.'; end if;
  return jsonb_build_object('id', r.id, 'asked', n);
end $$;

-- Contractor: can't quote this one
create or replace function pass_quote_request(p_request uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); r quote_requests;
begin
  select * into r from quote_requests where id = p_request;
  if r.id is null or m.contractor_id is null or not is_contractor_office(m.contractor_id)
     or not exists (select 1 from quote_request_contractors where request_id = r.id and contractor_id = m.contractor_id) then raise exception 'Not allowed.'; end if;
  update quote_request_contractors set passed_at = now(), pass_note = nullif(trim(p_note), '') where request_id = r.id and contractor_id = m.contractor_id;
  perform _notify(p.id, null, 'new_call', format('%s won''t be quoting "%s"%s.', (select name from contractors where id = m.contractor_id), r.title,
    coalesce(': ' || nullif(trim(p_note), ''), '')), 'qpass:' || r.id || ':' || m.contractor_id)
    from profiles p where p.id = r.created_by;
  return jsonb_build_object('ok', true);
end $$;

-- ============ The contractor writes a quote ============
create or replace function _quote_lines(p_lines jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(_bill_line(
           case when x->>'kind' in ('labor', 'part', 'task', 'equipment', 'other') then x->>'kind' else 'other' end,
           left(trim(x->>'description'), 300),
           greatest(0, coalesce(nullif(x->>'qty', '')::numeric, 0)),
           left(coalesce(x->>'unit', ''), 10),
           greatest(0, coalesce(nullif(x->>'rate', '')::numeric, 0)), false)), '[]')
  from jsonb_array_elements(coalesce(p_lines, '[]')) x where coalesce(trim(x->>'description'), '') <> ''
$$;

create or replace function save_quote(p_id uuid, p_site uuid, p_title text, p_lines jsonb, p_notes text default null,
  p_valid_until date default null, p_request uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites; q quotes; ln jsonb; tot numeric;
begin
  if m.contractor_id is null or not is_contractor_office(m.contractor_id) then raise exception 'Only your office can write quotes.'; end if;
  select * into s from sites where id = p_site;
  if s.id is null or not exists (select 1 from customer_contractors where customer_id = s.customer_id and contractor_id = m.contractor_id) then
    raise exception 'That isn''t one of your customers.';
  end if;
  if p_request is null and not _is_base(m.contractor_id) then raise exception 'Quoting your customers without being asked comes with Base.'; end if;
  if p_request is not null and not exists (select 1 from quote_request_contractors qc join quote_requests r on r.id = qc.request_id
       where qc.request_id = p_request and qc.contractor_id = m.contractor_id and r.closed_at is null) then
    raise exception 'That request is closed or wasn''t sent to you.';
  end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'Give the quote a title.'; end if;
  if jsonb_typeof(coalesce(p_lines, '[]')) <> 'array' or jsonb_array_length(coalesce(p_lines, '[]')) > 100 then raise exception 'Up to 100 lines.'; end if;
  ln := _quote_lines(p_lines);
  select coalesce(sum((x->>'amount')::numeric), 0) into tot from jsonb_array_elements(ln) x;
  if p_id is null then
    insert into quotes (contractor_id, customer_id, site_id, request_id, title, notes, lines, total, valid_until, created_by)
    values (m.contractor_id, s.customer_id, s.id, p_request, trim(p_title), nullif(trim(p_notes), ''), ln, tot,
            coalesce(p_valid_until, current_date + 30), m.id) returning * into q;
  else
    update quotes set site_id = s.id, customer_id = s.customer_id, title = trim(p_title), notes = nullif(trim(p_notes), ''), lines = ln, total = tot,
           valid_until = coalesce(p_valid_until, valid_until), updated_at = now()
     where id = p_id and contractor_id = m.contractor_id and status in ('draft', 'sent') returning * into q;
    if q.id is null then raise exception 'That quote can''t be changed any more.'; end if;
  end if;
  return to_jsonb(q);
end $$;

-- Send it (or send the changes again). Customers with logins see it in their portal; others get an email link.
create or replace function send_quote(p_id uuid, p_email text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); q quotes; c contractors; cu customers; t uuid; to_ text; site text; qn int;
begin
  select * into q from quotes where id = p_id for update;
  if q.id is null or m.contractor_id is distinct from q.contractor_id or not is_contractor_office(q.contractor_id) then raise exception 'Not allowed.'; end if;
  if q.status not in ('draft', 'sent') then raise exception 'This quote was already decided.'; end if;
  if jsonb_array_length(q.lines) = 0 or q.total <= 0 then raise exception 'Add the lines first.'; end if;
  select * into c from contractors where id = q.contractor_id;
  select * into cu from customers where id = q.customer_id;
  site := (select name from sites where id = q.site_id);
  if q.number is null then
    perform set_config('app.demo_guard_off', 'on', true);
    update contractors set next_quote_no = coalesce(next_quote_no, 101) + 1 where id = c.id returning next_quote_no - 1 into qn;
    perform set_config('app.demo_guard_off', 'off', true);
    q.number := 'Q-' || qn;
  end if;
  update quotes set status = 'sent', sent_at = now(), number = q.number, updated_at = now() where id = q.id;
  if _customer_has_logins(q.customer_id) then
    perform _notify(p.id, null, 'approval_request', format('%s sent quote %s: %s at %s, $%s. Open Quotes to compare and approve.',
      c.name, q.number, q.title, site, trim_scale(q.total)), 'quote:' || q.id || ':' || extract(epoch from now())::bigint)
      from profiles p where p.customer_id = q.customer_id and p.active and (p.can_approve or p.is_org_admin or p.can_open_calls)
        and profile_sees_site(p.id, q.site_id);
    return jsonb_build_object('ok', true, 'number', q.number, 'portal', true);
  end if;
  to_ := lower(coalesce(nullif(trim(p_email), ''), cu.email));
  if to_ is null then raise exception 'Add an email for this customer to send the quote.'; end if;
  if to_ !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email doesn''t look right.'; end if;
  select token into t from quote_links where quote_id = q.id order by created_at desc limit 1;
  if t is null then insert into quote_links (quote_id) values (q.id) returning token into t; end if;
  insert into email_queue (to_email, subject, lines, button, reply_to)
  values (to_, format('Quote %s from %s: %s ($%s)', q.number, c.name, q.title, trim_scale(q.total)),
    jsonb_build_array(format('Hello%s,', coalesce(' ' || cu.contact_name, '')),
      format('%s sent you quote %s for %s at %s: $%s%s.', c.name, q.number, q.title, site, trim_scale(q.total),
             coalesce(', good until ' || to_char(q.valid_until, 'Mon DD, YYYY'), '')),
      'Open it to see every line. You can approve it or say no right there, no account needed.',
      format('Questions? Call %s%s.', c.name, coalesce(' at ' || c.phone, ''))),
    jsonb_build_object('label', 'View the quote', 'path', '/q/' || t), c.email);
  return jsonb_build_object('ok', true, 'number', q.number, 'emailed_to', to_);
end $$;

create or replace function withdraw_quote(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); q quotes;
begin
  select * into q from quotes where id = p_id;
  if q.id is null or m.contractor_id is distinct from q.contractor_id or not is_contractor_office(q.contractor_id) then raise exception 'Not allowed.'; end if;
  if q.status not in ('draft', 'sent') then raise exception 'This quote was already decided.'; end if;
  update quotes set status = 'withdrawn', updated_at = now() where id = q.id;
  return jsonb_build_object('ok', true);
end $$;

-- ============ Deciding ============
-- Approving makes it the job: a call to that contractor, the quote total as the limit. Others on the same request
-- are told they weren't chosen.
create or replace function _quote_decided(p_quote uuid, p_approve boolean, p_name text, p_via text, p_by uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q quotes; w work_orders; site text; it uuid; c contractors;
begin
  select * into q from quotes where id = p_quote for update;
  if q.status <> 'sent' then raise exception 'This quote is no longer open.'; end if;
  if q.valid_until is not null and q.valid_until < current_date and p_approve then raise exception 'This quote expired on %. Ask for an updated one.', to_char(q.valid_until, 'Mon DD'); end if;
  if not p_approve and coalesce(length(trim(p_note)), 0) < 3 then raise exception 'Say why, so they can adjust it.'; end if;
  select * into c from contractors where id = q.contractor_id;
  site := (select name from sites where id = q.site_id);
  update quotes set status = case when p_approve then 'approved' else 'declined' end, decided_at = now(), decided_by = p_by,
         decided_name = nullif(trim(p_name), ''), decided_via = p_via, decline_note = case when not p_approve then trim(p_note) end, updated_at = now()
   where id = q.id;
  if p_approve then
    it := (select id from issue_types where code = 'other');
    w := _create_call(q.site_id, it, format('Quote %s: %s%s', q.number, q.title, coalesce(E'\n' || q.notes, '')), null, null, null, 'install',
                      q.contractor_id, null, null, coalesce(p_by, q.created_by), case when p_by is not null then 'store' else 'contractor' end, q.total, null);
    update quotes set work_order_id = w.id where id = q.id;
    if q.request_id is not null then
      update quotes set status = 'not_chosen', updated_at = now() where request_id = q.request_id and id <> q.id and status in ('draft', 'sent');
      update quote_requests set closed_at = now() where id = q.request_id;
      perform _notify(p.id, null, 'approval_declined', format('Quote for "%s" at %s: the customer chose another contractor. Thanks for quoting.', q.title, site))
        from quotes o join profiles p on p.contractor_id = o.contractor_id and p.active and (p.is_org_admin or p.can_dispatch or p.can_bill)
        where o.request_id = q.request_id and o.id <> q.id and o.status = 'not_chosen';
    end if;
  end if;
  perform _notify(p.id, w.id, case when p_approve then 'approval_granted'::notify_type else 'approval_declined' end,
    format('Quote %s (%s, $%s) was %s by %s%s.', q.number, q.title, trim_scale(q.total), case when p_approve then 'APPROVED' else 'declined' end,
           coalesce(nullif(trim(p_name), ''), 'the customer'), case when p_approve then format(': call #%s is open for it', w.number)
           else coalesce(': ' || trim(p_note), '') end))
    from profiles p where p.contractor_id = q.contractor_id and p.active and (p.is_org_admin or p.can_dispatch or p.can_bill);
  return jsonb_build_object('ok', true, 'approved', p_approve, 'work_order_id', w.id, 'call_number', w.number);
end $$;
revoke execute on function _quote_decided(uuid, boolean, text, text, uuid, text) from public, anon, authenticated;

-- Customer in the portal (approvers, or people who open calls)
create or replace function decide_quote(p_quote uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); q quotes;
begin
  select * into q from quotes where id = p_quote;
  if q.id is null or m.customer_id is distinct from q.customer_id or not profile_sees_site(m.id, q.site_id)
     or not (m.can_approve or m.is_org_admin) then raise exception 'You are not set up to approve quotes.'; end if;
  if p_approve and m.approval_limit is not null and q.total > m.approval_limit then
    raise exception 'This quote ($%) is above your $% approval limit. Ask someone who can approve it.', trim_scale(q.total), trim_scale(m.approval_limit);
  end if;
  return _quote_decided(p_quote, p_approve, m.full_name, 'portal', m.id, p_note);
end $$;

-- Customer from the emailed link
create or replace function quote_public(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l quote_links; q quotes; c contractors;
begin
  select * into l from quote_links where token = p_token;
  if l.token is null then return null; end if;
  select * into q from quotes where id = l.quote_id;
  if q.status = 'draft' then return null; end if;
  update quote_links set viewed_at = coalesce(viewed_at, now()) where token = p_token;
  select * into c from contractors where id = q.contractor_id;
  return jsonb_build_object('number', q.number, 'title', q.title, 'notes', q.notes, 'lines', q.lines, 'total', q.total,
    'valid_until', q.valid_until, 'status', q.status, 'sent_at', q.sent_at, 'decided_at', q.decided_at, 'decided_name', q.decided_name,
    'contractor', jsonb_build_object('name', c.name, 'phone', c.phone, 'email', c.email, 'logo', c.logo_data),
    'customer', (select name from customers where id = q.customer_id),
    'site', (select jsonb_build_object('name', s.name, 'address', s.address) from sites s where s.id = q.site_id),
    'expired', q.valid_until is not null and q.valid_until < current_date);
end $$;

create or replace function quote_link_decide(p_token uuid, p_approve boolean, p_name text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l quote_links;
begin
  select * into l from quote_links where token = p_token;
  if l.token is null then raise exception 'This link is not valid.'; end if;
  if coalesce(length(trim(p_name)), 0) < 2 then raise exception 'Type your name to sign.'; end if;
  return _quote_decided(l.quote_id, p_approve, trim(p_name) || ' (by link)', 'link', null, p_note);
end $$;

-- ============ Lists ============
-- Contractor: requests waiting for a quote, and every quote
create or replace function my_quotes() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not is_contractor_office(m.contractor_id) then raise exception 'Not allowed.'; end if;
  return jsonb_build_object(
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'title', r.title, 'details', r.details, 'due_on', r.due_on,
        'created_at', r.created_at, 'customer', cu.name, 'site', s.name, 'site_id', s.id, 'passed', qc.passed_at is not null,
        'quote_id', (select id from quotes where request_id = r.id and contractor_id = m.contractor_id order by created_at desc limit 1)) order by r.created_at desc), '[]')
      from quote_request_contractors qc join quote_requests r on r.id = qc.request_id join customers cu on cu.id = r.customer_id join sites s on s.id = r.site_id
      where qc.contractor_id = m.contractor_id and r.closed_at is null),
    'quotes', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'number', q.number, 'title', q.title, 'total', q.total, 'status', q.status,
        'customer', cu.name, 'site', s.name, 'site_id', q.site_id, 'notes', q.notes, 'lines', q.lines, 'valid_until', q.valid_until,
        'request_id', q.request_id, 'sent_at', q.sent_at, 'decided_at', q.decided_at, 'decided_name', q.decided_name, 'decline_note', q.decline_note,
        'work_order_id', q.work_order_id, 'call_number', (select number from work_orders where id = q.work_order_id), 'updated_at', q.updated_at)
        order by q.updated_at desc), '[]')
      from quotes q join customers cu on cu.id = q.customer_id join sites s on s.id = q.site_id
      where q.contractor_id = m.contractor_id));
end $$;

-- Customer: their requests with the quotes received, and quotes sent without a request
create or replace function store_quotes() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null then raise exception 'Not allowed.'; end if;
  return jsonb_build_object(
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'title', r.title, 'details', r.details, 'due_on', r.due_on,
        'created_at', r.created_at, 'closed_at', r.closed_at, 'site', s.name, 'site_id', s.id,
        'asked', (select coalesce(jsonb_agg(jsonb_build_object('contractor', c.name, 'passed', qc.passed_at is not null, 'pass_note', qc.pass_note)), '[]')
                  from quote_request_contractors qc join contractors c on c.id = qc.contractor_id where qc.request_id = r.id)) order by r.created_at desc), '[]')
      from quote_requests r join sites s on s.id = r.site_id
      where r.customer_id = m.customer_id and profile_sees_site(m.id, r.site_id) and (r.closed_at is null or r.closed_at > now() - interval '60 days')),
    'quotes', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'number', q.number, 'title', q.title, 'total', q.total, 'status', q.status,
        'contractor', c.name, 'site', s.name, 'site_id', q.site_id, 'notes', q.notes, 'lines', q.lines, 'valid_until', q.valid_until,
        'request_id', q.request_id, 'sent_at', q.sent_at, 'decided_at', q.decided_at, 'decided_name', q.decided_name,
        'call_number', (select number from work_orders where id = q.work_order_id), 'work_order_id', q.work_order_id) order by q.sent_at desc), '[]')
      from quotes q join contractors c on c.id = q.contractor_id join sites s on s.id = q.site_id
      where q.customer_id = m.customer_id and q.status <> 'draft' and profile_sees_site(m.id, q.site_id)
        and (q.status = 'sent' or q.decided_at > now() - interval '60 days' or q.updated_at > now() - interval '60 days')));
end $$;

grant execute on function request_quotes(uuid, text, text, uuid[], date), pass_quote_request(uuid, text),
  save_quote(uuid, uuid, text, jsonb, text, date, uuid), send_quote(uuid, text), withdraw_quote(uuid), decide_quote(uuid, boolean, text),
  my_quotes(), store_quotes() to authenticated;
grant execute on function quote_public(uuid), quote_link_decide(uuid, boolean, text, text) to anon, authenticated;
