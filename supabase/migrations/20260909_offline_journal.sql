begin;
set local lock_timeout='5s';
alter table public.movements add column if not exists device_occurred_at timestamptz;
alter table public.movements add column if not exists device_id uuid;
alter table public.movements add column if not exists device_sequence bigint;
create table tracken_private.offline_events (
 operation_id uuid primary key,
 user_id uuid not null references public.users(id),
 device_id uuid not null,
 device_sequence bigint not null check(device_sequence>0),
 device_occurred_at timestamptz not null,
 received_at timestamptz not null default clock_timestamp(),
 request jsonb not null,
 status text not null check(status in ('accepted','review','resolved')),
 result jsonb not null,
 resolved_by uuid references public.users(id),
 resolved_at timestamptz,
 resolution_note text,
 unique(device_id,device_sequence)
);
alter table tracken_private.offline_events enable row level security;
revoke all on tracken_private.offline_events from public,anon,authenticated;
create function tracken_private.sync(p_action text,p_token text,p_body jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
 actor uuid; manager boolean; op jsonb; event_id uuid; device uuid; seq bigint; happened timestamptz;
 existing tracken_private.offline_events; answer jsonb; final_status text;
begin
 if p_body is null or jsonb_typeof(p_body)<>'object' or octet_length(p_body::text)>2000000 then return jsonb_build_object('error','Richiesta non valida.'); end if;
 if p_token is null or length(p_token)<>64 then return jsonb_build_object('auth_required',true); end if;
 select u.id,a.manager into actor,manager from tracken_private.sessions s join public.users u on u.id=s.user_id join tracken_private.accounts a on a.user_id=u.id
 where s.token_hash=extensions.digest(p_token,'sha256') and s.expires_at>now() and u.active;
 if actor is null then return jsonb_build_object('auth_required',true); end if;
 if p_action='receipts' then
  if jsonb_typeof(p_body->'ids') is distinct from 'array' or jsonb_array_length(p_body->'ids')>100 then return jsonb_build_object('error','Richiesta non valida.'); end if;
  return jsonb_build_object('events',(select coalesce(jsonb_agg(jsonb_build_object('operation_id',e.operation_id,'status',e.status,'result',e.result,'resolution_note',e.resolution_note)),'[]') from tracken_private.offline_events e where e.user_id=actor and e.operation_id::text in (select jsonb_array_elements_text(p_body->'ids'))));
 elsif p_action='reviews' then
  return jsonb_build_object('events',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from
   (select e.operation_id,e.device_occurred_at,e.received_at,e.device_id,e.device_sequence,e.result->>'reason' as reason,
    e.request->>'article_name' as article_name,e.request->>'movement_type' as movement_type,u.name as user_name
    from tracken_private.offline_events e join public.users u on u.id=e.user_id
    where e.status='review' and (manager or e.user_id=actor) order by e.received_at limit 100)r));
 elsif p_action='resolve' then
  if not manager then return jsonb_build_object('error','Solo il gestore può registrare la verifica.'); end if;
  if length(btrim(coalesce(p_body->>'note',''))) not between 3 and 2000 then return jsonb_build_object('error','Descrivi la verifica (3–2000 caratteri).'); end if;
  update tracken_private.offline_events set status='resolved',resolved_by=actor,resolved_at=clock_timestamp(),resolution_note=btrim(p_body->>'note')
   where operation_id=(p_body->>'operation_id')::uuid and status='review';
  if not found then return jsonb_build_object('error','Verifica non trovata o già conclusa.'); end if;
  return jsonb_build_object('ok',true);
 elsif p_action<>'submit' then return jsonb_build_object('error','Operazione non valida.'); end if;
 op:=p_body->'operation';
 if op is null or jsonb_typeof(op)<>'object' then return jsonb_build_object('error','Movimento mancante.'); end if;
 event_id:=(op->>'operation_id')::uuid;device:=(op->>'device_id')::uuid;seq:=(op->>'device_sequence')::bigint;happened:=(op->>'device_occurred_at')::timestamptz;
 if event_id is null or device is null or seq is null or seq<1 or happened is null or not isfinite(happened) then return jsonb_build_object('error','Identificativi o orario del dispositivo mancanti.'); end if;
 -- Ownership comes from a live session. A stored offline profile is not a server credential.
 if (op->>'recorded_by_user_id') is distinct from actor::text then return jsonb_build_object('error','Accedi con l’utente che ha registrato il movimento.'); end if;
 perform pg_advisory_xact_lock(hashtextextended(device::text,1));
 perform pg_advisory_xact_lock(hashtextextended(event_id::text,2));
 select * into existing from tracken_private.offline_events where operation_id=event_id;
 if found then
  if existing.user_id<>actor or existing.request<>op then return jsonb_build_object('error','Identificatore già utilizzato con dati diversi.'); end if;
  return existing.result||jsonb_build_object('status',existing.status);
 end if;
 if exists(select 1 from tracken_private.offline_events where device_id=device and device_sequence=seq) then return jsonb_build_object('error','Sequenza dispositivo duplicata: conserva ed esporta la registrazione per verifica.'); end if;
 -- Core validates role, ownership, expected state and predecessor; no timestamp wins automatically.
 answer:=tracken_private.api('movement',p_token,op);
 if answer->>'auth_required'='true' then return answer; end if;
 final_status:=case when answer->>'ok'='true' then 'accepted' else 'review' end;
 if final_status='accepted' then
  update public.movements set device_occurred_at=happened,device_id=device,device_sequence=seq where session_id=event_id::text and recorded_by_user_id=actor;
 end if;
 answer:=jsonb_build_object('status',final_status,'operation_id',event_id,'received_at',clock_timestamp(),'reason',answer->>'error');
 insert into tracken_private.offline_events(operation_id,user_id,device_id,device_sequence,device_occurred_at,request,status,result)
 values(event_id,actor,device,seq,happened,op,final_status,answer);
 return answer;
exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then
 return jsonb_build_object('error','Identificativi o data non validi: registrazione conservata sul telefono.');
end $fn$;
revoke all on function tracken_private.sync(text,text,jsonb) from public;
grant execute on function tracken_private.sync(text,text,jsonb) to anon,authenticated;
create function public.tracken_sync(p_action text,p_token text default null,p_body jsonb default '{}')
returns jsonb language sql security invoker set search_path='' as $fn$ select tracken_private.sync(p_action,p_token,p_body); $fn$;
revoke all on function public.tracken_sync(text,text,jsonb) from public;
grant execute on function public.tracken_sync(text,text,jsonb) to anon,authenticated;
commit;
