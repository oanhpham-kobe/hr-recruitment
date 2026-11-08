#!/usr/bin/env bash
set -euo pipefail
container_name="supabase_db_eiu-recruitment-dev"
psql_exec() { docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"; }
wait_pair() {
  local label="$1" pid_a="$2" pid_b="$3" out_a="$4" err_a="$5" out_b="$6" err_b="$7" status_a status_b
  set +e; wait "$pid_a"; status_a=$?; wait "$pid_b"; status_b=$?; set -e
  if [[ "$status_a" -ne 0 || "$status_b" -ne 0 ]]; then
    echo "S07 background failure: $label (pid=$pid_a exit=$status_a, pid=$pid_b exit=$status_b)" >&2
    echo "--- $label pid=$pid_a stdout ---" >&2; cat "$out_a" >&2
    echo "--- $label pid=$pid_a stderr ---" >&2; cat "$err_a" >&2
    echo "--- $label pid=$pid_b stdout ---" >&2; cat "$out_b" >&2
    echo "--- $label pid=$pid_b stderr ---" >&2; cat "$err_b" >&2
    return 1
  fi
}
suffix="$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-12)"
psql_exec <<SQL
update public.email_outbox set next_attempt_at=clock_timestamp()+interval '1 day'
where request_fingerprint is not null;
do \$\$
declare v_actor uuid:=gen_random_uuid(); v_auth uuid:=gen_random_uuid(); v_i uuid;
declare v_cand uuid:=gen_random_uuid(); v_cand_auth uuid:=gen_random_uuid(); v_sub uuid:=gen_random_uuid();
declare v_unit uuid; v_group uuid; v_pos uuid; v_app uuid;
begin
 insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active)
 values(v_actor,v_auth,'s07-worker-'||'${suffix}'||'@eiu.edu.vn','S07 Worker',true);
 insert into public.app_user_roles(app_user_id,role_code) values(v_actor,'HR');
 insert into public.candidates(candidate_id,auth_user_id,email,current_full_name,is_active)
 values(v_cand,v_cand_auth,'s07-candidate-'||'${suffix}'||'@example.invalid','S07 Candidate',true);
 insert into public.submissions(submission_id,candidate_id,status_code,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot)
 values(v_sub,v_cand,'NEW','S07 Candidate','1990-01-01','MALE','S07 address','0900000000','s07-candidate-'||'${suffix}'||'@example.invalid');
 insert into public.organizational_units(code,name_vi) values('S07_'||'${suffix}','S07') returning unit_id into v_unit;
 insert into public.position_groups(code,name_vi) values('S07_'||'${suffix}','S07') returning position_group_id into v_group;
 insert into public.positions(code,name_vi,unit_id,position_group_id) values('S07_'||'${suffix}','S07',v_unit,v_group) returning position_id into v_pos;
 insert into public.applications(submission_id,unit_id,position_id,hr_owner_id) values(v_sub,v_unit,v_pos,v_actor) returning application_id into v_app;
 insert into public.interviews(application_id,round_no,visible_to_interviewers) values(v_app,1,true) returning interview_id into v_i;
-- actor fixture is inserted before Application so ownership eligibility can be checked.
 insert into public.app_user_permissions(app_user_id,permission_code,granted_by,granted_at)
 values(v_actor,'interviews.email',v_actor,clock_timestamp()),(v_actor,'interviews.view',v_actor,clock_timestamp());
 insert into public.interview_participants(interview_id,app_user_id,participant_order,snapshot_name,snapshot_email)
 values(v_i,v_actor,1,'S07 Worker','s07-worker-'||'${suffix}'||'@eiu.edu.vn');
