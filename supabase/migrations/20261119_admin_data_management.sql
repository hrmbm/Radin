
-- Expose the persisted area field to all approval/detail clients. Older records
-- may have area in absensi.area even when the RHAREA note marker is absent.
CREATE OR REPLACE FUNCTION public.absensi_to_json(a public.absensi)
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
  SELECT json_build_object(
    'id', a.id,
    'tanggal', to_char(a.tanggal, 'YYYY-MM-DD'),
    'jam', to_char(a.jam, 'HH24:MI:SS'),
    'waktuPengajuan', to_char((a.timestamp AT TIME ZONE 'Asia/Jakarta'), 'DD/MM/YYYY HH24:MI'),
    'nik', a.employee_id,
    'nama', (SELECT k.nama FROM public.karyawan k WHERE k.employee_id = a.employee_id),
    'organization', (SELECT k.organization FROM public.karyawan k WHERE k.employee_id = a.employee_id),
    'tipe', a.tipe,
    'fotoUrl', COALESCE(a.foto_path, a.foto_url, a.storage_path),
    'latitude', a.latitude,
    'longitude', a.longitude,
    'accuracy', a.accuracy,
    'address', a.address,
    'area', a.area,
    'catatan', a.catatan,
    'branchTarget', a.branch_target,
    'atasanId', a.atasan_id,
    'statusApproval', a.status_approval,
    'alasanApproval', a.alasan_approval,
    'alasanApprovalAtasan', a.alasan_approval_atasan,
    'alasanApprovalHR', a.alasan_approval_hr,
    'managerName', (SELECT k.nama FROM public.karyawan k WHERE k.employee_id = a.approval_manager_by),
    'managerAt', a.approval_manager_at,
    'superadminName', (SELECT k.nama FROM public.karyawan k WHERE k.employee_id = a.approval_hr_by),
    'superadminAt', a.approval_hr_at,
    'approvalManagerBy', a.approval_manager_by,
    'approvalHRBy', a.approval_hr_by
  );
$function$;

-- ReHolz HRIS: administrator data management
-- Run this migration in the Supabase project before deploying the updated API Edge Function.

