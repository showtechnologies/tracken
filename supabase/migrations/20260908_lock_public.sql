-- Execute only in the coordinated cutover, after secure frontend and manager activation.
begin;
set local lock_timeout='5s';
do $$begin
 if not exists(select 1 from tracken_private.accounts a join public.users u on u.id=a.user_id where a.manager and a.pin_hash is not null and u.active) then
  raise exception 'Activate the designated manager before cutover';
 end if;
end$$;
alter table public.users enable row level security;
alter table public.articles enable row level security;
alter table public.locations enable row level security;
alter table public.movements enable row level security;
revoke all privileges on public.users,public.articles,public.locations,public.movements from public,anon,authenticated;
drop policy if exists "anon read users" on public.users;
drop policy if exists "anon write users" on public.users;
drop policy if exists "anon read articles" on public.articles;
drop policy if exists "anon write articles" on public.articles;
drop policy if exists "anon read locations" on public.locations;
drop policy if exists "anon write locations" on public.locations;
drop policy if exists "anon read movements" on public.movements;
drop policy if exists "anon write movements" on public.movements;
update public.users set pin_hash='disabled';
alter default privileges for role postgres in schema public revoke all on tables from anon,authenticated;
commit;