end\$\$;
do \$\$
declare v_i uuid; v_a uuid; v_s uuid; v_snap jsonb; v_id uuid;
begin
 select i.interview_id,a.application_id,a.submission_id into v_i,v_a,v_s
 from public.interviews i join public.applications a on a.application_id=i.application_id
 where i.is_active and a.is_active and a.hr_owner_id=(select app_user_id from public.app_users where email='s07-worker-'||'${suffix}'||'@eiu.edu.vn')
   and not exists (select 1 from public.interview_participants ip join public.app_users pu on pu.app_user_id=ip.app_user_id
                   where ip.interview_id=i.interview_id and ip.is_current and ip.removed_at is null and not pu.is_active)
 order by i.interview_id limit 1;
 if v_i is null then raise exception 'S07 requires an Interview-backed outbox fixture'; end if;
 v_snap:=private.email_snapshot('INTERVIEW_INVITATION',v_s,v_a,v_i);
 insert into public.email_outbox(submission_id,application_id,interview_id,email_type,environment_code,
   recipients,subject,body_text,template_version,idempotency_key,actor_scope,request_fingerprint,
   context_fingerprint,next_attempt_at)
 values(v_s,v_a,v_i,'INTERVIEW_INVITATION',v_snap->>'environment_code',v_snap->'recipients',
   v_snap->>'subject',v_snap->>'body_text',v_snap->>'template_version',gen_random_uuid(),
   's07:'||'${suffix}','${suffix}',v_snap->>'context_fingerprint',clock_timestamp())
 returning email_outbox_id into v_id;
 if not exists(select 1 from public.email_outbox where email_outbox_id=v_id and context_fingerprint is not null) then
   raise exception 'S07 snapshot-bound fixture missing context fingerprint';
 end if;
end\$\$;
SQL
actor_row="$(docker exec -i "$container_name" psql -qAt -F ' ' -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select u.app_user_id,u.auth_user_id,i.interview_id,a.application_id,a.submission_id from public.app_users u join public.app_user_permissions p on p.app_user_id=u.app_user_id join public.interviews i on i.is_active join public.applications a on a.application_id=i.application_id where p.permission_code='interviews.email' and u.email='s07-worker-${suffix}@eiu.edu.vn' and u.is_active and a.is_active and a.hr_owner_id=u.app_user_id and not exists (select 1 from public.interview_participants ip join public.app_users pu on pu.app_user_id=ip.app_user_id where ip.interview_id=i.interview_id and ip.is_current and ip.removed_at is null and not pu.is_active) order by i.interview_id limit 1")"
if [[ -z "$actor_row" ]]; then echo 'S07 setup failed: authenticated worker actor fixture missing' >&2; exit 1; fi
read -r actor actor_auth interview application submission <<<"$actor_row"
preview="$(docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "begin; select set_config('request.jwt.claim.sub','$actor_auth',true); select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth')::text,true); set local role authenticated; select public.preview_email('INTERVIEW_INVITATION','$interview','$application','$submission'); commit" | tr -d '\r' | tail -n 1)"
if ! jq -e '.success == true' <<<"$preview" >/dev/null; then echo 'trusted preview fixture failed' >&2; exit 1; fi
fingerprint="$(jq -r '.data.preview_fingerprint' <<<"$preview")"
request="$(jq -cn --arg t INTERVIEW_INVITATION --arg i "$interview" --arg a "$application" --arg s "$submission" --arg f "$fingerprint" '{email_type:$t,interview_id:$i,application_id:$a,submission_id:$s,preview_fingerprint:$f}')"
same_key="$(uuidgen)"
enqueue_sql="begin; select set_config('request.jwt.claim.sub','$actor_auth',true); select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth')::text,true); set local role authenticated; select public.enqueue_email('$request','$same_key'); commit"
docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$enqueue_sql" >/tmp/s07-enqueue-a.txt 2>/tmp/s07-enqueue-a.err & p1=$!
docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$enqueue_sql" >/tmp/s07-enqueue-b.txt 2>/tmp/s07-enqueue-b.err & p2=$!
wait_pair same-key-enqueue "$p1" "$p2" /tmp/s07-enqueue-a.txt /tmp/s07-enqueue-a.err /tmp/s07-enqueue-b.txt /tmp/s07-enqueue-b.err
enqueue_a="$(tr -d '\r' </tmp/s07-enqueue-a.txt | tail -n 1)"; enqueue_b="$(tr -d '\r' </tmp/s07-enqueue-b.txt | tail -n 1)"
if ! jq -e '.success == true' <<<"$enqueue_a" >/dev/null || ! jq -e '.success == true' <<<"$enqueue_b" >/dev/null ||
   [[ "$(jq -r '.data.email_outbox_id' <<<"$enqueue_a")" != "$(jq -r '.data.email_outbox_id' <<<"$enqueue_b")" ]]; then
  echo 'same-key concurrent enqueue must converge on one outbox row' >&2; exit 1;
