"""Real two-session regressions. Explicit disposable synthetic container required.
Run: python supabase/tests/internal_interview_feedback_concurrency_test.py --container NAME
Fixtures intentionally remain in the disposable database for diagnosis.
"""
import argparse
import json
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--container', required=True)
args = parser.parse_args()
container = args.container
processes = []

def uid():
    return str(uuid.uuid4())

def sql(query):
    result = subprocess.run(['docker', 'exec', '-i', container, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'], input=query.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
    if result.returncode:
        raise AssertionError(result.stderr.decode())
    return result.stdout.decode().strip()

def auth(actor):
    return f"set local role authenticated; set local request.jwt.claim.sub='{actor}';"

def rpc(actor, expression):
    output = sql(f'begin; set local statement_timeout=\'10s\'; {auth(actor)} select {expression}; commit;')
    return json.loads(next(line for line in output.splitlines() if line.startswith('{')))

def start(name, body):
    process = subprocess.Popen(['docker', 'exec', '-i', container, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process.stdin.write(f"set application_name='{name}'; begin; set local statement_timeout='12s'; {body}; commit;".encode())
    process.stdin.close()
    process.stdin = None
    processes.append(process)
    return process

def finish(process):
    output, error = process.communicate(timeout=20)
    assert process.returncode == 0, error.decode()
    return [json.loads(line) for line in output.decode().splitlines() if line.startswith('{')]

def waiting(name, event):
    until = time.monotonic() + 6
    while time.monotonic() < until:
        if sql(f"select exists(select 1 from pg_stat_activity where application_name='{name}' and {event});") == 't':
            return
        time.sleep(.03)
    raise AssertionError(f'Missing synchronization for {name}: {event}')

suffix = uid()
root = sql('select app_user_id::text||\'|\'||auth_user_id::text from public.app_users where is_root_admin;')
if root:
    root_id, root_auth = root.split('|')
else:
    root_id, root_auth = uid(), uid()
    sql(f"insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active,is_root_admin) values('{root_id}','{root_auth}','{root_id}@eiu.edu.vn','Feedback race Root',true,true);")
manager, manager_auth, evaluator, evaluator_auth = [uid() for _ in range(4)]
unit, group, candidate, submission = [uid() for _ in range(4)]
sql(f"""
insert into public.app_users(app_user_id,auth_user_id,email,full_name,is_active,is_root_admin) values
('{manager}','{manager_auth}','{manager}@eiu.edu.vn','Feedback race manager',true,false),
('{evaluator}','{evaluator_auth}','{evaluator}@eiu.edu.vn','Feedback race evaluator',true,false);
insert into public.organizational_units(unit_id,name_vi,code) values('{unit}','Race unit','{unit}');
insert into public.position_groups(position_group_id,name_vi,code) values('{group}','Race group','{group}');
insert into public.candidates(candidate_id,auth_user_id,email,current_full_name) values('{candidate}','{uid()}','{candidate}@example.invalid','Race candidate');
insert into public.submissions(submission_id,candidate_id,status_code,full_name,date_of_birth,gender_code,current_address,phone,email_snapshot)
values('{submission}','{candidate}','READ','Race candidate','1990-01-01','MALE','Address','0900000000','{candidate}@example.invalid');
""")
version = sql(f"select version_no from public.app_users where app_user_id='{manager}';")
assert rpc(root_auth, f"public.assign_hr_role_with_defaults('{manager}',{version},'{uid()}')")['success']
template = '10100000-0000-4000-8000-000000000001'

def context():
    position, application, interview, participant = [uid() for _ in range(4)]
    sql(f"""
insert into public.positions(position_id,unit_id,position_group_id,name_vi,code) values('{position}','{unit}','{group}','Race position','{position}');
insert into public.applications(application_id,submission_id,unit_id,position_id,hr_owner_id) values('{application}','{submission}','{unit}','{position}','{root_id}');
insert into public.interviews(interview_id,application_id,round_no,schedule_status_code,report_status_code,is_active,visible_to_interviewers)
values('{interview}','{application}',1,'AVAILABLE','WAITING_FOR_REPORT',true,true);
insert into public.interview_participants(interview_participant_id,interview_id,app_user_id,participant_order,snapshot_name,snapshot_email)
values('{participant}','{interview}','{evaluator}',1,'Race evaluator','{evaluator}@eiu.edu.vn');
""")
    return application, interview, participant

def collection(interview, participant, actor=root_auth):
    result = rpc(actor, f"public.create_interview_feedback_collection('{interview}','{template}',array['{participant}'::uuid],null,'{uid()}')")
    assert result['success'], result
    cid = result['data']['collection_id']
    iid = rpc(actor, f"public.get_interview_feedback_collection('{cid}')")['data']['invitations'][0]['invitation_id']
    return cid, iid

try:
    application, interview, participant = context()
    key = uid()
    call = f"public.create_interview_feedback_collection('{interview}','{template}',array['{participant}'::uuid],null,'{key}')"
    name = 'feedback-create-' + suffix
    first = start(name, auth(root_auth) + f' select {call}; select pg_sleep(2)')
    waiting(name, "wait_event='PgSleep'")
    second = start(name + '-retry', auth(root_auth) + f' select {call}')
    waiting(name + '-retry', "wait_event_type='Lock'")
    r1, r2 = finish(first)[0], finish(second)[0]
    assert r1 == r2 and r1['success'], (r1, r2)
    cid = r1['data']['collection_id']
    assert sql(f"select count(*) from private.interview_feedback_notification_intents n join private.interview_feedback_invitations fi using(invitation_id) where fi.collection_id='{cid}';") == '1'
    invitation = rpc(root_auth, f"public.get_interview_feedback_collection('{cid}')")['data']['invitations'][0]['invitation_id']
    print('Concurrent create retry: PASS', flush=True)

    name = 'feedback-draft-' + suffix
    first = start(name, auth(evaluator_auth) + f" select public.save_interview_feedback_response('{invitation}','{{}}',1,false); select pg_sleep(2)")
    waiting(name, "wait_event='PgSleep'")
    second = start(name+'-stale', auth(evaluator_auth) + f" select public.save_interview_feedback_response('{invitation}','{{}}',1,false)")
    waiting(name+'-stale', "wait_event_type='Lock'")
    assert finish(first)[0]['success']
    assert finish(second)[0]['error_code'] == 'STALE_VERSION'
    print('Concurrent same-user draft version: PASS', flush=True)

    name = 'feedback-revoke-' + suffix
    first = start(name, auth(root_auth) + f" select public.revoke_interview_feedback_invitation('{invitation}',2); select pg_sleep(2)")
    waiting(name, "wait_event='PgSleep'")
    second = start(name+'-submit', auth(evaluator_auth) + f" select public.save_interview_feedback_response('{invitation}','{{}}',2,true)")
    waiting(name+'-submit', "wait_event_type='Lock'")
    assert finish(first)[0]['success']
    assert finish(second)[0]['error_code'] == 'INVITATION_REVOKED'
    print('Revoke versus submit: PASS', flush=True)

    application, interview, participant = context()
    cid, invitation = collection(interview, participant)
    assert rpc(evaluator_auth,f"public.save_interview_feedback_response('{invitation}','{{}}',1,true)")['success']
    assert rpc(root_auth,f"public.save_interview_feedback_consolidation('{cid}','Draft','',0,false)")['success']
    version = sql(f"select version_no from public.interview_participants where interview_participant_id='{participant}';")
    name = 'feedback-remove-' + suffix
    first = start(name, auth(root_auth) + f" select public.remove_interview_participant('{participant}',{version}); select pg_sleep(2)")
    waiting(name, "wait_event='PgSleep'")
    second = start(name+'-approve', auth(root_auth) + f" select public.save_interview_feedback_consolidation('{cid}','Approved','',1,true)")
    waiting(name+'-approve', "wait_event_type='Lock'")
    assert finish(first)[0]['success']
    assert finish(second)[0]['error_code'] == 'COMPLETENESS_REQUIRED'
    print('Participant removal versus approval: PASS', flush=True)

    application, interview, participant = context()
    name = 'feedback-authority-' + suffix
    first = start(name, f"select 1 from public.interviews where interview_id='{interview}' for update; select pg_sleep(3)")
    waiting(name,"wait_event='PgSleep'")
    second = start(name+'-create', auth(manager_auth)+f" select public.create_interview_feedback_collection('{interview}','{template}',array['{participant}'::uuid],null,'{uid()}')")
    waiting(name+'-create',"wait_event_type='Lock'")
    version = sql(f"select version_no from public.app_users where app_user_id='{manager}';")
    assert rpc(root_auth,f"public.revoke_hr_permission('{manager}','interviews.manage',{version},'{uid()}')")['success']
    finish(first)
    assert finish(second)[0]['error_code'] == 'FORBIDDEN'
    print('Post-wait permission revocation: PASS', flush=True)

    round_app, round_interview, round_participant = context()
    round_collection, round_invitation = collection(round_interview, round_participant)
    name = 'feedback-next-round-' + suffix
    first = start(name, auth(root_auth) + f" select public.create_next_interview_round('{round_app}','{uid()}'); select pg_sleep(2)")
    waiting(name,"wait_event='PgSleep'")
    second = start(name+'-submit', auth(evaluator_auth) + f" select public.save_interview_feedback_response('{round_invitation}','{{}}',1,true)")
    waiting(name+'-submit',"wait_event_type='Lock'")
    assert finish(first)[0]['success']
    assert finish(second)[0]['error_code'] == 'CONTEXT_NOT_WRITABLE'
    print('New current round versus submit: PASS', flush=True)

    # Force email's established A->I->S shared context composition against
    # feedback's S->A->I order. Parent SHARE modes must remain compatible.
    name = 'feedback-email-' + suffix
    first = start(name, f"select 1 from public.applications where application_id='{application}' for share; select 1 from public.interviews where interview_id='{interview}' for no key update; select pg_sleep(2); select private.lock_email_contexts(array['{interview}'::uuid],'{root_id}'::uuid)")
    waiting(name,"wait_event='PgSleep'")
    second = start(name+'-create',auth(root_auth)+f" select public.create_interview_feedback_collection('{interview}','{template}',array['{participant}'::uuid],null,'{uid()}')")
    waiting(name+'-create',"wait_event_type='Lock'")
    finish(first)
    assert finish(second)[0]['success']
    print('Existing email context lock composition: PASS', flush=True)
finally:
    for process in processes:
        if process.poll() is None:
            process.communicate(timeout=20)
