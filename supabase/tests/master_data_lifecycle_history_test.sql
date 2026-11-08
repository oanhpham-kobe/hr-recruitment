-- TASK-S06-001: Master Data lifecycle/history/security/idempotency regressions.
\set ON_ERROR_STOP on

do $$
declare
  v_suffix text := substr(gen_random_uuid()::text, 1, 8);
  v_hr_auth uuid := gen_random_uuid();
  v_hr uuid;
  v_hr2_auth uuid := gen_random_uuid();
  v_hr2 uuid;
  v_no_perm_auth uuid := gen_random_uuid();
  v_no_perm uuid;
  v_root_auth uuid := gen_random_uuid();
  v_root uuid;
  v_candidate_auth uuid := gen_random_uuid();
  v_candidate uuid;
  v_result jsonb;
  v_result2 jsonb;
  v_key uuid;
  v_audit_before bigint;
  v_audit_after bigint;
  v_version bigint;
  v_version2 bigint;
  v_unit uuid;
  v_unit2 uuid;
  v_team uuid;
  v_group uuid;
  v_position uuid;
  v_qualification uuid;
  v_room uuid;
  v_room2 uuid;
  v_format uuid;
  v_source uuid;
  v_doc_type uuid;
  v_cancel_reason uuid;
  v_reject_reason uuid;
  v_submission uuid;
  v_application uuid;
  v_interview uuid;
  v_logical uuid;
