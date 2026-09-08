-- Synthetic fixture only. Fresh database + both migrations required.
update tracken_private.accounts set reset_hash=extensions.digest('fixture','sha256'),reset_expires=now()+interval '1 hour';
update tracken_private.accounts set manager=true where user_id='00000000-0000-4000-8000-000000000001';
do $test$
declare a text;b text;m text;r jsonb; op jsonb; other jsonb;
begin
 set local role anon;
 a:=public.tracken_api('activate',null,'{"name":"Worker","pin":"12345678","code":"fixture"}')->>'token';
 b:=public.tracken_api('activate',null,'{"name":"Other","pin":"87654321","code":"fixture"}')->>'token';
 m:=public.tracken_api('activate',null,'{"name":"Manager","pin":"87651234","code":"fixture"}')->>'token';
 op:='{"operation_id":"00000000-0000-4000-8000-000000000101","device_id":"00000000-0000-4000-8000-000000000090","device_sequence":1,"device_occurred_at":"2026-09-01T12:00:00Z","recorded_by_user_id":"00000000-0000-4000-8000-000000000002","article_id":"00000000-0000-4000-8000-000000000020","article_name":"Test tool","movement_type":"prelievo","expected":{"state":"home","holder":null,"location":"00000000-0000-4000-8000-000000000010","last_movement_at":null}}';
 r:=public.tracken_sync('submit',null,jsonb_build_object('operation',op));assert r->>'auth_required'='true';
 r:=public.tracken_sync('submit',b,jsonb_build_object('operation',op));assert r?'error','Foreign actor';
 r:=public.tracken_sync('submit',a,jsonb_build_object('operation',op));assert r->>'status'='accepted',r::text;
 r:=public.tracken_sync('submit',a,jsonb_build_object('operation',op));assert r->>'status'='accepted','Replay lost';
 r:=public.tracken_sync('submit',a,jsonb_build_object('operation',op||'{"note":"tamper"}'));assert r?'error','Altered replay';
 other:=op||'{"operation_id":"00000000-0000-4000-8000-000000000102","device_id":"00000000-0000-4000-8000-000000000091","recorded_by_user_id":"00000000-0000-4000-8000-000000000003","device_occurred_at":"2036-09-01T12:00:00Z"}';
 r:=public.tracken_sync('submit',b,jsonb_build_object('operation',other));assert r->>'status'='review','Clock skew overwrote state';
 r:=public.tracken_sync('submit',b,jsonb_build_object('operation',other));assert r->>'status'='review','Conflict replay';
 r:=public.tracken_sync('reviews',a);assert jsonb_array_length(r->'events')=0,'Other user conflict leak';
 r:=public.tracken_sync('reviews',m);assert jsonb_array_length(r->'events')=1;
 r:=public.tracken_sync('resolve',b,'{"operation_id":"00000000-0000-4000-8000-000000000102","note":"checked"}');assert r?'error','Unauthorized resolution';
 r:=public.tracken_sync('submit',a,jsonb_build_object('operation',op||'{"operation_id":"00000000-0000-4000-8000-000000000103","previous_operation":"00000000-0000-4000-8000-000000000101","device_sequence":2,"movement_type":"restituzione"}'));assert r->>'status'='accepted','Offline chain failed';
 r:=public.tracken_sync('resolve',m,'{"operation_id":"00000000-0000-4000-8000-000000000102","note":"Verificato fisicamente; restituito dal primo operatore."}');assert r->>'ok'='true';
 r:=public.tracken_sync('receipts',b,'{"ids":["00000000-0000-4000-8000-000000000102"]}');assert r->'events'->0->>'status'='resolved','Resolution receipt missing';
 reset role;
 assert (select count(*) from public.movements)=2,'Duplicate movements';
 assert (select count(*) from tracken_private.offline_events)=3,'Conflict not preserved';
 assert (select count(*) from public.movements where device_occurred_at='2026-09-01T12:00:00Z')=2,'Device timestamp missing';
 assert (select state='home' from public.articles limit 1),'Resolution changed inventory';
 update public.users set active=false where name='Worker';
 set local role anon;
 r:=public.tracken_sync('submit',a,jsonb_build_object('operation',op));assert r->>'auth_required'='true','Revoked account accepted';
 reset role;
 raise notice 'PASS: offline idempotency, same-tool conflict, clock skew, device timestamps, causal chain, permissions, manager review, revoked user';
end $test$;
