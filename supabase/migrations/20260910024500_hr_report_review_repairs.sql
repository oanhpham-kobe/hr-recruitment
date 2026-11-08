-- TASK-S05-002 independent-review repair: keep raw Interview meeting URLs
-- behind the Interview authorization boundary while preserving the existing HR
-- Report projection contract for allowed Report fields.

create or replace function public.get_hr_report_page(
  p_page integer default 1,
  p_page_size integer default 20,
  p_status_code text default null,
  p_visibility text default 'ALL',
  p_search text default null,
  p_sort text default 'CANDIDATE_ASC'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  v_result := hr_report_private.get_hr_report_page_impl(
    p_page,
    p_page_size,
    p_status_code,
    p_visibility,
    p_search,
    p_sort
  );

  if coalesce((v_result->>'success')::boolean, false)
     and jsonb_typeof(v_result->'data'->'rows') = 'array' then
    v_result := jsonb_set(
      v_result,
      '{data,rows}',
      coalesce(
        (
          select jsonb_agg(row_value - 'meeting_link' order by ordinal)
          from jsonb_array_elements(v_result->'data'->'rows')
            with ordinality as safe_rows(row_value, ordinal)
        ),
        '[]'::jsonb
      ),
      false
    );
  end if;

  return v_result;
end;
$$;

-- The public SECURITY DEFINER wrapper is the only authenticated entry point.
-- It delegates authorization to the existing private implementation and strips
-- the raw meeting URL before the payload can cross the Report read boundary.
revoke all on function hr_report_private.get_hr_report_page_impl(integer, integer, text, text, text, text)
  from authenticated;
revoke usage on schema hr_report_private from authenticated;

revoke all on function public.get_hr_report_page(integer, integer, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.get_hr_report_page(integer, integer, text, text, text, text)
  to authenticated, postgres, service_role;
