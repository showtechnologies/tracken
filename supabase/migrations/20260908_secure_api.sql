-- Tracken: token-authenticated API. No credential values belong in this file.
begin;
create schema if not exists tracken_private;
revoke all on schema tracken_private from public;
create extension if not exists pgcrypto with schema extensions;
create table tracken_private.accounts (
 user_id uuid primary key references public.users(id),
 pin_hash text,
 manager boolean not null default false,
 reset_hash bytea,
 reset_expires timestamptz,
 failures integer not null default 0,
 locked_until timestamptz
);
create table tracken_private.sessions (
 token_hash bytea primary key,
 user_id uuid not null references public.users(id),
 expires_at timestamptz not null
);
create table tracken_private.login_budget (
 id boolean primary key default true check(id),
 starts_at timestamptz not null default now(),
 attempts integer not null default 0
);
insert into tracken_private.login_budget(id) values(true);
create table tracken_private.operations (
 operation_id uuid primary key,
 user_id uuid not null,
 request jsonb not null,
 result jsonb not null
);
insert into tracken_private.accounts(user_id) select id from public.users;
alter table tracken_private.accounts enable row level security;
alter table tracken_private.sessions enable row level security;
alter table tracken_private.login_budget enable row level security;
alter table tracken_private.operations enable row level security;
revoke all on all tables in schema tracken_private from public,anon,authenticated;

