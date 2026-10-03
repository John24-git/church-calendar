-- تحديث 1: صفحة الإدارة + استثناءات خميس الشماسية.
-- شغّله مرة واحدة في Supabase: SQL Editor ← New query ← Run.

-- 1) قايمة الأنشطة (رحلة، كورس…) بقت في قاعدة البيانات
create table if not exists public.activities (
  name text primary key,
  sort int not null default 0
);
insert into public.activities (name, sort) values
  ('رحلة',1),('كورس',2),('خلوة',3),('معسكر',4),('مؤتمر',5),('حفلة',6),
  ('مسرح',7),('يوم روحي',8),('يوم رياضي',9),('كرنفال',10),('قافلة',11)
on conflict (name) do nothing;

-- 2) أيام الخميس اللي اجتماع الشماسية الأسبوعي بيتنازل عنها (مؤتمرات، خلوات…)
create table if not exists public.weekly_exceptions (
  id        uuid primary key default gen_random_uuid(),
  from_date date not null,
  to_date   date not null,
  reason    text not null default '',
  check (to_date >= from_date)
);

alter table public.activities        enable row level security;
alter table public.weekly_exceptions enable row level security;

-- الكل يقرا. المشرف بس هو اللي يكتب.
grant select on public.activities, public.weekly_exceptions to anon, authenticated;
grant insert, update, delete on public.activities, public.weekly_exceptions, public.services to authenticated;

drop policy if exists activities_read on public.activities;
create policy activities_read on public.activities for select using (true);
drop policy if exists activities_write on public.activities;
create policy activities_write on public.activities for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists exceptions_read on public.weekly_exceptions;
create policy exceptions_read on public.weekly_exceptions for select using (true);
drop policy if exists exceptions_write on public.weekly_exceptions;
create policy exceptions_write on public.weekly_exceptions for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- الخدمات: المشرف يضيف ويعدّل ويحذف، ما عدا خدمة الشماسية (dia) لأن القواعد مربوطة بيها.
drop policy if exists services_insert on public.services;
create policy services_insert on public.services for insert to authenticated
  with check (public.is_admin());
drop policy if exists services_update on public.services;
create policy services_update on public.services for update to authenticated
  using (public.is_admin() and id <> 'dia') with check (public.is_admin() and id <> 'dia');
drop policy if exists services_delete on public.services;
create policy services_delete on public.services for delete to authenticated
  using (public.is_admin() and id <> 'dia');

-- 3) قواعد الحجز بعد الاستثناءات: يوم الخميس مش محجوز لو داخل في فترة استثناء
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

  if extract(isodow from p_date) = 4 and real_count = 0 and p_service <> 'dia'
     and not exists (select 1 from weekly_exceptions where p_date between from_date and to_date) then
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
