-- تحديث 2: إدارة المستخدمين من صفحة الإدارة.
-- أي حد يقدر يعمل حساب، بس الحساب مبيبقاش مشرف غير لما مشرف يوافق عليه.
-- شغّله مرة واحدة في Supabase: SQL Editor ← New query ← Run.

create or replace function public.list_users() returns json
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not is_admin() then return '[]'::json; end if;
  return coalesce((
    select json_agg(json_build_object(
      'id', u.id, 'email', u.email, 'created', u.created_at,
      'is_admin', exists (select 1 from public.admins a where a.user_id = u.id)
    ) order by u.created_at desc) from auth.users u
  ), '[]'::json);
end $$;

create or replace function public.set_admin(p_user uuid, p_make boolean) returns json
language plpgsql security definer set search_path = public, auth as $$
begin
  if not is_admin() then
    return json_build_object('ok', false, 'error', 'للمشرف بس.');
  end if;
  if p_make then
    insert into public.admins (user_id) values (p_user) on conflict do nothing;
  else
    if p_user = auth.uid() then
      return json_build_object('ok', false, 'error', 'مينفعش تشيل الإشراف عن نفسك.');
    end if;
    delete from public.admins where user_id = p_user;
  end if;
  return json_build_object('ok', true);
end $$;

revoke execute on function public.list_users(), public.set_admin(uuid, boolean) from public, anon;
grant execute on function public.list_users(), public.set_admin(uuid, boolean) to authenticated;