CREATE OR REPLACE FUNCTION public.admin_get_timeoff_records(
  p_token text,
  p_employee_id text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin public.karyawan;
  v_records json;
BEGIN
  v_admin := public.session_karyawan(p_token);
  IF UPPER(COALESCE(v_admin.role, '')) NOT IN ('ADMIN', 'SUPERADMIN') THEN
    RAISE EXCEPTION 'Only Admin and Superadmin can view Time Off records.' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(TRIM(COALESCE(p_employee_id, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Pilih karyawan terlebih dahulu.';
  END IF;

  SELECT COALESCE(json_agg(to_jsonb(q) ORDER BY q.requested_at DESC), '[]'::json)
    INTO v_records
  FROM (
    SELECT
      p.id,
      p."timestamp" AS requested_at,
      p.employee_id,
      p.nama,
      p.kode_cuti,
      p.keterangan_cuti,
      p.tanggal_mulai,
      p.tanggal_selesai,
      p.total_hari,
      p.alasan,
      p.status_atasan,
      p.status_hr,
      p.alasan_atasan,
      p.alasan_hr,
      p.timestamp_atasan,
      p.timestamp_hr,
      p.delegate_to,
      p.dinas_luar_sakit,
      p.area_sakit
    FROM public.pengajuan_cuti p
    WHERE p.employee_id = TRIM(p_employee_id)
    ORDER BY p."timestamp" DESC
    LIMIT 250
  ) q;

  RETURN json_build_object('success', TRUE, 'records', COALESCE(v_records, '[]'::json));
END;
$function$;


CREATE OR REPLACE FUNCTION public.admin_get_reimbursement_records(
  p_token text,
  p_employee_id text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin public.karyawan;
  v_records json;
BEGIN
  v_admin := public.session_karyawan(p_token);
  IF UPPER(COALESCE(v_admin.role, '')) NOT IN ('ADMIN', 'SUPERADMIN') THEN
    RAISE EXCEPTION 'Only Admin and Superadmin can view Reimbursement records.' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(TRIM(COALESCE(p_employee_id, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Pilih karyawan terlebih dahulu.';
  END IF;

  SELECT COALESCE(json_agg(to_jsonb(q) ORDER BY q.request_date DESC, q.created_at DESC), '[]'::json)
    INTO v_records
  FROM (
    SELECT
      r.id,
      r.employee_id,
      r.category,
      r.request_date,
      r.period_start,
      r.period_end,
      r.amount,
      r.note,
      r.status,
      r.manager_approval_at,
      r.manager_approval_by,
      r.manager_note,
      r.hr_approval_at,
      r.hr_approval_by,
      r.hr_note,
      r.created_at,
      r.updated_at,
      (NULLIF(TRIM(COALESCE(r.attachment_path, '')), '') IS NOT NULL) AS has_attachment
    FROM public.hr_reimbursement_requests r
    WHERE r.employee_id = TRIM(p_employee_id)
    ORDER BY r.request_date DESC, r.created_at DESC
    LIMIT 250
  ) q;

  RETURN json_build_object('success', TRUE, 'records', COALESCE(v_records, '[]'::json));
END;
$function$;


CREATE OR REPLACE FUNCTION public.admin_delete_timeoff(
  p_token text,
  p_request_id text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin public.karyawan;
  v_deleted integer := 0;
BEGIN
  v_admin := public.session_karyawan(p_token);
  IF UPPER(COALESCE(v_admin.role, '')) <> 'SUPERADMIN' THEN
    RAISE EXCEPTION 'Only Superadmin can delete Time Off records.' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(TRIM(COALESCE(p_request_id, '')), '') IS NULL THEN
    RAISE EXCEPTION 'ID pengajuan Time Off tidak valid.';
  END IF;

  PERFORM 1
  FROM public.pengajuan_cuti
  WHERE id = TRIM(p_request_id)
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pengajuan Time Off tidak ditemukan.';
  END IF;

  DELETE FROM public.pengajuan_cuti
  WHERE id = TRIM(p_request_id);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  PERFORM public.log_activity(
    p_token,
    'DELETE',
    'TIME_OFF',
    TRIM(p_request_id),
    'Superadmin menghapus pengajuan Time Off.',
    'SUCCESS'
  );

  RETURN json_build_object(
    'success', TRUE,
    'message', 'Pengajuan Time Off berhasil dihapus.',
    'deletedCount', v_deleted
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.admin_delete_reimbursement(
  p_token text,
  p_request_id text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin public.karyawan;
  v_attachment_path text;
  v_attachment_paths text[] := ARRAY[]::text[];
  v_deleted integer := 0;
BEGIN
  v_admin := public.session_karyawan(p_token);
  IF UPPER(COALESCE(v_admin.role, '')) <> 'SUPERADMIN' THEN
    RAISE EXCEPTION 'Only Superadmin can delete Reimbursement records.' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(TRIM(COALESCE(p_request_id, '')), '') IS NULL THEN
    RAISE EXCEPTION 'ID pengajuan Reimbursement tidak valid.';
  END IF;

  SELECT attachment_path
    INTO v_attachment_path
  FROM public.hr_reimbursement_requests
  WHERE id = TRIM(p_request_id)
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pengajuan Reimbursement tidak ditemukan.';
  END IF;

  SELECT COALESCE(array_agg(DISTINCT p.storage_path), ARRAY[]::text[])
    INTO v_attachment_paths
  FROM (
    SELECT NULLIF(TRIM(COALESCE(v_attachment_path, '')), '') AS storage_path
    UNION
    SELECT NULLIF(TRIM(COALESCE(u.storage_path, '')), '')
    FROM public.hr_reimbursement_attachment_uploads u
    WHERE u.request_id = TRIM(p_request_id)
       OR (NULLIF(TRIM(COALESCE(v_attachment_path, '')), '') IS NOT NULL
           AND u.storage_path = v_attachment_path)
  ) p
  WHERE p.storage_path IS NOT NULL;

  -- Remove the child upload registry rows before deleting the parent request.
  DELETE FROM public.hr_reimbursement_attachment_uploads
  WHERE request_id = TRIM(p_request_id)
     OR (NULLIF(TRIM(COALESCE(v_attachment_path, '')), '') IS NOT NULL
         AND storage_path = v_attachment_path);

  DELETE FROM public.hr_reimbursement_requests
  WHERE id = TRIM(p_request_id);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  PERFORM public.log_activity(
    p_token,
    'DELETE',
    'REIMBURSEMENT',
    TRIM(p_request_id),
    'Superadmin menghapus pengajuan Reimbursement.',
    'SUCCESS'
  );

  RETURN json_build_object(
    'success', TRUE,
    'message', 'Pengajuan Reimbursement berhasil dihapus.',
    'deletedCount', v_deleted,
    'attachment_path', NULLIF(TRIM(COALESCE(v_attachment_path, '')), ''),
    'attachment_paths', to_json(v_attachment_paths)
  );
END;
$function$;


GRANT ALL ON FUNCTION public.admin_get_timeoff_records(text, text) TO anon;
GRANT ALL ON FUNCTION public.admin_get_timeoff_records(text, text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_get_timeoff_records(text, text) TO service_role;

GRANT ALL ON FUNCTION public.admin_get_reimbursement_records(text, text) TO anon;
GRANT ALL ON FUNCTION public.admin_get_reimbursement_records(text, text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_get_reimbursement_records(text, text) TO service_role;

GRANT ALL ON FUNCTION public.admin_delete_timeoff(text, text) TO anon;
GRANT ALL ON FUNCTION public.admin_delete_timeoff(text, text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_delete_timeoff(text, text) TO service_role;

GRANT ALL ON FUNCTION public.admin_delete_reimbursement(text, text) TO anon;
GRANT ALL ON FUNCTION public.admin_delete_reimbursement(text, text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_delete_reimbursement(text, text) TO service_role;
