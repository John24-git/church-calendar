-- تحديث 3: موافقة أمين الشمامسة على حجوزات الخميس + أرقام إنجليزي.
-- شغّله مرة واحدة في Supabase: SQL Editor ← New query ← Run.

-- 1) حالة الحجز: confirmed (مؤكد) / pending (بانتظار الموافقة) / rejected (مرفوض)
alter table public.bookings add column if not exists status text not null default 'confirmed';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'bookings_status_chk') then
    alter table public.bookings add constraint bookings_status_chk check (status in ('confirmed','pending','rejected'));
  end if;
end $$;
alter table public.bookings add column if not exists decision_note text not null default '';
alter table public.bookings add column if not exists decided_at timestamptz;

-- 2) أمناء الشمامسة: صلاحيتهم الموافقة على طلبات الخميس بس
create table if not exists public.approvers (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.approvers enable row level security;
revoke all on public.approvers from anon, authenticated;

create or replace function public.is_approver() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.approvers where user_id = auth.uid())
      or exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.admins where user_id = auth.uid()) then 'admin'
    when exists (select 1 from public.approvers where user_id = auth.uid()) then 'approver'
    else 'none' end;
$$;

-- 3) الحجز يحتاج موافقة لو: يوم خميس، مش للشماسية، مفيش حجز مؤكد في اليوم، ومش في فترة استثناء
create or replace function public.needs_approval(p_date date, p_service text, p_exclude uuid)
returns boolean language sql stable set search_path = public as $$
  select extract(isodow from p_date) = 4 and p_service <> 'dia'
    and not exists (select 1 from bookings where book_date = p_date and status = 'confirmed' and id is distinct from p_exclude)
    and not exists (select 1 from weekly_exceptions where p_date between from_date and to_date);
$$;
revoke execute on function public.needs_approval(date, text, uuid) from public, anon, authenticated;

-- 4) قواعد الحجز (الخميس بقى بموافقة، مش ممنوع)
create or replace function public.check_rules(p_date date, p_service text, p_exclude uuid)
returns text language plpgsql stable set search_path = public as $$
declare
  dia_name text; real_count int; dup_name text; lst text;
begin
  select name into dia_name from bookings
    where book_date = p_date and service_id = 'dia' and status = 'confirmed' and id is distinct from p_exclude limit 1;
  if dia_name is not null then
    return 'اليوم ده محجوز لخدمة الشماسية (' || dia_name || ') ومينفعش أي خدمة تانية تحجز فيه.';
  end if;

  select count(*) into real_count from bookings
    where book_date = p_date and status = 'confirmed' and id is distinct from p_exclude;

  if p_service = 'dia' and real_count > 0 then
    select string_agg(s.name || ' (' || b.name || ')', '، ') into lst
      from bookings b join services s on s.id = b.service_id
      where b.book_date = p_date and b.status = 'confirmed' and b.id is distinct from p_exclude;
    return 'الشماسية محتاجة يوم فاضي بالكامل، واليوم ده فيه حجوزات: ' || lst || '.';
  end if;

  select name into dup_name from bookings
    where book_date = p_date and service_id = p_service and status in ('confirmed','pending')
      and id is distinct from p_exclude limit 1;
  if dup_name is not null then
    return (select name from services where id = p_service) || ' حاجزة اليوم ده بالفعل. الحاجز: ' || dup_name || '.';
  end if;
  return null;
end $$;

create or replace function public.get_bookings() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
    'id', id, 'date', book_date, 'service', service_id, 'name', name,
    'activity', activity, 'place', place, 'note', note, 'notifyDate', notify_date, 'status', status
  ) order by book_date, created_at), '[]'::json) from bookings where status <> 'rejected';
$$;

create or replace function public.add_booking(
  p_date date, p_service text, p_name text, p_activity text, p_place text, p_note text
) returns json language plpgsql security definer set search_path = public as $$
declare
  err text; v_name text := left(btrim(coalesce(p_name, '')), 60);
  new_id uuid; new_code text; st text;
  today date := (now() at time zone 'Africa/Cairo')::date;
