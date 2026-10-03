-- كاليندر كنيسة السيدة العذراء والقديس أثناسيوس الرسولي - دار السلام
-- شغّل الملف ده كله مرة واحدة في Supabase: SQL Editor ← New query ← Run.

create extension if not exists pgcrypto;

create table if not exists public.services (
  id        text primary key,
  name      text not null,
  hue       int  not null,
  exclusive boolean not null default false,
  sort      int  not null default 0
);

create table if not exists public.bookings (
  id          uuid primary key default gen_random_uuid(),
  book_date   date not null,
  service_id  text not null references public.services(id),
  name        text not null,
  activity    text not null default '',
  place       text not null default '',
  note        text not null default '',
  notify_date date not null default ((now() at time zone 'Africa/Cairo')::date),
  created_at  timestamptz not null default now(),
  edit_code   text not null default upper(substr(md5(gen_random_uuid()::text), 1, 8))
);
create index if not exists bookings_date_idx on public.bookings (book_date);

-- المشرفين: كل واحد ليه حساب في Authentication، ونضيفه هنا.
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- الجداول مقفولة على الزوار. كل التعامل بيتم عن طريق الدوال تحت، وكود التعديل عمره ما بيطلع للمتصفح.
alter table public.bookings enable row level security;
alter table public.admins   enable row level security;
alter table public.services enable row level security;
revoke all on public.bookings, public.admins from anon, authenticated;
revoke all on public.services from anon, authenticated;
grant select on public.services to anon, authenticated;
drop policy if exists services_read on public.services;
create policy services_read on public.services for select using (true);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- قواعد الحجز. بترجّع رسالة خطأ أو null لو الحجز مسموح.
-- كل خميس محجوز لاجتماع الشماسية الأسبوعي (٦ لـ٩)، إلا لو اليوم فيه حجز فعلي بالفعل.
create or replace function public.check_rules(p_date date, p_service text, p_exclude uuid)
returns text language plpgsql stable set search_path = public as $$
declare
  dia_name text; real_count int; dup_name text; lst text;
begin
  select name into dia_name from bookings
    where book_date = p_date and service_id = 'dia' and id is distinct from p_exclude limit 1;
  if dia_name is not null then
    return 'اليوم ده محجوز لخدمة الشماسية (' || dia_name || ') ومينفعش أي خدمة تانية تحجز فيه.';
  end if;

  select count(*) into real_count from bookings
    where book_date = p_date and id is distinct from p_exclude;

  if extract(isodow from p_date) = 4 and real_count = 0 and p_service <> 'dia' then
    return 'يوم الخميس محجوز لاجتماع الشماسية الأسبوعي من ٦ لـ٩.';
  end if;

  if p_service = 'dia' and real_count > 0 then
    select string_agg(s.name || ' (' || b.name || ')', '، ') into lst
      from bookings b join services s on s.id = b.service_id
      where b.book_date = p_date and b.id is distinct from p_exclude;
    return 'الشماسية محتاجة يوم فاضي بالكامل، واليوم ده فيه حجوزات: ' || lst || '.';
  end if;

  select name into dup_name from bookings
    where book_date = p_date and service_id = p_service and id is distinct from p_exclude limit 1;
  if dup_name is not null then
    return (select name from services where id = p_service) || ' حاجزة اليوم ده بالفعل. الحاجز: ' || dup_name || '.';
  end if;
  return null;
end $$;
revoke execute on function public.check_rules(date, text, uuid) from public, anon, authenticated;

-- قراءة الحجوزات (من غير كود التعديل).
create or replace function public.get_bookings() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
    'id', id, 'date', book_date, 'service', service_id, 'name', name,
    'activity', activity, 'place', place, 'note', note, 'notifyDate', notify_date
  ) order by book_date, created_at), '[]'::json) from bookings;
$$;

create or replace function public.add_booking(
  p_date date, p_service text, p_name text, p_activity text, p_place text, p_note text
) returns json language plpgsql security definer set search_path = public as $$
declare
  err text; v_name text := left(btrim(coalesce(p_name, '')), 60);
  new_id uuid; new_code text; today date := (now() at time zone 'Africa/Cairo')::date;
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
  insert into bookings (book_date, service_id, name, activity, place, note)
    values (p_date, p_service, v_name, left(btrim(coalesce(p_activity, '')), 40),
            left(btrim(coalesce(p_place, '')), 80), left(btrim(coalesce(p_note, '')), 200))
    returning id, edit_code into new_id, new_code;
  return json_build_object('ok', true, 'id', new_id, 'code', new_code);
end $$;

-- تعديل حجز: بكود التعديل بتاع الحجز، أو لو المستخدم مشرف.
create or replace function public.update_booking(
  p_id uuid, p_code text, p_date date, p_service text, p_name text, p_activity text, p_place text, p_note text
) returns json language plpgsql security definer set search_path = public as $$
declare
  err text; v_name text := left(btrim(coalesce(p_name, '')), 60);
  today date := (now() at time zone 'Africa/Cairo')::date; code_ok boolean;
begin
  if p_date is null or v_name = '' or not exists (select 1 from services where id = p_service) then
    return json_build_object('ok', false, 'error', 'كمّل التاريخ والخدمة والاسم.');
  end if;
  if p_date < today then
    return json_build_object('ok', false, 'error', 'التاريخ ده عدى. اختار النهارده أو يوم جاي.');
  end if;
  perform pg_advisory_xact_lock(7001);
  select exists (select 1 from bookings where id = p_id and btrim(coalesce(p_code, '')) <> ''
                 and upper(edit_code) = upper(btrim(p_code))) into code_ok;
  if not exists (select 1 from bookings where id = p_id) then
    return json_build_object('ok', false, 'error', 'الحجز ده مش موجود. حدّث الصفحة.');
  end if;
  if not code_ok and not is_admin() then
    return json_build_object('ok', false, 'error', 'كود التعديل غلط.');
  end if;
  err := check_rules(p_date, p_service, p_id);
  if err is not null then return json_build_object('ok', false, 'error', err); end if;
  update bookings set book_date = p_date, service_id = p_service, name = v_name,
    activity = left(btrim(coalesce(p_activity, '')), 40), place = left(btrim(coalesce(p_place, '')), 80),
    note = left(btrim(coalesce(p_note, '')), 200), notify_date = today
    where id = p_id;
  return json_build_object('ok', true);
end $$;

-- إلغاء حجز: للمشرف بس.
create or replace function public.cancel_booking(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then
    return json_build_object('ok', false, 'error', 'الإلغاء للمشرف بس. سجّل دخول كمشرف.');
  end if;
  delete from bookings where id = p_id;
  return json_build_object('ok', true);
end $$;

revoke execute on function public.is_admin(), public.get_bookings(),
  public.add_booking(date, text, text, text, text, text),
  public.update_booking(uuid, text, date, text, text, text, text, text),
  public.cancel_booking(uuid) from public;
grant execute on function public.is_admin(), public.get_bookings(),
  public.add_booking(date, text, text, text, text, text),
  public.update_booking(uuid, text, date, text, text, text, text, text),
  public.cancel_booking(uuid) to anon, authenticated;
