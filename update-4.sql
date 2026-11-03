-- أوقات داخل اليوم + حجز لمدى أيام (مؤتمر/رحلة) + اجتماع الشماسية الأسبوعي بيفضل ثابت.
-- start_time/end_time فاضيين = اليوم كله. group_id/range_end بيربطوا أيام الحجز الواحد.

alter table public.bookings
  add column if not exists start_time time,
  add column if not exists end_time   time,
  add column if not exists group_id   uuid,
  add column if not exists range_end  date;
create index if not exists bookings_group_idx on public.bookings (group_id);

-- هل فترتين زمنيتين بيتقاطعوا؟ (فاضي = اليوم كله)
create or replace function public.t_overlap(a_s time, a_e time, b_s time, b_e time) returns boolean
language sql immutable as $$
  select coalesce(a_s, time '00:00') < coalesce(b_e, time '23:59:59.999999')
     and coalesce(b_s, time '00:00') < coalesce(a_e, time '23:59:59.999999');
$$;

drop function if exists public.check_rules(date, text, uuid);
create or replace function public.check_rules(p_date date, p_service text, p_exclude uuid, p_start time default null, p_end time default null)
returns text language plpgsql stable set search_path to 'public' as $$
declare dia_name text; real_count int; dup_name text; lst text; w text := case when p_start is null then 'اليوم ده' else 'الوقت ده' end;
begin
  select name into dia_name from bookings
    where book_date = p_date and service_id = 'dia' and status = 'confirmed' and id is distinct from p_exclude
      and public.t_overlap(start_time, end_time, p_start, p_end) limit 1;
  if dia_name is not null then
    return w || ' محجوز لخدمة الشماسية (' || dia_name || ') ومينفعش أي خدمة تانية تحجز فيه.';
  end if;
  select count(*) into real_count from bookings
    where book_date = p_date and status = 'confirmed' and id is distinct from p_exclude
      and public.t_overlap(start_time, end_time, p_start, p_end);
  if p_service = 'dia' and real_count > 0 then
    select string_agg(s.name || ' (' || b.name || ')', '، ') into lst
      from bookings b join services s on s.id = b.service_id
      where b.book_date = p_date and b.status = 'confirmed' and b.id is distinct from p_exclude
        and public.t_overlap(b.start_time, b.end_time, p_start, p_end);
    return 'الشماسية محتاجة ' || w || ' فاضي بالكامل، وفيه حجوزات: ' || lst || '.';
  end if;
  select name into dup_name from bookings
    where book_date = p_date and service_id = p_service and status in ('confirmed','pending') and id is distinct from p_exclude
      and public.t_overlap(start_time, end_time, p_start, p_end) limit 1;
  if dup_name is not null then
    return (select name from services where id = p_service) || ' حاجزة ' || w || ' بالفعل. الحاجز: ' || dup_name || '.';
  end if;
  return null;
end $$;

-- الخميس (في موسم الشماسية ومن غير استثناء) بيحتاج موافقة الشماسية لو الحجز بيتقاطع مع 6 لـ 9 مساءً.
drop function if exists public.needs_approval(date, text, uuid);
create or replace function public.needs_approval(p_date date, p_service text, p_exclude uuid, p_start time default null, p_end time default null)
returns boolean language sql stable set search_path to 'public' as $$
  select extract(isodow from p_date) = 4 and p_service <> 'dia'
    and (not exists (select 1 from diaconate_seasons)
         or exists (select 1 from diaconate_seasons where p_date between from_date and to_date))
    and not exists (select 1 from weekly_exceptions where p_date between from_date and to_date)
    and public.t_overlap(p_start, p_end, time '18:00', time '21:00');
$$;
revoke execute on function public.check_rules(date, text, uuid, time, time), public.needs_approval(date, text, uuid, time, time), public.t_overlap(time, time, time, time) from public, anon, authenticated;

-- حجز جديد (يوم واحد أو مدى أيام، وبوقت أو من غير)
drop function if exists public.add_booking(date, text, text, text, text);
create or replace function public.add_booking(p_date date, p_service text, p_activity text, p_place text, p_note text,
                                              p_start time default null, p_end time default null, p_end_date date default null)