fi
bulk_key="$(uuidgen)"
bulk_sql="begin; select set_config('request.jwt.claim.sub','$actor_auth',true); select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth')::text,true); set local role authenticated; select public.bulk_enqueue_email(jsonb_build_array('$request'::jsonb),'$bulk_key'); commit"
docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$bulk_sql" >/tmp/s07-bulk-a.txt 2>/tmp/s07-bulk-a.err & p1=$!
docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$bulk_sql" >/tmp/s07-bulk-b.txt 2>/tmp/s07-bulk-b.err & p2=$!
wait_pair overlapping-bulk "$p1" "$p2" /tmp/s07-bulk-a.txt /tmp/s07-bulk-a.err /tmp/s07-bulk-b.txt /tmp/s07-bulk-b.err
bulk_a="$(tr -d '\r' </tmp/s07-bulk-a.txt | tail -n 1)"; bulk_b="$(tr -d '\r' </tmp/s07-bulk-b.txt | tail -n 1)"
if [[ "$bulk_a" != "$bulk_b" ]] || ! jq -e '.success | length == 1' <<<"$bulk_a" >/dev/null; then
  echo 'overlapping bulk requests must converge without duplicate target outcome' >&2; exit 1;
fi
participant="$(docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select interview_participant_id from public.interview_participants where interview_id='$interview' and app_user_id='$actor' and is_current limit 1")"
if [[ -z "$participant" ]]; then echo 'participant-change race requires a participant fixture' >&2; exit 1; fi
participant_key="$(uuidgen)"
alt_request="$(jq -c --arg i "{${interview}}" '.interview_id=$i' <<<"$request")"
participant_bulk_key="$(uuidgen)"
participant_bulk_sql="begin; select set_config('request.jwt.claim.sub','$actor_auth',true); select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth')::text,true); set local role authenticated; select public.bulk_enqueue_email(jsonb_build_array('$alt_request'::jsonb),'$participant_bulk_key'); commit"
participant_sql="begin; select set_config('request.jwt.claim.sub','$actor_auth',true); select set_config('request.jwt.claims',jsonb_build_object('sub','$actor_auth')::text,true); set local role authenticated; select public.enqueue_email('$request','$participant_key'); commit"
docker exec -e PGAPPNAME="s07-holder-${suffix}" -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "begin; select 1 from public.interviews where interview_id='$interview' for update; select pg_advisory_xact_lock(hashtextextended('s07-ready:${suffix}',0)); select pg_sleep(5); update public.interview_participants set is_current=false,removed_at=clock_timestamp() where interview_participant_id='$participant'; commit" >/tmp/s07-participant-holder.txt 2>/tmp/s07-participant-holder.err & p1=$!
holder_ready=false
for _ in {1..50}; do
  if [[ "$(docker exec -i "$container_name" psql -qAt -U postgres -d postgres -c "select count(*) from pg_stat_activity a join pg_locks l on l.pid=a.pid where a.application_name='s07-holder-${suffix}' and l.locktype='advisory' and l.granted")" == "1" ]]; then holder_ready=true; break; fi
  sleep 0.1
done
if [[ "$holder_ready" != true ]]; then echo 'participant holder readiness timeout' >&2; exit 1; fi
docker exec -e PGAPPNAME="s07-bulk-${suffix}" -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$participant_bulk_sql" >/tmp/s07-participant-bulk.txt 2>/tmp/s07-participant-bulk.err & p2=$!
bulk_blocked=false
for _ in {1..50}; do
  if [[ "$(docker exec -i "$container_name" psql -qAt -U postgres -d postgres -c "select count(*) from pg_stat_activity where application_name='s07-bulk-${suffix}' and wait_event_type='Lock' and query like '%bulk_enqueue_email%'")" == "1" ]]; then bulk_blocked=true; break; fi
  sleep 0.1
