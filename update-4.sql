-- تحديث 4: موسم خدمة الشماسية (بداية العام ونهايته).
-- الاجتماع الأسبوعي يوم الخميس بيتحسب جوه الموسم بس. برة الموسم الخميس متاح من غير موافقة.
-- لو مفيش موسم متسجل، كل الخميسات بتتحسب (زي الأول).
-- شغّله مرة واحدة في Supabase: SQL Editor ← New query ← Run.

create table if not exists public.diaconate_seasons (
  id        uuid primary key default gen_random_uuid(),
  from_date date not null,
  to_date   date not null,
  label     text not null default '',
  check (to_date >= from_date)
);
alter table public.diaconate_seasons enable row level security;
grant select on public.diaconate_seasons to anon, authenticated;
grant insert, update, delete on public.diaconate_seasons to authenticated;

drop policy if exists seasons_read on public.diaconate_seasons;
create policy seasons_read on public.diaconate_seasons for select using (true);
drop policy if exists seasons_write on public.diaconate_seasons;
create policy seasons_write on public.diaconate_seasons for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create or replace function public.needs_approval(p_date date, p_service text, p_exclude uuid)
returns boolean language sql stable set search_path = public as $$
  select extract(isodow from p_date) = 4 and p_service <> 'dia'
    and (not exists (select 1 from diaconate_seasons)
         or exists (select 1 from diaconate_seasons where p_date between from_date and to_date))
    and not exists (select 1 from bookings where book_date = p_date and status = 'confirmed' and id is distinct from p_exclude)
    and not exists (select 1 from weekly_exceptions where p_date between from_date and to_date);
$$;
revoke execute on function public.needs_approval(date, text, uuid) from public, anon, authenticated;