returns json language plpgsql security definer set search_path to 'public', 'auth' as $$
declare
  r text := public.cur_role(); err text; st text; nd text := null; new_id uuid; gid uuid := null; d date;
  last_d date := coalesce(p_end_date, p_date); n int := 0; pend int := 0;
  today date := (now() at time zone 'Africa/Cairo')::date;
  need_general boolean := coalesce((select (value #>> '{}')::boolean from settings where key = 'require_general_approval'), false);
begin
  if r = 'none' then return json_build_object('ok', false, 'error', 'سجّل دخول بحساب أمين خدمة عشان تحجز.'); end if;
  if p_date is null or not exists (select 1 from services where id = p_service) then
    return json_build_object('ok', false, 'error', 'كمّل التاريخ والخدمة.');
  end if;
  if not public.can_book_service(p_service) then
    return json_build_object('ok', false, 'error',
      case when p_service = 'dia' then 'حجوزات الشماسية بتطلع من أمين خدمة الشماسية بس.' else 'تقدر تحجز لخدمتك بس.' end);
  end if;
  if p_date < today then return json_build_object('ok', false, 'error', 'التاريخ ده عدى. اختار النهارده أو يوم جاي.'); end if;
  if last_d < p_date then return json_build_object('ok', false, 'error', 'تاريخ النهاية لازم يكون بعد تاريخ البداية.'); end if;
  if last_d - p_date > 13 then return json_build_object('ok', false, 'error', 'أقصى مدة للحجز 14 يوم.'); end if;
  if (p_start is null) <> (p_end is null) then
    return json_build_object('ok', false, 'error', 'اكتب ساعة البداية والنهاية مع بعض، أو سيبهم فاضيين لو اليوم كله.');
  end if;
  if p_start is not null and p_end <= p_start then
    return json_build_object('ok', false, 'error', 'ساعة النهاية لازم تكون بعد ساعة البداية.');
  end if;
  perform pg_advisory_xact_lock(7001);
  for d in select generate_series(p_date, last_d, interval '1 day')::date loop
    err := public.check_rules(d, p_service, null, p_start, p_end);
    if err is not null then
      return json_build_object('ok', false, 'error', case when last_d > p_date then to_char(d, 'DD/MM') || ': ' || err else err end);
    end if;
  end loop;
  if last_d > p_date then gid := gen_random_uuid(); end if;
  for d in select generate_series(p_date, last_d, interval '1 day')::date loop
    st := 'confirmed'; nd := null;
    if public.needs_approval(d, p_service, null, p_start, p_end) and r not in ('diaconate','super') then
      st := 'pending'; nd := 'diaconate';
    elsif need_general and r = 'service' then
      st := 'pending'; nd := 'general';
    end if;
    insert into bookings (book_date, service_id, name, activity, place, note, status, needs, created_by,
                          start_time, end_time, group_id, range_end)
      values (d, p_service, public.cur_name(), left(btrim(coalesce(p_activity, '')), 40),
              left(btrim(coalesce(p_place, '')), 80), left(btrim(coalesce(p_note, '')), 200), st, nd, auth.uid(),
              p_start, p_end, gid, case when gid is not null then last_d end)
      returning id into new_id;
    n := n + 1; if st = 'pending' then pend := pend + 1; end if;
    if st = 'confirmed' and p_service = 'dia' then
      update bookings set status = 'rejected', decision_note = 'الشماسية حجزت اليوم ده', decided_at = now()
        where book_date = d and status = 'pending' and id <> new_id
          and public.t_overlap(start_time, end_time, p_start, p_end);
    end if;
  end loop;
  return json_build_object('ok', true, 'id', new_id, 'days', n, 'pending', pend,
                           'status', case when pend > 0 then 'pending' else 'confirmed' end, 'needs', nd);
end $$;

-- تعديل حجز. p_all = طبّق الوقت/النشاط/المكان/الملاحظة على كل أيام الحجز (من غير ما تغيّر تواريخها)
drop function if exists public.update_booking(uuid, date, text, text, text, text);
create or replace function public.update_booking(p_id uuid, p_date date, p_service text, p_activity text, p_place text, p_note text,
                                                 p_start time default null, p_end time default null, p_all boolean default false)
returns json language plpgsql security definer set search_path to 'public', 'auth' as $$
declare
  r text := public.cur_role(); old public.bookings%rowtype; row_ public.bookings%rowtype; err text; st text; nd text;
  ids uuid[]; tid uuid; tdate date; tsvc text; any_pending boolean := false;
  today date := (now() at time zone 'Africa/Cairo')::date;
  need_general boolean := coalesce((select (value #>> '{}')::boolean from settings where key = 'require_general_approval'), false);
begin
  select * into old from bookings where id = p_id;
  if not found then return json_build_object('ok', false, 'error', 'الحجز ده مش موجود. حدّث الصفحة.'); end if;
  if not ((r = 'super') or (r = 'general' and old.service_id <> 'dia')
          or (r in ('service','diaconate') and auth.uid() is not null and old.created_by = auth.uid())) then
    return json_build_object('ok', false, 'error', 'مفيش صلاحية تعدّل الحجز ده.');
  end if;
  if p_date is null or not exists (select 1 from services where id = p_service) then
    return json_build_object('ok', false, 'error', 'كمّل التاريخ والخدمة.');
  end if;
  if not public.can_book_service(p_service) then
    return json_build_object('ok', false, 'error', 'تقدر تحجز لخدمتك بس.');
  end if;
  if (p_start is null) <> (p_end is null) then
    return json_build_object('ok', false, 'error', 'اكتب ساعة البداية والنهاية مع بعض، أو سيبهم فاضيين لو اليوم كله.');
  end if;
  if p_start is not null and p_end <= p_start then
    return json_build_object('ok', false, 'error', 'ساعة النهاية لازم تكون بعد ساعة البداية.');
  end if;
  if p_all and old.group_id is not null then
    select array_agg(id order by book_date) into ids from bookings where group_id = old.group_id and book_date >= today;
  else
    if p_date < today then return json_build_object('ok', false, 'error', 'التاريخ ده عدى. اختار النهارده أو يوم جاي.'); end if;
    ids := array[p_id];
  end if;
  perform pg_advisory_xact_lock(7001);
  for pass in 1..2 loop
    foreach tid in array ids loop
      select * into row_ from bookings where id = tid;
      if tid = p_id and not (p_all and old.group_id is not null) then tdate := p_date; tsvc := p_service;
      else tdate := row_.book_date; tsvc := row_.service_id; end if;
      if pass = 1 then
        err := public.check_rules(tdate, tsvc, tid, p_start, p_end);
        if err is not null then
          return json_build_object('ok', false, 'error', case when array_length(ids, 1) > 1 then to_char(tdate, 'DD/MM') || ': ' || err else err end);
        end if;
      else
        if row_.status <> 'rejected' and row_.book_date = tdate and row_.service_id = tsvc
           and row_.start_time is not distinct from p_start and row_.end_time is not distinct from p_end then
          st := row_.status; nd := row_.needs;
        elsif public.needs_approval(tdate, tsvc, tid, p_start, p_end) and r not in ('diaconate','super') then
          st := 'pending'; nd := 'diaconate';
        elsif need_general and r = 'service' then
          st := 'pending'; nd := 'general';
        else
          st := 'confirmed'; nd := null;
        end if;
        update bookings set book_date = tdate, service_id = tsvc,
          activity = left(btrim(coalesce(p_activity, '')), 40), place = left(btrim(coalesce(p_place, '')), 80),
          note = left(btrim(coalesce(p_note, '')), 200), start_time = p_start, end_time = p_end,
          notify_date = today, status = st, needs = nd,
          group_id = case when tid = p_id and not (p_all and old.group_id is not null) and tdate <> old.book_date then null else group_id end
          where id = tid;
        if st = 'pending' then any_pending := true; end if;
        if st = 'confirmed' and tsvc = 'dia' then
          update bookings set status = 'rejected', decision_note = 'الشماسية حجزت اليوم ده', decided_at = now()
            where book_date = tdate and status = 'pending' and id <> tid
              and public.t_overlap(start_time, end_time, p_start, p_end);
        end if;
      end if;
    end loop;
  end loop;
  return json_build_object('ok', true, 'status', case when any_pending then 'pending' else 'confirmed' end);
end $$;

-- إلغاء حجز. p_all = إلغاء كل الأيام الجاية في نفس الحجز (مؤتمر/رحلة)
drop function if exists public.cancel_booking(uuid);
create or replace function public.cancel_booking(p_id uuid, p_all boolean default false)
returns json language plpgsql security definer set search_path to 'public', 'auth' as $$
declare
  r text := public.cur_role(); old public.bookings%rowtype; many boolean;
  today date := (now() at time zone 'Africa/Cairo')::date;
  allow_cancel boolean := coalesce((select (value #>> '{}')::boolean from settings where key = 'allow_service_cancel'), true);
begin
  select * into old from bookings where id = p_id;
  if not found then return json_build_object('ok', false, 'error', 'الحجز ده مش موجود.'); end if;
  many := p_all and old.group_id is not null;
  if r = 'super' or (r = 'general' and old.service_id <> 'dia') then
    null;
  elsif r in ('service','diaconate') and auth.uid() is not null and old.created_by = auth.uid() then
    if not allow_cancel then
      return json_build_object('ok', false, 'error', 'الإلغاء بيتم عن طريق الأمين العام.');
    end if;
    insert into notifications (kind, message, actor_name, book_date, service_id)
      values ('cancelled',
              public.cur_name() || ' لغى حجز ' || (select name from services where id = old.service_id) || ' يوم ' || to_char(old.book_date, 'YYYY-MM-DD')
                || case when many then ' (وكل أيام الحجز)' else '' end,
              public.cur_name(), old.book_date, old.service_id);
  else
    return json_build_object('ok', false, 'error', 'مفيش صلاحية تلغي الحجز ده.');
  end if;
  if many then
    delete from bookings where group_id = old.group_id and book_date >= today;
  else
    delete from bookings where id = p_id;
  end if;
  return json_build_object('ok', true);
end $$;

-- الموافقة: بتراجع القواعد بنفس الوقت
create or replace function public.decide_booking(p_id uuid, p_approve boolean, p_note text)
returns json language plpgsql security definer set search_path to 'public' as $$
declare r text := public.cur_role(); b public.bookings%rowtype; err text;
begin
  if r not in ('super','diaconate','general') then
    return json_build_object('ok', false, 'error', 'مفيش صلاحية.');
  end if;
  perform pg_advisory_xact_lock(7001);
  select * into b from bookings where id = p_id and status = 'pending';
  if not found then return json_build_object('ok', false, 'error', 'الطلب ده اتعالج بالفعل.'); end if;
  if not (r = 'super' or (b.needs = 'diaconate' and r = 'diaconate') or (b.needs = 'general' and r = 'general')) then
    return json_build_object('ok', false, 'error', 'الطلب ده مش من صلاحياتك.');
  end if;
  if p_approve then
    err := public.check_rules(b.book_date, b.service_id, b.id, b.start_time, b.end_time);
    if err is not null then return json_build_object('ok', false, 'error', err); end if;
    update bookings set status = 'confirmed', decided_at = now(),
      decision_note = left(btrim(coalesce(p_note, '')), 200) where id = b.id;
  else
    update bookings set status = 'rejected', decided_at = now(),
      decision_note = left(btrim(coalesce(p_note, '')), 200) where id = b.id;
  end if;
  return json_build_object('ok', true);
end $$;

-- القراءة: الوقت والمدى
create or replace function public.get_bookings() returns json
language plpgsql stable security definer set search_path to 'public' as $$
declare
  r text := public.cur_role(); uid uuid := auth.uid();
  allow_cancel boolean := coalesce((select (value #>> '{}')::boolean from settings where key = 'allow_service_cancel'), true);
begin
  return coalesce((
    select json_agg(json_build_object(
      'id', b.id, 'date', b.book_date, 'service', b.service_id, 'name', b.name,
      'activity', b.activity, 'place', b.place, 'note', b.note, 'notifyDate', b.notify_date,
      'status', b.status, 'needs', b.needs,
      'start', to_char(b.start_time, 'HH24:MI'), 'end', to_char(b.end_time, 'HH24:MI'),
      'group', b.group_id, 'rangeEnd', b.range_end,
      'phone', case when r <> 'none' then nullif((select p.phone from profiles p where p.user_id = b.created_by), '') end,
      'canEdit', (r = 'super') or (r = 'general' and b.service_id <> 'dia')
                 or (r in ('service','diaconate') and uid is not null and b.created_by = uid),
      'canCancel', (r = 'super') or (r = 'general' and b.service_id <> 'dia')
                 or (r in ('service','diaconate') and allow_cancel and uid is not null and b.created_by = uid)
    ) order by b.book_date, b.start_time nulls first, b.created_at) from bookings b where b.status <> 'rejected'
  ), '[]'::json);
end $$;

create or replace function public.pending_requests() returns json
language plpgsql stable security definer set search_path to 'public' as $$
declare r text := public.cur_role();
begin
  if r not in ('super','diaconate','general') then return '[]'::json; end if;
  return coalesce((
    select json_agg(json_build_object(
      'id', id, 'date', book_date, 'service', service_id, 'name', name, 'needs', needs,
      'activity', activity, 'place', place, 'note', note, 'created', created_at,
      'start', to_char(start_time, 'HH24:MI'), 'end', to_char(end_time, 'HH24:MI'), 'rangeEnd', range_end
    ) order by book_date, created_at) from bookings
    where status = 'pending' and (r = 'super' or needs = r)
  ), '[]'::json);
end $$;

create or replace function public.my_requests() returns json
language sql stable security definer set search_path to 'public' as $$
  select coalesce(json_agg(json_build_object(
    'id', id, 'status', status, 'needs', needs, 'note', decision_note, 'date', book_date, 'service', service_id,
    'start', to_char(start_time, 'HH24:MI'), 'end', to_char(end_time, 'HH24:MI')
  ) order by book_date), '[]'::json)
  from bookings where auth.uid() is not null and created_by = auth.uid() and status in ('pending','rejected');
$$;

-- إشعار الحجز: مرة واحدة للحجز المتعدد الأيام، ومعاه الوقت والمدى
create or replace function public.notify_new_booking() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  secret text; ids uuid[]; svc text; msg text;
begin
  if new.created_by is null then return new; end if;
  if new.group_id is not null and exists (select 1 from public.bookings where group_id = new.group_id and id <> new.id) then
    return new;
  end if;
  select value into secret from public.push_config where key = 'hook_secret';
  if secret is null then return new; end if;
  select array_agg(distinct u) into ids from (
    select user_id as u from public.admins
    union select user_id from public.staff where role in ('general', 'diaconate')
  ) x where u <> new.created_by;
  if ids is null then return new; end if;
  select name into svc from public.services where id = new.service_id;
  msg := coalesce(svc, '') || ' - ' || to_char(new.book_date, 'DD/MM/YYYY')
         || case when new.range_end is not null then ' إلى ' || to_char(new.range_end, 'DD/MM/YYYY') else '' end
         || case when new.start_time is not null then ' (' || to_char(new.start_time, 'HH24:MI') || '-' || to_char(new.end_time, 'HH24:MI') || ')' else '' end
         || ' - ' || coalesce(new.name, '')
         || case when coalesce(new.activity, '') <> '' then ' (' || new.activity || ')' else '' end;
  perform net.http_post(
    url := 'https://gwqbmxfrufzchhlbmevl.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', secret),
    body := jsonb_build_object(
      'title', case when new.status = 'pending' then 'طلب حجز جديد بانتظار الموافقة' else 'حجز جديد' end,
      'body', msg, 'tag', 'booking-' || new.id, 'url', './index.html', 'user_ids', to_jsonb(ids)));
  return new;
exception when others then
  return new;
end $$;

revoke execute on function public.add_booking(date, text, text, text, text, time, time, date),
  public.update_booking(uuid, date, text, text, text, text, time, time, boolean),
  public.cancel_booking(uuid, boolean) from public, anon;
grant execute on function public.add_booking(date, text, text, text, text, time, time, date),
  public.update_booking(uuid, date, text, text, text, text, time, time, boolean),
  public.cancel_booking(uuid, boolean) to authenticated;