done
if [[ "$bulk_blocked" != true ]]; then echo 'participant bulk did not block behind held Interview lock' >&2; kill "$p1" "$p2" 2>/dev/null || true; exit 1; fi
participant_result="$(docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$participant_sql" 2>/tmp/s07-participant-enqueue.err | tr -d '\r' | tail -n 1)"
set +e; wait "$p1"; participant_status=$?; wait "$p2"; bulk_status=$?; set -e
if [[ "$participant_status" -ne 0 || "$bulk_status" -ne 0 ]]; then echo "participant barrier failure holder=$participant_status bulk=$bulk_status" >&2; cat /tmp/s07-participant-holder.txt /tmp/s07-participant-holder.err /tmp/s07-participant-bulk.txt /tmp/s07-participant-bulk.err >&2; exit 1; fi
participant_bulk_result="$(tr -d '\r' </tmp/s07-participant-bulk.txt | tail -n 1)"
if [[ -s /tmp/s07-participant-bulk.err ]]; then echo 'S07 participant bulk stderr:' >&2; cat /tmp/s07-participant-bulk.err >&2; fi
if ! jq -e '((.failed | length) == 1) and (.failed[0].error_code == "STALE_PREVIEW" or .failed[0].error_code == "FORBIDDEN")' <<<"$participant_bulk_result" >/dev/null; then
  echo 'participant change must invalidate brace-spelled bulk enqueue' >&2; exit 1;
fi
if ! jq -e '.success == false and (.error_code == "STALE_PREVIEW" or .error_code == "FORBIDDEN")' <<<"$participant_result" >/dev/null; then
  echo 'participant change must invalidate concurrent enqueue' >&2; exit 1;
fi
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "update public.interview_participants set is_current=true,removed_at=null where interview_participant_id='$participant'"
message="$(docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select email_outbox_id from public.email_outbox where actor_scope='s07:${suffix}'")"
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "update public.email_outbox set next_attempt_at=clock_timestamp()+interval '1 day' where request_fingerprint is not null and email_outbox_id<>'$message'::uuid"
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "update private.email_configuration set delivery_paused=false,delivery_not_before=null where singleton"
call="select public.claim_email_outbox('worker-${suffix}',1)::text;"
docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$call" >/tmp/s07-worker-a.txt 2>/tmp/s07-worker-a.err & p1=$!
docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$call" >/tmp/s07-worker-b.txt 2>/tmp/s07-worker-b.err & p2=$!
wait_pair worker-claim "$p1" "$p2" /tmp/s07-worker-a.txt /tmp/s07-worker-a.err /tmp/s07-worker-b.txt /tmp/s07-worker-b.err
claim_count="$(docker exec -i "$container_name" psql -qAt -U postgres -d postgres -c "select count(*) from public.email_outbox where actor_scope='s07:${suffix}' and status_code='SENDING'")"
if [[ "$claim_count" -ne 1 ]]; then
  echo "S07 claim diagnostic: worker-a=$(cat /tmp/s07-worker-a.txt) worker-b=$(cat /tmp/s07-worker-b.txt)" >&2
  docker exec -i "$container_name" psql -U postgres -d postgres -c "select email_outbox_id,status_code,next_attempt_at,attempt_no,locked_until,request_fingerprint from public.email_outbox where actor_scope='s07:${suffix}'; select delivery_paused,delivery_not_before from private.email_configuration; select count(*) as claim_eligible from public.email_outbox where request_fingerprint is not null and ((status_code='QUEUED' or (status_code='FAILED' and next_attempt_at is not null)) and attempt_no<3 and coalesce(next_attempt_at,clock_timestamp())<=clock_timestamp() or (status_code='SENDING' and locked_until<=clock_timestamp()));" >&2