create function tracken_private.api(p_action text,p_token text,p_body jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
 u public.users; a public.articles; acc tracken_private.accounts;
 s tracken_private.sessions; budget tracken_private.login_budget;
 operation tracken_private.operations;
 token text; pin text; code text; name_in text; result jsonb; marker uuid;
 target_user uuid; target_location uuid; new_holder uuid; new_state text; expected jsonb; previous jsonb;
 movement_kind text; image_in text; uid uuid;
begin
 if p_body is null or jsonb_typeof(p_body)<>'object' or octet_length(p_body::text)>2000000 then
  return jsonb_build_object('error','Richiesta non valida.');
 end if;
 if p_action in ('login','activate') then
  name_in:=lower(btrim(p_body->>'name')); pin:=p_body->>'pin';
  if name_in is null or length(name_in)>160 or pin is null or length(pin)>64 then
   return jsonb_build_object('error','Credenziali non valide.');
  end if;
  select * into budget from tracken_private.login_budget where id for update;
  if budget.starts_at < now()-interval '1 minute' then
   update tracken_private.login_budget set starts_at=now(),attempts=1 where id;
  elsif budget.attempts>=60 then
   return jsonb_build_object('error','Troppi tentativi. Riprova tra un minuto.');
  else update tracken_private.login_budget set attempts=attempts+1 where id;
  end if;
  if (select count(*) from public.users where lower(btrim(name))=name_in and active)<>1 then
   return jsonb_build_object('error','Credenziali non valide o accesso non attivato.');
  end if;
  select * into u from public.users where lower(btrim(name))=name_in and active;
  select * into acc from tracken_private.accounts where user_id=u.id for update;
  if not found or acc.locked_until>now() then
   return jsonb_build_object('error','Credenziali non valide o accesso temporaneamente bloccato.');
  end if;
  if acc.locked_until<=now() then
   update tracken_private.accounts set failures=0,locked_until=null where user_id=u.id;
  end if;
  if p_action='activate' then
   code:=p_body->>'code';
   if acc.reset_hash is null or acc.reset_expires<=now() or code is null or length(code)>128
      or extensions.digest(code,'sha256')<>acc.reset_hash then
    update tracken_private.accounts set failures=case when locked_until<=now() then 1 else failures+1 end,
     locked_until=case when failures>=4 then now()+interval '15 minutes' else locked_until end where user_id=u.id;
    return jsonb_build_object('error','Codice non valido, scaduto o già utilizzato.');
   end if;
   if pin !~ '^[0-9]{8,12}$' then return jsonb_build_object('error','Scegli un PIN di 8–12 cifre.'); end if;
   update tracken_private.accounts set pin_hash=extensions.crypt(pin,extensions.gen_salt('bf',12)),
    reset_hash=null,reset_expires=null,failures=0,locked_until=null where user_id=u.id;
   delete from tracken_private.sessions where user_id=u.id;
  else
   if acc.pin_hash is null or extensions.crypt(pin,acc.pin_hash)<>acc.pin_hash then
    update tracken_private.accounts set failures=case when locked_until<=now() then 1 else failures+1 end,
     locked_until=case when failures>=4 then now()+interval '15 minutes' else locked_until end where user_id=u.id;
    return jsonb_build_object('error','Credenziali non valide o accesso non attivato.');
   end if;
   update tracken_private.accounts set failures=0,locked_until=null where user_id=u.id;
  end if;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  delete from tracken_private.sessions where expires_at<now();
  insert into tracken_private.sessions values(extensions.digest(token,'sha256'),u.id,now()+interval '20 minutes');
  return jsonb_build_object('token',token,'user',jsonb_build_object('id',u.id,'name',u.name,'role',u.role,'manager',acc.manager),'expires_at',now()+interval '20 minutes');
 end if;
 if p_token is null or length(p_token)<>64 then return jsonb_build_object('error','Accedi per continuare.','auth_required',true); end if;
 select * into s from tracken_private.sessions where token_hash=extensions.digest(p_token,'sha256') and expires_at>now();
 if not found then return jsonb_build_object('error','Sessione scaduta. Accedi nuovamente.','auth_required',true); end if;
 select * into u from public.users where id=s.user_id and active;
 if not found then return jsonb_build_object('error','Utente disattivato.','auth_required',true); end if;
 select * into acc from tracken_private.accounts where user_id=u.id;
 if not found then return jsonb_build_object('error','Account non attivo.','auth_required',true); end if;
 if p_action='logout' then
  delete from tracken_private.sessions where token_hash=s.token_hash;
  return jsonb_build_object('ok',true);
 end if;
 if p_action='data' then
  return jsonb_build_object(
   'user',jsonb_build_object('id',u.id,'name',u.name,'role',u.role,'manager',acc.manager),
   'users',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'role',role,'active',active) order by name),'[]') from public.users where active or acc.manager),
   'locations',(select coalesce(jsonb_agg(to_jsonb(l) order by name),'[]') from public.locations l where active or acc.manager),
   'articles',(select coalesce(jsonb_agg(to_jsonb(ar) order by name),'[]') from public.articles ar where active or acc.manager),
   'movements',(select coalesce(jsonb_agg(to_jsonb(m) order by created_at desc),'[]') from
    (select * from public.movements where acc.manager or u.role='admin' or recorded_by_user_id=u.id or from_user_id=u.id or to_user_id=u.id order by created_at desc limit 300)m));
 end if;
 if p_action='movement' then
  marker:=(p_body->>'operation_id')::uuid;
  if marker is null then return jsonb_build_object('error','Identificatore operazione mancante.'); end if;
  perform pg_advisory_xact_lock(hashtextextended(marker::text,0));
  select * into operation from tracken_private.operations where operation_id=marker;
  if found then
   if operation.user_id<>u.id or operation.request<>p_body then return jsonb_build_object('error','Operazione già utilizzata con dati diversi.'); end if;
   return operation.result;
  end if;
  select * into a from public.articles where id=(p_body->>'article_id')::uuid and active for update;
  if not found then return jsonb_build_object('error','Articolo non disponibile.'); end if;
  expected:=p_body->'expected';
  if p_body->>'previous_operation' is not null then
   select op.result->'article' into previous from tracken_private.operations op
    where op.operation_id=(p_body->>'previous_operation')::uuid and op.user_id=u.id;
   if previous is null or previous->>'id'<>a.id::text then return jsonb_build_object('error','Movimento precedente non sincronizzato.'); end if;
   expected:=jsonb_build_object('state',previous->'state','holder',previous->'current_holder_user_id','location',previous->'location_id','last_movement_at',previous->'last_movement_at');
  end if;
  if expected is null or expected <> jsonb_build_object('state',a.state,'holder',a.current_holder_user_id,'location',a.location_id,'last_movement_at',a.last_movement_at) then
   return jsonb_build_object('error','Articolo modificato da un altro operatore. Ricarica e verifica il movimento.','conflict',true);
  end if;
  movement_kind:=p_body->>'movement_type'; new_holder:=a.current_holder_user_id; new_state:=a.state; target_location:=a.location_id;
  if movement_kind='prelievo' then
   if a.state<>'home' and u.role<>'admin' then return jsonb_build_object('error','Articolo già in carico.'); end if;
   new_holder:=u.id; new_state:='in_carico';
  elsif movement_kind in ('restituzione','passaggio') then
   if a.state<>'in_carico' or (a.current_holder_user_id is distinct from u.id and u.role<>'admin') then return jsonb_build_object('error','Non puoi movimentare questo articolo.'); end if;
   if movement_kind='restituzione' then new_holder:=null; new_state:='home';
   else
    target_user:=(p_body->>'to_user_id')::uuid;
    if target_user is null or target_user=u.id or not exists(select 1 from public.users where id=target_user and active) then return jsonb_build_object('error','Destinatario non valido.'); end if;
    new_holder:=target_user;
   end if;
  elsif movement_kind='trasferimento' then
   if a.state<>'home' and u.role<>'admin' then return jsonb_build_object('error','Solo gli articoli disponibili possono essere trasferiti.'); end if;
   target_location:=(p_body->>'to_location_id')::uuid;
   if target_location is null or target_location=a.location_id or not exists(select 1 from public.locations where id=target_location and active) then return jsonb_build_object('error','Sede di destinazione non valida.'); end if;
  else return jsonb_build_object('error','Tipo movimento non valido.'); end if;
  image_in:=p_body->>'image_data';
  if image_in is not null and (length(image_in)>1500000 or image_in !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$') then return jsonb_build_object('error','Formato immagine non consentito.'); end if;
  if length(coalesce(p_body->>'note',''))>4000 then return jsonb_build_object('error','Nota troppo lunga.'); end if;
  if p_body->>'geo_lat' is not null and (p_body->>'geo_lat')::float8 not between -90 and 90 then return jsonb_build_object('error','Latitudine non valida.'); end if;
  if p_body->>'geo_lng' is not null and (p_body->>'geo_lng')::float8 not between -180 and 180 then return jsonb_build_object('error','Longitudine non valida.'); end if;
  insert into public.movements(article_id,article_name,article_serial,movement_type,from_location_id,to_location_id,from_user_id,to_user_id,recorded_by_user_id,note,image_data,session_id,geo_lat,geo_lng,geo_accuracy_m,geo_captured_at,geo_source,geo_address)
  values(a.id,a.name,a.serial,movement_kind,a.location_id,target_location,a.current_holder_user_id,new_holder,u.id,coalesce(p_body->>'note',''),image_in,marker::text,
   (p_body->>'geo_lat')::float8,(p_body->>'geo_lng')::float8,(p_body->>'geo_accuracy_m')::float8,(p_body->>'geo_captured_at')::timestamptz,
   'client_reported',left(p_body->>'geo_address',1000));
  update public.articles set state=new_state,current_holder_user_id=new_holder,location_id=target_location,
   last_known_user_id=coalesce(new_holder,last_known_user_id),last_movement_at=clock_timestamp(),last_note=coalesce(p_body->>'note','') where id=a.id returning * into a;
  result:=jsonb_build_object('ok',true,'article',to_jsonb(a));
  insert into tracken_private.operations values(marker,u.id,p_body,result);
  return result;
 end if;
 if not acc.manager then return jsonb_build_object('error','Operazione riservata al gestore.'); end if;
 if p_action='create_user' then
  name_in:=btrim(p_body->>'name');
  if name_in is null or length(name_in) not between 1 and 160 or exists(select 1 from public.users where lower(btrim(name))=lower(name_in)) or coalesce(p_body->>'role','') not in ('user','admin') then return jsonb_build_object('error','Nome già usato o dati non validi.'); end if;
  insert into public.users(name,pin_hash,role) values(name_in,'disabled',p_body->>'role') returning id into uid;
  insert into tracken_private.accounts(user_id) values(uid);
 elsif p_action in ('reset_user','role_user','disable_user') then
  uid:=(p_body->>'id')::uuid;
  if uid is null or not exists(select 1 from public.users where id=uid and active) then return jsonb_build_object('error','Utente non trovato.'); end if;
  if p_action='role_user' then
   if coalesce(p_body->>'role','') not in ('user','admin') then return jsonb_build_object('error','Ruolo non valido.'); end if;
   update public.users set role=p_body->>'role' where id=uid;
   delete from tracken_private.sessions where user_id=uid;
   return jsonb_build_object('ok',true);
  elsif p_action='disable_user' then
   if exists(select 1 from tracken_private.accounts where user_id=uid and manager) then return jsonb_build_object('error','Il gestore non può essere disattivato da questa schermata.'); end if;
   if exists(select 1 from public.articles where current_holder_user_id=uid and active) then return jsonb_build_object('error','Riassegna prima gli articoli in carico.'); end if;
   update public.users set active=false where id=uid;
   delete from tracken_private.sessions where user_id=uid;
   return jsonb_build_object('ok',true);
  end if;
 elsif p_action='create_location' then
  if length(btrim(coalesce(p_body->>'name',''))) not between 1 and 160 or coalesce(p_body->>'type','') not in ('cantiere','magazzino') then return jsonb_build_object('error','Sede non valida.'); end if;
  insert into public.locations(name,type,notes) values(btrim(p_body->>'name'),p_body->>'type',left(coalesce(p_body->>'notes',''),4000));
  return jsonb_build_object('ok',true);
 elsif p_action='disable_location' then
  uid:=(p_body->>'id')::uuid;
  if exists(select 1 from public.articles where location_id=uid and active) then return jsonb_build_object('error','La sede contiene articoli attivi.'); end if;
  update public.locations set active=false where id=uid;
  return jsonb_build_object('ok',true);
 elsif p_action='create_article' then
  if length(btrim(coalesce(p_body->>'name',''))) not between 1 and 200 or coalesce(p_body->>'state','') not in ('home','in_carico') then return jsonb_build_object('error','Articolo non valido.'); end if;
  target_location:=(p_body->>'location_id')::uuid; target_user:=(p_body->>'current_holder_user_id')::uuid;
  if not exists(select 1 from public.locations where id=target_location and active) then return jsonb_build_object('error','Sede non valida.'); end if;
  if p_body->>'state'='in_carico' and not exists(select 1 from public.users where id=target_user and active) then return jsonb_build_object('error','Utente non valido.'); end if;
  if p_body->>'state'='home' then target_user:=null; end if;
  insert into public.articles(name,category,internal_code,serial,location_id,state,current_holder_user_id,last_known_user_id)
  values(btrim(p_body->>'name'),left(coalesce(p_body->>'category',''),200),left(coalesce(p_body->>'internal_code',''),200),left(coalesce(p_body->>'serial',''),200),target_location,p_body->>'state',target_user,target_user);
  return jsonb_build_object('ok',true);
 elsif p_action='disable_article' then
  uid:=(p_body->>'id')::uuid;
  if exists(select 1 from public.articles where id=uid and state='in_carico') then return jsonb_build_object('error','Restituisci prima l’articolo.'); end if;
  update public.articles set active=false where id=uid;
  return jsonb_build_object('ok',true);
 else return jsonb_build_object('error','Operazione non valida.'); end if;
 -- One-time activation; no PIN is selected by the administrator.
 code:=encode(extensions.gen_random_bytes(24),'hex');
 update tracken_private.accounts set pin_hash=null,reset_hash=extensions.digest(code,'sha256'),reset_expires=now()+interval '24 hours',failures=0,locked_until=null where user_id=uid;
 delete from tracken_private.sessions where user_id=uid;
 return jsonb_build_object('ok',true,'activation_code',code,'user_id',uid);
exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then
 return jsonb_build_object('error','Dati non validi.');
end $fn$;
revoke all on function tracken_private.api(text,text,jsonb) from public;
grant usage on schema tracken_private to anon,authenticated;
grant execute on function tracken_private.api(text,text,jsonb) to anon,authenticated;
create function public.tracken_api(p_action text,p_token text default null,p_body jsonb default '{}')
returns jsonb language sql security invoker set search_path='' as $fn$
 select tracken_private.api(p_action,p_token,p_body);
$fn$;
revoke all on function public.tracken_api(text,text,jsonb) from public;
grant execute on function public.tracken_api(text,text,jsonb) to anon,authenticated;
commit;