begin
  if p_date is null or v_name = '' or not exists (select 1 from services where id = p_service) then
    return json_build_object('ok', false, 'error', 'كمّل التاريخ والخدمة والاسم.');
  end if;
  if p_date < today then
    return json_build_object('ok', false, 'error', 'التاريخ ده عدى. اختار النهارده أو يوم جاي.');
  end if;
  perform pg_advisory_xact_lock(7001);
  err := check_rules(p_date, p_service, null);
  if err is not null then return json_build_object('ok', false, 'error', err); end if;
  st := case when needs_approval(p_date, p_service, null) and not is_approver() then 'pending' else 'confirmed' end;
  insert into bookings (book_date, service_id, name, activity, place, note, status)
    values (p_date, p_service, v_name, left(btrim(coalesce(p_activity, '')), 40),
            left(btrim(coalesce(p_place, '')), 80), left(btrim(coalesce(p_note, '')), 200), st)
    returning id, edit_code into new_id, new_code;
  if st = 'confirmed' and p_service = 'dia' then
    update bookings set status = 'rejected', decision_note = 'الشماسية حجزت اليوم ده', decided_at = now()
      where book_date = p_date and status = 'pending' and id <> new_id;
  end if;
  return json_build_object('ok', true, 'id', new_id, 'code', new_code, 'status', st);
end $$;

create or replace function public.update_booking(
  p_id uuid, p_code text, p_date date, p_service text, p_name text, p_activity text, p_place text, p_note text
) returns json language plpgsql security definer set search_path = public as $$
declare
  err text; v_name text := left(btrim(coalesce(p_name, '')), 60);
  today date := (now() at time zone 'Africa/Cairo')::date;
  code_ok boolean; old_rec public.bookings%rowtype; st text;
begin
  if p_date is null or v_name = '' or not exists (select 1 from services where id = p_service) then
    return json_build_object('ok', false, 'error', 'كمّل التاريخ والخدمة والاسم.');
  end if;
  if p_date < today then
    return json_build_object('ok', false, 'error', 'التاريخ ده عدى. اختار النهارده أو يوم جاي.');
  end if;
  perform pg_advisory_xact_lock(7001);
  select * into old_rec from bookings where id = p_id;
  if not found then
    return json_build_object('ok', false, 'error', 'الحجز ده مش موجود. حدّث الصفحة.');
  end if;
  code_ok := btrim(coalesce(p_code, '')) <> '' and upper(old_rec.edit_code) = upper(btrim(p_code));
  if not code_ok and not is_admin() then
    return json_build_object('ok', false, 'error', 'كود التعديل غلط.');
  end if;
  err := check_rules(p_date, p_service, p_id);
  if err is not null then return json_build_object('ok', false, 'error', err); end if;
  st := case
    when old_rec.status <> 'rejected' and old_rec.book_date = p_date and old_rec.service_id = p_service then old_rec.status
    when needs_approval(p_date, p_service, p_id) and not is_approver() then 'pending'
    else 'confirmed' end;
  update bookings set book_date = p_date, service_id = p_service, name = v_name,
    activity = left(btrim(coalesce(p_activity, '')), 40), place = left(btrim(coalesce(p_place, '')), 80),
    note = left(btrim(coalesce(p_note, '')), 200), notify_date = today, status = st
    where id = p_id;
  if st = 'confirmed' and p_service = 'dia' then
    update bookings set status = 'rejected', decision_note = 'الشماسية حجزت اليوم ده', decided_at = now()
      where book_date = p_date and status = 'pending' and id <> p_id;
  end if;
  return json_build_object('ok', true, 'status', st);
end $$;