fi
psql_exec <<SQL
do \$\$
declare n integer;
begin
 select count(*) into n from public.email_outbox where actor_scope='s07:${suffix}' and status_code='SENDING';
 assert n=1, 'SKIP LOCKED permits one live owner';
 select count(*) into n from private.email_attempts ea join public.email_outbox eo on eo.email_outbox_id=ea.email_outbox_id where eo.actor_scope='s07:${suffix}';
 assert n=1, 'one attempt identity for one logical message';
end\$\$;
SQL
token="$(docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select ea.attempt_id from private.email_attempts ea join public.email_outbox eo on eo.attempt_id=ea.attempt_id where eo.actor_scope='s07:${suffix}' and eo.status_code='SENDING'")"
message="$(docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select email_outbox_id from public.email_outbox where actor_scope='s07:${suffix}'")"
docker exec -i "$container_name" psql -qAt -U postgres -d postgres -c "select email_outbox_id,status_code,attempt_id,worker_id,locked_until,next_attempt_at from public.email_outbox where email_outbox_id='$message'" >/tmp/s07-before-expiry.txt
docker exec -i "$container_name" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "update public.email_outbox set locked_until=clock_timestamp()-interval '1 second' where email_outbox_id='$message'"
docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "begin; set local statement_timeout='10s'; select public.authorize_email_send('$message','$token','worker-${suffix}'); commit" >/tmp/s07-authorize-late.txt 2>/tmp/s07-authorize-late.err & p1=$!
docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select public.claim_email_outbox('reclaim-${suffix}',1)" >/tmp/s07-reclaim.txt 2>/tmp/s07-reclaim.err & p2=$!
wait_pair reclaim-vs-late-auth "$p1" "$p2" /tmp/s07-authorize-late.txt /tmp/s07-authorize-late.err /tmp/s07-reclaim.txt /tmp/s07-reclaim.err
token="$(docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select ea.attempt_id from private.email_attempts ea join public.email_outbox eo on eo.attempt_id=ea.attempt_id where eo.actor_scope='s07:${suffix}' and eo.status_code='SENDING'")"
if [[ -z "$token" ]]; then echo 'reclaim versus late authorization did not produce a live staged attempt' >&2; exit 1; fi
auth_result="$(docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select public.authorize_email_send('$message','$token','reclaim-${suffix}')")"
if ! jq -e '.success == true' <<<"$auth_result" >/dev/null; then
  echo "S07 reclaim/auth diagnostic: before-expiry=$(cat /tmp/s07-before-expiry.txt) auth_result=$auth_result reclaim=$(cat /tmp/s07-reclaim.txt)" >&2
  echo 'reclaimed snapshot-bound attempt must authorize' >&2; exit 1;
fi
docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "begin; set local statement_timeout='10s'; select public.complete_email_attempt('$message','$token','reclaim-${suffix}','SENT','s07-provider',null); commit" >/tmp/s07-complete.txt 2>/tmp/s07-complete.err & p1=$!
docker exec -i "$container_name" psql -qAt -v ON_ERROR_STOP=1 -U postgres -d postgres -c "select public.authorize_email_send('$message','$token','reclaim-${suffix}')" >/tmp/s07-authorize-complete.txt 2>/tmp/s07-authorize-complete.err & p2=$!
wait_pair completion-vs-authorization "$p1" "$p2" /tmp/s07-complete.txt /tmp/s07-complete.err /tmp/s07-authorize-complete.txt /tmp/s07-authorize-complete.err
psql_exec <<SQL
do \$\$
declare n integer;
begin
 select count(*) into n from public.email_history h
   join private.email_attempts ea on ea.attempt_id=h.attempt_id
   where ea.email_outbox_id='$message'::uuid and ea.status_code='SENT';
 assert n=1, 'completion/authorization race must retain one SENT history row';
 assert (select status_code='SENT' and attempt_id='$token'::uuid from public.email_outbox where email_outbox_id='$message'::uuid),
   'completion/authorization race must finalize the fenced attempt';
 select count(*) into n from public.security_audit_log where entity_id='$message'::uuid and action_code='EMAIL_SENT';
 assert n=1, 'completion must write one immutable send audit';
end\$\$;
SQL
echo "TASK-S07-001 staged lock-order assertions passed (${suffix})"
exit 0