begin
  raise notice '=== TASK-S06-001 Master Data lifecycle/history ===';

  -- ---------------------------------------------------------------------------
  -- ACL and function exposure.
  -- ---------------------------------------------------------------------------
  assert not has_function_privilege('anon', 'public.create_master_item(text,jsonb,uuid)', 'EXECUTE'),
    'anon must not execute create_master_item';
  assert not has_function_privilege('anon', 'public.update_master_item(text,uuid,jsonb,bigint,uuid)', 'EXECUTE'),
    'anon must not execute update_master_item';
  assert not has_function_privilege('anon', 'public.delete_or_inactivate_master_item(text,uuid,bigint,uuid)', 'EXECUTE'),
    'anon must not execute delete_or_inactivate_master_item';
  assert has_function_privilege('authenticated', 'public.create_master_item(text,jsonb,uuid)', 'EXECUTE'),
    'authenticated may invoke create wrapper subject to server authorization';
  assert not has_function_privilege('authenticated', 'private.master_usage_exists(text,uuid)', 'EXECUTE'),
    'authenticated cannot execute private usage helper';
  assert not has_function_privilege('authenticated', 'private.normalize_master_payload(text,jsonb,text)', 'EXECUTE'),
    'authenticated cannot execute private normalization helper';

  assert not has_table_privilege('authenticated', 'public.organizational_units', 'INSERT'),
    'authenticated has no direct master INSERT';
  assert not has_table_privilege('authenticated', 'public.organizational_units', 'UPDATE'),
    'authenticated has no direct master UPDATE';
  assert not has_table_privilege('authenticated', 'public.organizational_units', 'DELETE'),
    'authenticated has no direct master DELETE';
  assert not has_table_privilege('authenticated', 'public.document_types', 'UPDATE'),
    'authenticated has no direct Document Type mutation';

  -- ---------------------------------------------------------------------------
  -- Actors.
  -- ---------------------------------------------------------------------------
  insert into public.app_users(auth_user_id, email, full_name, is_active)
  values (v_hr_auth, 's06001_hr_' || v_suffix || '@eiu.edu.vn', 'S06-001 HR', true)
  returning app_user_id into v_hr;

  insert into public.app_users(auth_user_id, email, full_name, is_active)
  values (v_hr2_auth, 's06001_hr2_' || v_suffix || '@eiu.edu.vn', 'S06-001 HR 2', true)
  returning app_user_id into v_hr2;

  insert into public.app_users(auth_user_id, email, full_name, is_active)
  values (v_no_perm_auth, 's06001_none_' || v_suffix || '@eiu.edu.vn', 'S06-001 No Permission', true)
  returning app_user_id into v_no_perm;

  select u.app_user_id, u.auth_user_id
    into v_root, v_root_auth
  from public.app_users u
  where u.is_root_admin = true
    and u.is_active = true
  limit 1;

  if v_root is null then
    insert into public.app_users(auth_user_id, email, full_name, is_active, is_root_admin)
    values (v_root_auth, 's06001_root_' || v_suffix || '@eiu.edu.vn', 'S06-001 Root', true, true)
    returning app_user_id into v_root;
  elsif v_root_auth is null then
    v_root_auth := gen_random_uuid();
    update public.app_users
    set auth_user_id = v_root_auth
    where app_user_id = v_root;
  end if;

  insert into public.app_user_roles(app_user_id, role_code)
  values (v_hr, 'HR')
  on conflict do nothing;

  insert into public.app_user_permissions(app_user_id, permission_code)
  values
    (v_hr, 'master_data.manage'),
    (v_hr2, 'master_data.manage'),
    (v_hr, 'interviews.view'),
    (v_hr, 'interviews.status')
  on conflict do nothing;

  -- ---------------------------------------------------------------------------
  -- Authentication, permission, allowlist, closed DTO.
  -- ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', '{}'::jsonb::text, true);
  v_result := public.create_master_item('organizational_units', jsonb_build_object('name_vi','Denied'), gen_random_uuid());
  assert v_result->>'error_code' = 'UNAUTHENTICATED', 'no-auth create must fail closed';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_no_perm_auth::text)::text, true);
  v_result := public.create_master_item('organizational_units', jsonb_build_object('name_vi','Denied'), gen_random_uuid());
  assert v_result->>'error_code' = 'FORBIDDEN', 'missing master_data.manage must fail closed';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr_auth::text)::text, true);
  v_result := public.create_master_item('app_users', jsonb_build_object('name_vi','No'), gen_random_uuid());
  assert v_result->>'error_code' = 'VALIDATION_ERROR', 'unknown/out-of-scope master type rejected';
  v_result := public.create_master_item(
    'organizational_units',
    jsonb_build_object('name_vi','Unknown Field', 'table_name','app_users'),
    gen_random_uuid()
  );
  assert v_result->>'error_code' = 'VALIDATION_ERROR', 'unknown payload field rejected';

  -- ---------------------------------------------------------------------------
  -- CREATE: positive path + sequential replay + mismatch + audit exactly once.
  -- ---------------------------------------------------------------------------
  v_key := gen_random_uuid();
  v_result := public.create_master_item(
    'organizational_units',
    jsonb_build_object('code','S06001_UNIT_' || v_suffix, 'name_vi','  Khoa kiểm thử  ', 'name_en','Test Unit'),
    v_key
  );
  assert (v_result->>'success')::boolean, 'authorized create succeeds';
  v_unit := (v_result->'data'->>'master_id')::uuid;
  assert (v_result->'data'->>'version_no')::bigint = 1, 'created master starts at version 1';
  assert (select name_vi from public.organizational_units where unit_id = v_unit) = 'Khoa kiểm thử',
    'create normalizes display label';
  v_result2 := public.create_master_item(
    'organizational_units',
    jsonb_build_object('name_en','Test Unit', 'name_vi','Khoa kiểm thử', 'code','S06001_UNIT_' || v_suffix),
    v_key
  );
  assert v_result2 = v_result, 'same create key/fingerprint replays stored typed result';
  assert (select count(*) from public.organizational_units where unit_id = v_unit) = 1,
    'create replay produces one business row';
  assert (select count(*) from public.security_audit_log where request_id = v_key and action_code = 'MASTER_DATA_CREATE') = 1,
    'create replay produces one audit';
  assert (select count(*) from public.idempotency_records where idempotency_key = v_key and command_type = 'create_master_item') = 1,
    'create replay stores one idempotency record';

  v_result2 := public.create_master_item(
    'organizational_units',
    jsonb_build_object('code','DIFFERENT_' || v_suffix, 'name_vi','Different'),
    v_key
  );
  assert v_result2->>'error_code' = 'VALIDATION_ERROR', 'same scoped key with different fingerprint fails closed';

  -- Failed attempt does not reserve a successful replay record.
  v_key := gen_random_uuid();
  v_result := public.create_master_item(
    'qualification_levels', jsonb_build_object('code','BAD_' || v_suffix, 'unknown',true), v_key
  );
  assert v_result->>'error_code' = 'VALIDATION_ERROR', 'failed create validation rejects';
  assert not exists (select 1 from public.idempotency_records where idempotency_key = v_key),
    'failed attempt does not create idempotency record';
  v_result := public.create_master_item(
    'qualification_levels', jsonb_build_object('code','QUAL_' || v_suffix, 'name_vi','Cử nhân test'), v_key
  );
  assert (v_result->>'success')::boolean, 'same key may be reused after failed non-committed attempt';
  v_qualification := (v_result->'data'->>'master_id')::uuid;

  -- Explicit subtransaction rollback removes business/audit/idempotency effects atomically.
  v_key := gen_random_uuid();
  begin
    v_result := public.create_master_item(
      'organizational_units', jsonb_build_object('name_vi','Rolled Back Logical Attempt'), v_key
    );
    assert (v_result->>'success')::boolean, 'pre-rollback command succeeds inside subtransaction';
    raise exception 'FORCE_TEST_ROLLBACK';
  exception when others then
    null;
  end;
  assert not exists (select 1 from public.idempotency_records where idempotency_key = v_key),
    'rolled-back successful attempt leaves no reusable idempotency record';
  v_result := public.create_master_item(
    'organizational_units', jsonb_build_object('name_vi','Rolled Back Logical Attempt'), v_key
  );
  assert (v_result->>'success')::boolean, 'logical command succeeds after prior transaction rollback';

  -- ---------------------------------------------------------------------------
  -- Actor / command / type / target isolation.
  -- ---------------------------------------------------------------------------
  v_key := gen_random_uuid();
  v_result := public.create_master_item('organizational_units', jsonb_build_object('name_vi','Actor Scoped'), v_key);
  assert (v_result->>'success')::boolean;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr2_auth::text)::text, true);
  v_result2 := public.create_master_item('organizational_units', jsonb_build_object('name_vi','Actor Scoped'), v_key);
  assert (v_result2->>'success')::boolean, 'different actor does not consume another actor replay';
  assert v_result2->'data'->>'master_id' <> v_result->'data'->>'master_id', 'actor scopes produce distinct logical execution';

  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_hr_auth::text)::text, true);
  v_key := gen_random_uuid();
  v_result := public.create_master_item(
    'cancellation_reasons', jsonb_build_object('code','CAN_' || v_suffix, 'name_vi','Lý do test'), v_key
  );
  assert (v_result->>'success')::boolean;
  v_cancel_reason := (v_result->'data'->>'master_id')::uuid;
  v_result2 := public.create_master_item(
    'rejection_reasons', jsonb_build_object('code','REJ_' || v_suffix, 'name_vi','Lý do test'), v_key
  );
  assert (v_result2->>'success')::boolean, 'same key is isolated by master_type';
  v_reject_reason := (v_result2->'data'->>'master_id')::uuid;

  -- Unauthorized caller cannot obtain a prior replay result.
  v_key := gen_random_uuid();
  v_result := public.create_master_item('organizational_units', jsonb_build_object('name_vi','Authorization Replay'), v_key);
  assert (v_result->>'success')::boolean;
  delete from public.app_user_permissions where app_user_id = v_hr and permission_code = 'master_data.manage';
  v_result2 := public.create_master_item('organizational_units', jsonb_build_object('name_vi','Authorization Replay'), v_key);
  assert v_result2->>'error_code' = 'FORBIDDEN', 'authorization is revalidated before replay';
  insert into public.app_user_permissions(app_user_id, permission_code) values (v_hr, 'master_data.manage') on conflict do nothing;

  -- ---------------------------------------------------------------------------
  -- Hierarchy and parent active-selection invariants.
  -- ---------------------------------------------------------------------------
  v_result := public.create_master_item(
    'position_groups',
    jsonb_build_object('code','PG_' || v_suffix, 'name_vi','Nhóm vị trí', 'requires_demo_topic', true),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_group := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'department_teams',
    jsonb_build_object('unit_id',v_unit, 'code','TEAM_' || v_suffix, 'name_vi','Ngành test'),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_team := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'organizational_units', jsonb_build_object('code','UNIT2_' || v_suffix, 'name_vi','Khoa 2'), gen_random_uuid()
  );
  v_unit2 := (v_result->'data'->>'master_id')::uuid;

  v_result := public.create_master_item(
    'positions',
    jsonb_build_object(
      'unit_id', v_unit2, 'department_team_id', v_team, 'position_group_id', v_group,
      'code','BADPOS_' || v_suffix, 'name_vi','Sai hierarchy'
    ),
    gen_random_uuid()
  );
  assert v_result->>'error_code' = 'VALIDATION_ERROR', 'Position rejects Team belonging to another Unit';

  v_result := public.create_master_item(
    'positions',
    jsonb_build_object(
      'unit_id', v_unit, 'department_team_id', v_team, 'position_group_id', v_group,
      'code','POS_' || v_suffix, 'name_vi','Vị trí test'
    ),
    gen_random_uuid()
  );
  assert (v_result->>'success')::boolean, 'valid Unit/Team/Group Position hierarchy succeeds';
  v_position := (v_result->'data'->>'master_id')::uuid;

  -- ---------------------------------------------------------------------------
  -- UPDATE: sequential replay, stale rejection, target isolation.
  -- ---------------------------------------------------------------------------
  select version_no into v_version from public.qualification_levels where qualification_id = v_qualification;
  v_key := gen_random_uuid();
  v_result := public.update_master_item(
    'qualification_levels', v_qualification, jsonb_build_object('name_vi','Cử nhân corrected'), v_version, v_key
  );
  assert (v_result->>'success')::boolean;
  v_version2 := (v_result->'data'->>'version_no')::bigint;
  assert v_version2 = v_version + 1, 'successful update bumps version exactly once';
  v_result2 := public.update_master_item(
    'qualification_levels', v_qualification, jsonb_build_object('name_vi','Cử nhân corrected'), v_version, v_key
  );
  assert v_result2 = v_result, 'same update key/fingerprint replays stored result';
  assert (select version_no from public.qualification_levels where qualification_id = v_qualification) = v_version2,
    'update replay does not bump version twice';
  assert (select count(*) from public.security_audit_log where request_id = v_key and action_code = 'MASTER_DATA_UPDATE') = 1,
    'update replay produces one audit';

  v_key := gen_random_uuid();
  v_audit_before := (select count(*) from public.security_audit_log where request_id = v_key);
  v_result := public.update_master_item(
    'qualification_levels', v_qualification, jsonb_build_object('name_vi','Should not apply'), v_version, v_key
  );
  assert v_result->>'error_code' = 'STALE_VERSION', 'stale update rejected';
  assert (select name_vi from public.qualification_levels where qualification_id = v_qualification) = 'Cử nhân corrected',
    'stale update leaves business row unchanged';
  v_audit_after := (select count(*) from public.security_audit_log where request_id = v_key);
  assert v_audit_after = v_audit_before, 'stale update leaves audit unchanged';

  v_result := public.create_master_item('rooms', jsonb_build_object('code','R1_' || v_suffix,'display_name','Room 1'), gen_random_uuid());
  v_room := (v_result->'data'->>'master_id')::uuid;
  v_result := public.create_master_item('rooms', jsonb_build_object('code','R2_' || v_suffix,'display_name','Room 2'), gen_random_uuid());
  v_room2 := (v_result->'data'->>'master_id')::uuid;
  v_key := gen_random_uuid();
  v_result := public.update_master_item('rooms', v_room, jsonb_build_object('display_name','Room One'), 1, v_key);
  assert (v_result->>'success')::boolean;
  v_result2 := public.update_master_item('rooms', v_room2, jsonb_build_object('display_name','Room Two'), 1, v_key);
  assert (v_result2->>'success')::boolean, 'same update key is isolated by exact target identity';

  -- ---------------------------------------------------------------------------
  -- Referenced history: label correction allowed, structural mutation blocked.
  -- Unit is referenced by Team and Position.
  -- ---------------------------------------------------------------------------
  select version_no into v_version from public.organizational_units where unit_id = v_unit;
  v_key := gen_random_uuid();
  v_result := public.update_master_item(
    'organizational_units', v_unit, jsonb_build_object('name_vi','Khoa corrected'), v_version, v_key
  );
  assert (v_result->>'success')::boolean, 'referenced label correction succeeds';
  assert (v_result->'data'->>'version_no')::bigint = v_version + 1, 'referenced label correction version-bumps';
  assert (select count(*) from public.security_audit_log where request_id = v_key) = 1, 'referenced label correction audits once';

  select version_no into v_version from public.organizational_units where unit_id = v_unit;
  v_key := gen_random_uuid();
  v_result := public.update_master_item(
    'organizational_units', v_unit, jsonb_build_object('code','REPURPOSED_' || v_suffix), v_version, v_key
  );
  assert v_result->>'error_code' = 'MASTER_STRUCTURAL_HISTORY', 'referenced Unit code cannot be repurposed';
  assert not exists (select 1 from public.security_audit_log where request_id = v_key), 'structural rejection has no audit write';

  -- Position Group requires_demo_topic is advisory, so it remains mutable even when referenced.
  select version_no into v_version from public.position_groups where position_group_id = v_group;
  v_result := public.update_master_item(
    'position_groups', v_group, jsonb_build_object('requires_demo_topic', false), v_version, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean, 'requires_demo_topic remains advisory metadata, not frozen structural meaning';

  -- ---------------------------------------------------------------------------
  -- Delete/inactivate: stale hard-delete, stale referenced inactivation, hard delete,
  -- referenced inactivation, historical resolution, inactive-new-selection guard.
  -- ---------------------------------------------------------------------------
  v_result := public.create_master_item(
    'recruitment_sources', jsonb_build_object('code','SRC_' || v_suffix,'name_vi','Nguồn test'), gen_random_uuid()
  );
  v_source := (v_result->'data'->>'master_id')::uuid;
  v_result := public.update_master_item(
    'recruitment_sources', v_source, jsonb_build_object('name_vi','Nguồn test 2'), 1, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_key := gen_random_uuid();
  v_result := public.delete_or_inactivate_master_item('recruitment_sources', v_source, 1, v_key);
  assert v_result->>'error_code' = 'STALE_VERSION', 'stale unreferenced hard-delete request rejects';
  assert exists (select 1 from public.recruitment_sources where recruitment_source_id = v_source), 'stale hard-delete leaves row';
  assert not exists (select 1 from public.security_audit_log where request_id = v_key), 'stale hard-delete leaves audit unchanged';

  select version_no into v_version from public.organizational_units where unit_id = v_unit;
  -- Make a stale version deterministically.
  v_result := public.update_master_item(
    'organizational_units', v_unit, jsonb_build_object('name_en','Current Unit'), v_version, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean;
  v_key := gen_random_uuid();
  v_result := public.delete_or_inactivate_master_item('organizational_units', v_unit, v_version, v_key);
  assert v_result->>'error_code' = 'STALE_VERSION', 'stale referenced inactivation request rejects';
  assert (select is_active from public.organizational_units where unit_id = v_unit), 'stale referenced request keeps master active';
  assert not exists (select 1 from public.security_audit_log where request_id = v_key), 'stale referenced request leaves audit unchanged';

  select version_no into v_version from public.organizational_units where unit_id = v_unit;
  v_result := public.delete_or_inactivate_master_item('organizational_units', v_unit, v_version, gen_random_uuid());
  assert (v_result->>'success')::boolean and v_result->'data'->>'outcome' = 'INACTIVATED',
    'referenced master is inactivated instead of deleted';
  assert exists (select 1 from public.organizational_units where unit_id = v_unit and is_active = false),
    'referenced inactive master row is retained';
  assert exists (select 1 from public.department_teams where department_team_id = v_team and unit_id = v_unit),
    'historical child reference remains resolvable after parent inactivation';

  v_result := public.create_master_item(
    'department_teams',
    jsonb_build_object('unit_id',v_unit,'code','TEAM_INACTIVE_' || v_suffix,'name_vi','Must fail'),
    gen_random_uuid()
  );
  assert v_result->>'error_code' = 'VALIDATION_ERROR', 'inactive Unit cannot be newly selected for Team';

  -- Fresh unreferenced source hard-deletes and delete replay is stable.
  v_result := public.create_master_item(
    'recruitment_sources', jsonb_build_object('code','SRC_DEL_' || v_suffix,'name_vi','Delete me'), gen_random_uuid()
  );
  v_source := (v_result->'data'->>'master_id')::uuid;
  v_key := gen_random_uuid();
  v_result := public.delete_or_inactivate_master_item('recruitment_sources', v_source, 1, v_key);
  assert (v_result->>'success')::boolean and v_result->'data'->>'outcome' = 'DELETED', 'unreferenced master hard-deletes';
  v_result2 := public.delete_or_inactivate_master_item('recruitment_sources', v_source, 1, v_key);
  assert v_result2 = v_result, 'delete replay returns stored typed result after row no longer exists';
  assert not exists (select 1 from public.recruitment_sources where recruitment_source_id = v_source), 'hard-deleted row remains absent';
  assert (select count(*) from public.security_audit_log where request_id = v_key and action_code = 'MASTER_DATA_DELETE') = 1,
    'delete replay produces one audit';

  -- Same key may be used by a different command family without cross-command replay.
  v_key := gen_random_uuid();
  v_result := public.create_master_item('rooms', jsonb_build_object('code','CMD_' || v_suffix,'display_name','Command Scope'), v_key);
  assert (v_result->>'success')::boolean;
  v_room2 := (v_result->'data'->>'master_id')::uuid;
  v_result2 := public.update_master_item('rooms', v_room2, jsonb_build_object('display_name','Command Scope 2'), 1, v_key);
  assert (v_result2->>'success')::boolean, 'same key is isolated across command families';

  -- ---------------------------------------------------------------------------
  -- Format / Room / Document Type structural history + historical operation.
  -- Build business history with a live Interview using the masters.
  -- ---------------------------------------------------------------------------
  -- Use an active second Unit because v_unit is intentionally inactive above.
  v_result := public.create_master_item(
    'position_groups', jsonb_build_object('code','PGH_' || v_suffix,'name_vi','Nhóm history'), gen_random_uuid()
  );
  v_group := (v_result->'data'->>'master_id')::uuid;
  v_result := public.create_master_item(
    'positions',
    jsonb_build_object('unit_id',v_unit2,'position_group_id',v_group,'code','POSH_' || v_suffix,'name_vi','Position history'),
    gen_random_uuid()
  );
  v_position := (v_result->'data'->>'master_id')::uuid;
  v_result := public.create_master_item(
    'rooms', jsonb_build_object('code','ROOMH_' || v_suffix,'display_name','Room History','building','Building A'), gen_random_uuid()
  );
  v_room := (v_result->'data'->>'master_id')::uuid;
  v_result := public.create_master_item(
    'interview_formats',
    jsonb_build_object(
      'code','FMTH_' || v_suffix,'name_vi','Trực tiếp history',
      'requires_room',true,'requires_meeting_link',false
    ), gen_random_uuid()
  );
  v_format := (v_result->'data'->>'master_id')::uuid;

  insert into public.candidates(auth_user_id,email,is_active)
  values (v_candidate_auth, 's06001_candidate_' || v_suffix || '@example.com', true)
  returning candidate_id into v_candidate;
  insert into public.submissions(
    candidate_id,status_code,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot
  ) values (
    v_candidate,'PROCESSED','S06 Candidate',date '1990-01-01','MALE','Address','0900000000',
    's06001_candidate_' || v_suffix || '@example.com'
  ) returning submission_id into v_submission;
  insert into public.applications(submission_id,unit_id,position_id,hr_owner_id,is_active)
  values (v_submission,v_unit2,v_position,v_hr,true)
  returning application_id into v_application;
  insert into public.interviews(
    application_id,round_no,start_at,end_at,interview_format_id,room_id,
    schedule_status_code,report_status_code,is_active
  ) values (
    v_application,1,
    timestamptz '2026-09-20 02:00:00+00',timestamptz '2026-09-20 03:00:00+00',
    v_format,v_room,'CONFIRMED','AWAITING_INTERVIEW',true
  ) returning interview_id into v_interview;

  select version_no into v_version from public.interview_formats where interview_format_id = v_format;
  v_result := public.update_master_item(
    'interview_formats', v_format, jsonb_build_object('requires_room',false), v_version, gen_random_uuid()
  );
  assert v_result->>'error_code' = 'MASTER_STRUCTURAL_HISTORY', 'referenced Interview Format requirement semantics are immutable';

  select version_no into v_version from public.rooms where room_id = v_room;
  v_result := public.update_master_item(
    'rooms', v_room, jsonb_build_object('building','Building B'), v_version, gen_random_uuid()
  );
  assert v_result->>'error_code' = 'MASTER_STRUCTURAL_HISTORY', 'referenced Room building identity is immutable';
  v_result := public.update_master_item(
    'rooms', v_room, jsonb_build_object('display_name','Room History Corrected'), v_version, gen_random_uuid()
  );
  assert (v_result->>'success')::boolean, 'referenced Room display typo correction remains allowed';

  v_result := public.create_master_item(
    'document_types',
    jsonb_build_object('code','DOC_' || v_suffix,'name_vi','Document history','scope_code','SUBMISSION'),
    gen_random_uuid()
  );
  v_doc_type := (v_result->'data'->>'master_id')::uuid;
  insert into public.submission_document_logicals(submission_id,document_type_id,created_by_candidate_id)
  values (v_submission,v_doc_type,v_candidate)
  returning logical_document_id into v_logical;
  select version_no into v_version from public.document_types where document_type_id = v_doc_type;
  v_result := public.update_master_item(
    'document_types', v_doc_type, jsonb_build_object('scope_code','INTERVIEW'), v_version, gen_random_uuid()
  );
  assert v_result->>'error_code' = 'MASTER_STRUCTURAL_HISTORY', 'referenced Document Type scope is immutable';

  assert (select scope_code from public.document_types where code = 'CV_RESUME') = 'SUBMISSION',
    'CV seed scope remains SUBMISSION';
  assert (select scope_code from public.document_types where code = 'DEGREE') = 'SUBMISSION',
    'Degree seed scope remains SUBMISSION';
  assert (select scope_code from public.document_types where code = 'SLIDE_DEMO_MATERIAL') = 'INTERVIEW',
    'Slide seed scope remains INTERVIEW';
  assert (select scope_code from public.document_types where code = 'PUBLICATION') = 'INTERVIEW',
    'Publication seed scope remains INTERVIEW';
  assert (select scope_code from public.document_types where code = 'PORTFOLIO') = 'INTERVIEW',
    'Portfolio seed scope remains INTERVIEW';
  assert (select scope_code from public.document_types where code = 'OTHER') = 'BOTH',
    'Other seed scope remains BOTH';

  -- Inactivate the referenced format, then prove an accepted operational command still works.
  select version_no into v_version from public.interview_formats where interview_format_id = v_format;
  v_result := public.delete_or_inactivate_master_item('interview_formats', v_format, v_version, gen_random_uuid());
  assert (v_result->>'success')::boolean and v_result->'data'->>'outcome' = 'INACTIVATED',
    'referenced Interview Format is retained inactive';
  select version_no into v_version from public.interviews where interview_id = v_interview;
  v_result := public.change_interview_schedule_status(v_interview, 'CANCELLED', v_version);
  assert (v_result->>'success')::boolean, 'Interview using inactive historical format remains operationally cancellable';
  assert exists (
    select 1 from public.interviews i
    join public.interview_formats f on f.interview_format_id = i.interview_format_id
    where i.interview_id = v_interview and f.is_active = false
  ), 'historical Interview continues to resolve inactive format FK';

  -- ---------------------------------------------------------------------------
  -- Root implicit permission obeys the identical structural/history guard.
  -- ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_root_auth::text)::text, true);
  select version_no into v_version from public.interview_formats where interview_format_id = v_format;
  v_key := gen_random_uuid();
  v_result := public.update_master_item(
    'interview_formats', v_format, jsonb_build_object('requires_meeting_link',true), v_version, v_key
  );
  assert v_result->>'error_code' = 'MASTER_STRUCTURAL_HISTORY', 'Root cannot bypass structural-history integrity';
  assert not exists (select 1 from public.security_audit_log where request_id = v_key), 'Root structural rejection writes no success audit';

  -- ---------------------------------------------------------------------------
  -- All 11 masters have one canonical touch_version trigger after reconciliation.
  -- ---------------------------------------------------------------------------
  assert (
    select count(*) = 11
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and not t.tgisinternal
      and t.tgname in (
        'organizational_units_touch_version','department_teams_touch_version','positions_touch_version',
        'position_groups_touch_version','qualification_levels_touch_version','rooms_touch_version',
        'interview_formats_touch_version','recruitment_sources_touch_version','document_types_touch_version',
        'cancellation_reasons_touch_version','rejection_reasons_touch_version'
      )
  ), 'all 11 Phase-1 business masters have canonical touch_version trigger coverage';

  raise notice 'TASK-S06-001 Master Data lifecycle/history assertions passed';
end;
$$;