-- 5) طلبات الخميس اللي مستنية موافقة (لأمين الشمامسة والمشرف بس)
create or replace function public.pending_requests() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_approver() then return '[]'::json; end if;
  return coalesce((
    select json_agg(json_build_object(
      'id', id, 'date', book_date, 'service', service_id, 'name', name,
      'activity', activity, 'place', place, 'note', note, 'created', created_at
    ) order by book_date, created_at) from bookings where status = 'pending'
  ), '[]'::json);
end $$;

create or replace function public.decide_booking(p_id uuid, p_approve boolean, p_note text) returns json
language plpgsql security definer set search_path = public as $$
declare b public.bookings%rowtype; err text;
begin
  if not is_approver() then
    return json_build_object('ok', false, 'error', 'للمشرف أو أمين الشمامسة بس.');
  end if;
  perform pg_advisory_xact_lock(7001);
  select * into b from bookings where id = p_id and status = 'pending';
  if not found then
    return json_build_object('ok', false, 'error', 'الطلب ده اتعالج بالفعل.');
  end if;
  if p_approve then
    err := check_rules(b.book_date, b.service_id, b.id);
    if err is not null then return json_build_object('ok', false, 'error', err); end if;
    update bookings set status = 'confirmed', decided_at = now(),
      decision_note = left(btrim(coalesce(p_note, '')), 200) where id = b.id;
  else
    update bookings set status = 'rejected', decided_at = now(),
      decision_note = left(btrim(coalesce(p_note, '')), 200) where id = b.id;
  end if;
  return json_build_object('ok', true);
end $$;

-- صاحب الطلب يشوف حالة طلباته (بالمعرّفات اللي متخزنة على جهازه)
create or replace function public.my_requests(p_ids uuid[]) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
    'id', id, 'status', status, 'note', decision_note, 'date', book_date, 'service', service_id
  )), '[]'::json) from bookings where id = any (p_ids[1:50]);
$$;

-- 6) إدارة المستخدمين: مشرف / أمين الشمامسة
create or replace function public.list_users() returns json
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not is_admin() then return '[]'::json; end if;
  return coalesce((
    select json_agg(json_build_object(
      'id', u.id, 'email', u.email, 'created', u.created_at,
      'is_admin', exists (select 1 from public.admins a where a.user_id = u.id),
      'is_approver', exists (select 1 from public.approvers p where p.user_id = u.id)
    ) order by u.created_at desc) from auth.users u
  ), '[]'::json);
end $$;

create or replace function public.set_approver(p_user uuid, p_make boolean) returns json
language plpgsql security definer set search_path = public, auth as $$
begin
  if not is_admin() then return json_build_object('ok', false, 'error', 'للمشرف بس.'); end if;
  if p_make then
    insert into public.approvers (user_id) values (p_user) on conflict do nothing;
  else
    delete from public.approvers where user_id = p_user;
  end if;
  return json_build_object('ok', true);
end $$;

revoke execute on function public.is_approver(), public.my_role(), public.pending_requests(),
  public.decide_booking(uuid, boolean, text), public.my_requests(uuid[]), public.set_approver(uuid, boolean)
  from public, anon;
grant execute on function public.my_role(), public.my_requests(uuid[]) to anon, authenticated;
grant execute on function public.is_approver(), public.pending_requests(),
  public.decide_booking(uuid, boolean, text), public.set_approver(uuid, boolean) to authenticated;

-- 7) أرقام إنجليزي في البيانات الموجودة
update public.services set name = translate(name, '٠١٢٣٤٥٦٧٨٩', '0123456789');
update public.activities set name = translate(name, '٠١٢٣٤٥٦٧٨٩', '0123456789');
update public.bookings set
  name = translate(name, '٠١٢٣٤٥٦٧٨٩', '0123456789'),
  activity = translate(activity, '٠١٢٣٤٥٦٧٨٩', '0123456789'),
  place = translate(place, '٠١٢٣٤٥٦٧٨٩', '0123456789'),
  note = translate(note, '٠١٢٣٤٥٦٧٨٩', '0123456789');
update public.weekly_exceptions set reason = translate(reason, '٠١٢٣٤٥٦٧٨٩', '0123456789');
