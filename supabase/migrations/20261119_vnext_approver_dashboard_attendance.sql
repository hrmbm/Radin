-- Radin HRIS v14.9.0: Approver access, attendance report punctuality, clock-out approval consistency,
-- dashboard panels, Superadmin attendance adjustments, and reliable refresh behavior.
-- Apply after 20261119_admin_data_management.sql.

-- Helper: an ordinary employee becomes an Approver only while they have active direct reports.
CREATE OR REPLACE FUNCTION public.rh_is_active_approver(p_employee_id text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'pg_catalog','public' AS $function$
  SELECT EXISTS (SELECT 1 FROM public.karyawan k WHERE k.approval_line_id=p_employee_id AND k.status_akun='AKTIF');
$function$;
REVOKE ALL ON FUNCTION public.rh_is_active_approver(text) FROM PUBLIC, anon, authenticated;

-- The report status is derived independently of the meal allowance tolerance snapshot.
-- hris_incentive_calculate continues using the existing five-minute meal rule.

ALTER TABLE public.absensi ADD COLUMN IF NOT EXISTS approval_required boolean NOT NULL DEFAULT false;
UPDATE public.absensi SET approval_required=TRUE WHERE COALESCE(outside_location,FALSE) IS TRUE OR status_approval IN ('PENDING_ATASAN','PENDING_HR') OR approval_manager_at IS NOT NULL OR approval_hr_at IS NOT NULL;
ALTER TABLE public.absensi ADD COLUMN IF NOT EXISTS manual_adjustment boolean NOT NULL DEFAULT false;
ALTER TABLE public.absensi ADD COLUMN IF NOT EXISTS adjustment_reason text;
ALTER TABLE public.absensi ADD COLUMN IF NOT EXISTS adjusted_by text;
ALTER TABLE public.absensi ADD COLUMN IF NOT EXISTS adjusted_at timestamptz;

CREATE TABLE IF NOT EXISTS public.attendance_adjustment_audit (
  id bigserial PRIMARY KEY,
  attendance_id text NOT NULL,
  employee_id text NOT NULL,
  action text NOT NULL CHECK (action IN ('INSERT','UPDATE')),
  reason text NOT NULL,
  actor_employee_id text NOT NULL,
  before_data jsonb,
  after_data jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_attendance_adjustment_audit_employee_date
  ON public.attendance_adjustment_audit(employee_id, created_at DESC);
ALTER TABLE public.attendance_adjustment_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.attendance_adjustment_audit FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.hr_get_dashboard_panels(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog','public' AS $function$
DECLARE
  v_emp public.karyawan;
  v_today date := (now() AT TIME ZONE 'Asia/Jakarta')::date;
  v_start date; v_end date; v_calc jsonb; v_row jsonb; v_employee_id text;
  v_area1 numeric:=0; v_area2 numeric:=0; v_area3 numeric:=0; v_area4 numeric:=0; v_arealain numeric:=0;
  v_transport numeric:=0; v_entertain numeric:=0;
  v_absent jsonb;
  v_admin boolean;
BEGIN
  v_emp := public.session_karyawan(p_token);
  v_admin := UPPER(COALESCE(v_emp.role,'')) IN ('HR','ADMIN','SUPERADMIN');
  IF NOT v_admin AND NOT public.rh_is_active_approver(v_emp.employee_id) THEN
    RAISE EXCEPTION 'Access denied.' USING ERRCODE='42501';
  END IF;
  SELECT b.period_start,b.period_end INTO v_start,v_end FROM public.hr_reimbursement_period_bounds(v_today) b;

  IF v_admin THEN
    v_calc := public.hris_incentive_calculate(v_start,v_end,NULL);
    FOR v_row IN SELECT value FROM jsonb_array_elements(COALESCE(v_calc->'records','[]'::jsonb)) LOOP
      v_area1 := v_area1 + COALESCE(NULLIF(v_row->>'area_1_amount','')::numeric,0);
      v_area2 := v_area2 + COALESCE(NULLIF(v_row->>'area_2_amount','')::numeric,0);
      v_area3 := v_area3 + COALESCE(NULLIF(v_row->>'area_3_amount','')::numeric,0);
      v_area4 := v_area4 + COALESCE(NULLIF(v_row->>'area_4_amount','')::numeric,0);
      v_arealain := v_arealain + COALESCE(NULLIF(v_row->>'area_lain_amount','')::numeric,0);
    END LOOP;
  ELSE
    FOR v_employee_id IN SELECT k.employee_id FROM public.karyawan k WHERE k.status_akun='AKTIF' AND k.approval_line_id=v_emp.employee_id LOOP
      v_calc := public.hris_incentive_calculate(v_start,v_end,v_employee_id);
      FOR v_row IN SELECT value FROM jsonb_array_elements(COALESCE(v_calc->'records','[]'::jsonb)) LOOP
        v_area1 := v_area1 + COALESCE(NULLIF(v_row->>'area_1_amount','')::numeric,0);
        v_area2 := v_area2 + COALESCE(NULLIF(v_row->>'area_2_amount','')::numeric,0);
        v_area3 := v_area3 + COALESCE(NULLIF(v_row->>'area_3_amount','')::numeric,0);
        v_area4 := v_area4 + COALESCE(NULLIF(v_row->>'area_4_amount','')::numeric,0);
        v_arealain := v_arealain + COALESCE(NULLIF(v_row->>'area_lain_amount','')::numeric,0);
      END LOOP;
    END LOOP;
  END IF;

  SELECT COALESCE(SUM(r.amount) FILTER (WHERE r.category='TRANSPORT'),0),
         COALESCE(SUM(r.amount) FILTER (WHERE r.category='ENTERTAIN'),0)
    INTO v_transport,v_entertain
  FROM public.hr_reimbursement_requests r
  JOIN public.karyawan k ON k.employee_id=r.employee_id
  WHERE r.status='DISETUJUI' AND r.period_start=v_start AND r.period_end=v_end
    AND UPPER(COALESCE(k.job_code,''))='HYBRID'
    AND (v_admin OR k.approval_line_id=v_emp.employee_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object('employee_id',q.employee_id,'nama',q.nama,'time_off_code',q.time_off_code)
      ORDER BY q.nama),'[]'::jsonb)
  INTO v_absent
  FROM (
    SELECT k.employee_id,k.nama,
      (SELECT c.kode_cuti FROM public.pengajuan_cuti c
       WHERE c.employee_id=k.employee_id AND c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI'
         AND c.tanggal_mulai<=v_today AND c.tanggal_selesai>=v_today
       ORDER BY c.tanggal_mulai DESC,c."timestamp" DESC LIMIT 1) AS time_off_code
    FROM public.karyawan k
    WHERE k.status_akun='AKTIF' AND (k.join_date IS NULL OR k.join_date<=v_today)
      AND (v_admin OR k.approval_line_id=v_emp.employee_id)
      AND NOT EXISTS (SELECT 1 FROM public.absensi a WHERE a.employee_id=k.employee_id AND a.tanggal=v_today
        AND a.tipe='MASUK' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR'))
  ) q;

  RETURN jsonb_build_object('ok',true,'period',jsonb_build_object('start_date',v_start,'end_date',v_end),
    'hybrid_expense',jsonb_build_object('transport',v_transport,'entertain',v_entertain),
    'outside_incentive',jsonb_build_object('area_1',v_area1,'area_2',v_area2,'area_3',v_area3,'area_4',v_area4,'area_lain',v_arealain),
    'absent_today',v_absent);
END;
$function$;

CREATE OR REPLACE FUNCTION public.hr_list_attendance_adjustments(
  p_token text,p_employee_id text,p_start_date date DEFAULT NULL,p_end_date date DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog','public' AS $function$
DECLARE v_emp public.karyawan; v_rows jsonb;
BEGIN
  v_emp:=public.session_karyawan(p_token);
  IF UPPER(COALESCE(v_emp.role,''))<>'SUPERADMIN' THEN RAISE EXCEPTION 'Only Superadmin can view attendance adjustments.' USING ERRCODE='42501'; END IF;
  IF NULLIF(BTRIM(COALESCE(p_employee_id,'')),'') IS NULL THEN RAISE EXCEPTION 'Pilih karyawan terlebih dahulu.'; END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.tanggal DESC,q.jam DESC),'[]'::jsonb) INTO v_rows
  FROM (
    SELECT a.id,a.employee_id,a.tanggal,a.jam,a.tipe,a.status_approval,a.manual_adjustment,a.adjustment_reason,a.adjusted_by,a.adjusted_at
    FROM public.absensi a WHERE a.employee_id=TRIM(p_employee_id) AND a.manual_adjustment IS TRUE
      AND (p_start_date IS NULL OR a.tanggal>=p_start_date) AND (p_end_date IS NULL OR a.tanggal<=p_end_date)
    ORDER BY a.tanggal DESC,a.jam DESC LIMIT 250
  ) q;
  RETURN jsonb_build_object('ok',true,'records',v_rows);
END;
$function$;

CREATE OR REPLACE FUNCTION public.hr_save_attendance_adjustment(
  p_token text,p_action text,p_attendance_id text,p_employee_id text,p_date date,p_type text,p_time time,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog','public' AS $function$
DECLARE
  v_emp public.karyawan; v_action text:=UPPER(BTRIM(COALESCE(p_action,''))); v_type text:=UPPER(BTRIM(COALESCE(p_type,'')));
  v_before jsonb; v_after public.absensi; v_id text; v_branch text; v_reason text:=NULLIF(BTRIM(COALESCE(p_reason,'')),'');
BEGIN
  v_emp:=public.session_karyawan(p_token);
  IF UPPER(COALESCE(v_emp.role,''))<>'SUPERADMIN' THEN RAISE EXCEPTION 'Only Superadmin can adjust attendance.' USING ERRCODE='42501'; END IF;
  IF v_action NOT IN ('INSERT','UPDATE') THEN RAISE EXCEPTION 'Aksi penyesuaian tidak valid.' USING ERRCODE='22023'; END IF;
  IF v_type NOT IN ('MASUK','PULANG') OR p_date IS NULL OR p_time IS NULL OR NULLIF(BTRIM(COALESCE(p_employee_id,'')),'') IS NULL THEN
    RAISE EXCEPTION 'Karyawan, tanggal, jenis, dan jam wajib diisi.' USING ERRCODE='22023';
  END IF;
  IF v_reason IS NULL OR length(v_reason)<8 THEN RAISE EXCEPTION 'Alasan penyesuaian wajib diisi minimal 8 karakter.' USING ERRCODE='22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.karyawan k WHERE k.employee_id=TRIM(p_employee_id)) THEN RAISE EXCEPTION 'Karyawan tidak ditemukan.' USING ERRCODE='P0002'; END IF;
  SELECT COALESCE(NULLIF(BTRIM(k.branch),''),'Pusat') INTO v_branch FROM public.karyawan k WHERE k.employee_id=TRIM(p_employee_id);

  IF v_action='INSERT' THEN
    IF p_date >= (now() AT TIME ZONE 'Asia/Jakarta')::date THEN RAISE EXCEPTION 'Penambahan manual hanya untuk tanggal yang sudah berlalu.' USING ERRCODE='22023'; END IF;
    IF EXISTS (SELECT 1 FROM public.absensi a WHERE a.employee_id=TRIM(p_employee_id) AND a.tanggal=p_date AND a.tipe=v_type
      AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')) THEN
      RAISE EXCEPTION 'Catatan jenis ini sudah ada pada tanggal tersebut. Gunakan Ubah Jam pada catatan yang ada.' USING ERRCODE='23505';
    END IF;
    v_id:='ADJ-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS')||'-'||substr(upper(replace(gen_random_uuid()::text,'-','')),1,6);
    INSERT INTO public.absensi(id,employee_id,tanggal,jam,timestamp,tipe,address,catatan,branch_target,status_approval,
      atasan_id,face_match,face_local_precheck,manual_adjustment,adjustment_reason,adjusted_by,adjusted_at)
    VALUES(v_id,TRIM(p_employee_id),p_date,p_time,now(),v_type,'Penyesuaian manual oleh SUPERADMIN',
      '[PENYESUAIAN DATA] '||v_reason,v_branch,'DISETUJUI',NULL,FALSE,FALSE,TRUE,v_reason,v_emp.employee_id,now())
    RETURNING * INTO v_after;
    INSERT INTO public.attendance_adjustment_audit(attendance_id,employee_id,action,reason,actor_employee_id,before_data,after_data)
    VALUES(v_id,TRIM(p_employee_id),'INSERT',v_reason,v_emp.employee_id,NULL,to_jsonb(v_after));
  ELSE
    IF NULLIF(BTRIM(COALESCE(p_attendance_id,'')),'') IS NULL THEN RAISE EXCEPTION 'ID presensi wajib untuk mengubah jam.' USING ERRCODE='22023'; END IF;
    SELECT to_jsonb(a) INTO v_before FROM public.absensi a
    WHERE a.id=TRIM(p_attendance_id) AND a.employee_id=TRIM(p_employee_id) AND a.tanggal=p_date AND a.tipe=v_type FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Catatan presensi tidak ditemukan.' USING ERRCODE='P0002'; END IF;
    UPDATE public.absensi SET jam=p_time,
      punctuality_status=CASE WHEN tipe='MASUK' AND scheduled_check_in_snapshot IS NOT NULL THEN
        CASE WHEN p_time < scheduled_check_in_snapshot THEN 'EARLY'
             WHEN EXTRACT(EPOCH FROM (p_time-scheduled_check_in_snapshot))/60 <= COALESCE(late_tolerance_minutes_snapshot,5) THEN 'ON_TIME'
             ELSE 'LATE' END
        ELSE punctuality_status END,
      manual_adjustment=TRUE,adjustment_reason=v_reason,adjusted_by=v_emp.employee_id,adjusted_at=now()
    WHERE id=TRIM(p_attendance_id) RETURNING * INTO v_after;
    INSERT INTO public.attendance_adjustment_audit(attendance_id,employee_id,action,reason,actor_employee_id,before_data,after_data)
    VALUES(TRIM(p_attendance_id),TRIM(p_employee_id),'UPDATE',v_reason,v_emp.employee_id,v_before,to_jsonb(v_after));
  END IF;
  PERFORM public.log_activity(p_token,'ATTENDANCE_ADJUSTMENT','ABSENSI',v_after.id,
    'Penyesuaian data absensi: '||v_reason,'SUCCESS');
  RETURN jsonb_build_object('ok',true,'success',true,'attendance_id',v_after.id,'action',v_action,'message',
    CASE WHEN v_action='INSERT' THEN 'Absensi historis berhasil ditambahkan.' ELSE 'Jam absensi berhasil disesuaikan.' END);
END;
$function$;


CREATE OR REPLACE FUNCTION public.hr_get_attendance_summary(p_token text, p_start_date date, p_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_emp public.karyawan;
  v_rows jsonb;
  v_is_approver boolean := false;
BEGIN
  v_emp := public.session_karyawan(p_token);
  v_is_approver := EXISTS (SELECT 1 FROM public.karyawan b WHERE b.approval_line_id=v_emp.employee_id AND b.status_akun='AKTIF');
  IF UPPER(COALESCE(v_emp.role, '')) NOT IN ('HR','ADMIN','SUPERADMIN') AND NOT v_is_approver THEN
    RAISE EXCEPTION 'Access denied.' USING ERRCODE='42501';
  END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_start_date > p_end_date OR p_end_date - p_start_date > 400 THEN
    RAISE EXCEPTION 'Invalid summary range (maximum 401 days).';
  END IF;

  WITH dates AS (
    SELECT d::date AS dt
    FROM generate_series(p_start_date, p_end_date, interval '1 day') d
  ), emp_days AS (
    SELECT
      k.employee_id::text AS employee_id,
      k.nama,
      k.organization,
      k.job_position,
      k.job_code,
      k.status_akun,
      k.join_date,
      k.contract_end_date,
      d.dt,
      COALESCE(h.branch, NULLIF(BTRIM(k.branch),''), 'Pusat') AS profile_branch
    FROM public.karyawan k
    CROSS JOIN dates d
    LEFT JOIN LATERAL (
      SELECT bh.branch
      FROM public.attendance_employee_branch_history bh
      WHERE bh.employee_id = k.employee_id::text
        AND bh.effective_from <= d.dt
        AND (bh.effective_to IS NULL OR bh.effective_to >= d.dt)
      ORDER BY bh.effective_from DESC
      LIMIT 1
    ) h ON TRUE
    WHERE (k.join_date IS NULL OR k.join_date <= d.dt)
      AND (UPPER(COALESCE(k.status_akun,'')) = 'AKTIF' OR d.dt <= (k.updated_at AT TIME ZONE 'Asia/Jakarta')::date)
      AND (UPPER(COALESCE(v_emp.role,'')) IN ('HR','ADMIN','SUPERADMIN') OR k.approval_line_id = v_emp.employee_id)
  ), actual AS (
    SELECT
      a.employee_id::text AS employee_id,
      a.tanggal AS dt,
      MIN(a.jam) FILTER (WHERE a.tipe='MASUK') AS check_in,
      MAX(a.jam) FILTER (WHERE a.tipe='PULANG') AS check_out,
      MAX(a.employee_branch_snapshot) FILTER (WHERE a.tipe='MASUK') AS event_branch,
      MAX(a.shift_name_snapshot) FILTER (WHERE a.tipe='MASUK') AS event_shift_name,
      MAX(a.shift_code_snapshot) FILTER (WHERE a.tipe='MASUK') AS event_shift_code,
      MAX(a.shift_label_snapshot) FILTER (WHERE a.tipe='MASUK') AS event_shift_label,
      MAX(a.scheduled_check_in_snapshot) FILTER (WHERE a.tipe='MASUK') AS event_scheduled_in,
      MAX(a.scheduled_check_out_snapshot) FILTER (WHERE a.tipe='MASUK') AS event_scheduled_out,
      MAX(a.calendar_day_type_snapshot) FILTER (WHERE a.tipe='MASUK') AS event_day_type,
      MAX(substring(COALESCE(a.catatan,'') from '\[\[RHATT=([A-Za-z0-9]+)\]\]'))
        FILTER (WHERE a.tipe='MASUK') AS event_attendance_marker,
      MAX(a.area) FILTER (WHERE a.tipe='MASUK') AS first_in_area,
      COALESCE(BOOL_OR(COALESCE(a.outside_location,FALSE)) FILTER (WHERE a.tipe='MASUK'),FALSE) AS first_in_outside,
      COALESCE(
        MAX(a.area) FILTER (WHERE a.tipe='MASUK' AND COALESCE(a.outside_location,FALSE) IS TRUE),
        MAX(a.area) FILTER (WHERE a.tipe='PULANG' AND COALESCE(a.outside_location,FALSE) IS TRUE)
      ) AS event_area,
      BOOL_OR(COALESCE(a.outside_location,FALSE)) AS outside_any
    FROM public.absensi a
    WHERE a.tanggal BETWEEN p_start_date AND p_end_date
      AND COALESCE(a.status_approval,'VALID') NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')
    GROUP BY a.employee_id, a.tanggal
  ), base AS (
    SELECT
      e.*,
      a.check_in,
      a.check_out,
      a.event_attendance_marker,
      a.event_area,
      a.first_in_area,
      COALESCE(a.first_in_outside,FALSE) AS first_in_outside,
      COALESCE(a.outside_any,FALSE) AS outside_any,
      COALESCE(a.event_branch,e.profile_branch) AS branch,
      COALESCE(a.event_shift_name,r.shift_name) AS shift_name,
      COALESCE(a.event_shift_code,r.shift_code) AS shift_code,
      COALESCE(a.event_shift_label,r.shift_label) AS shift_label,
      COALESCE(a.event_scheduled_in,r.scheduled_check_in) AS scheduled_in,
      COALESCE(a.event_scheduled_out,r.scheduled_check_out) AS scheduled_out,
      COALESCE(a.event_day_type,public.attendance_resolved_day_type(e.dt,COALESCE(a.event_branch,e.profile_branch))) AS day_type,
      COALESCE(r.is_workday,FALSE) AS rule_is_workday,
      lv.kode_cuti AS time_off_code,
      lv.total_hari AS time_off_days,
      COALESCE(lv.dinas_luar_sakit,false) AS sick_outside_leave,
      lv.area_sakit AS sick_outside_area
    FROM emp_days e
    LEFT JOIN actual a ON a.employee_id=e.employee_id AND a.dt=e.dt
    LEFT JOIN LATERAL (
      SELECT sr.*
      FROM public.attendance_schedule_rules sr
      WHERE LOWER(BTRIM(sr.branch)) = LOWER(BTRIM(COALESCE(a.event_branch,e.profile_branch)))
        AND sr.effective_from <= e.dt
        AND (sr.effective_to IS NULL OR sr.effective_to >= e.dt)
        AND (
          public.attendance_resolved_day_type(e.dt,COALESCE(a.event_branch,e.profile_branch)) NOT IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF')
          OR (
            EXTRACT(ISODOW FROM e.dt)::integer = 7
            AND public.attendance_resolved_day_type(e.dt,COALESCE(a.event_branch,e.profile_branch)) = 'WORKING_DAY'
          )
        )
        AND (
          sr.day_of_week = EXTRACT(ISODOW FROM e.dt)::integer
          OR (
            EXTRACT(ISODOW FROM e.dt)::integer = 7
            AND public.attendance_resolved_day_type(e.dt,COALESCE(a.event_branch,e.profile_branch)) = 'WORKING_DAY'
            AND sr.day_of_week BETWEEN 1 AND 6
            AND sr.is_workday = TRUE
          )
        )
        AND NOT (
          EXTRACT(ISODOW FROM e.dt)::integer = 7
          AND public.attendance_resolved_day_type(e.dt,COALESCE(a.event_branch,e.profile_branch)) = 'WORKING_DAY'
          AND sr.day_of_week = 7
          AND sr.is_workday = FALSE
        )
      ORDER BY
        CASE WHEN sr.day_of_week = EXTRACT(ISODOW FROM e.dt)::integer THEN 0 ELSE 1 END,
        sr.effective_from DESC,
        sr.day_of_week
      LIMIT 1
    ) r ON TRUE
    LEFT JOIN LATERAL (
      SELECT c.kode_cuti, c.total_hari, c.dinas_luar_sakit, c.area_sakit
      FROM public.pengajuan_cuti c
      WHERE c.employee_id=e.employee_id
        AND c.status_atasan='DISETUJUI'
        AND c.status_hr='DISETUJUI'
        AND c.tanggal_mulai<=e.dt
        AND c.tanggal_selesai>=e.dt
      ORDER BY c.tanggal_mulai DESC, c."timestamp" DESC
      LIMIT 1
    ) lv ON TRUE
  ), final_rows AS (
    SELECT
      employee_id,
      UPPER(COALESCE(NULLIF(BTRIM(nama),''),employee_id)) AS full_name,
      branch,
      organization,
      job_position,
      job_code,
      dt AS date,
      COALESCE(shift_name, CASE WHEN day_type IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF') THEN 'Day Off' ELSE '—' END) AS shift,
      shift_code,
      shift_label,
      to_char(scheduled_in,'HH24:MI') AS schedule_check_in,
      to_char(scheduled_out,'HH24:MI') AS schedule_check_out,
      CASE
        WHEN time_off_code='SDR' AND sick_outside_leave AND sick_outside_area='Area 1' THEN 'SDR-DL1'
        WHEN time_off_code='SDR' AND sick_outside_leave AND sick_outside_area='Area 2' THEN 'SDR-DL2'
        WHEN time_off_code='SDR' AND sick_outside_leave AND sick_outside_area='Area 3' THEN 'SDR-DL3'
        WHEN time_off_code='SDR' AND sick_outside_leave AND sick_outside_area='Area 4' THEN 'SDR-DL4'
        WHEN time_off_code='SDR' AND sick_outside_leave AND sick_outside_area='Area lainnya' THEN 'SDR-DLL'
        WHEN event_attendance_marker IN ('P','P1','P2','P3','P4','PL') THEN event_attendance_marker
        WHEN event_attendance_marker = 'P5' THEN 'PL'
        WHEN event_attendance_marker IN ('SDL1','SDL2','SDL3','SDL4','SDLL') THEN event_attendance_marker
        WHEN event_attendance_marker = 'SDL5' THEN 'SDLL'
        WHEN event_attendance_marker IN ('DL1','DL2','DL3','DL4','DLL') THEN event_attendance_marker
        WHEN event_attendance_marker = 'DL5' THEN 'DLL'
        WHEN event_area = 'Surabaya & Sekitarnya' AND check_in IS NOT NULL THEN 'H'
        WHEN COALESCE(event_attendance_marker,'') !~ '^P' AND first_in_outside AND first_in_area = 'Area 1' THEN 'DL1'
        WHEN COALESCE(event_attendance_marker,'') !~ '^P' AND first_in_outside AND first_in_area = 'Area 2' THEN 'DL2'
        WHEN COALESCE(event_attendance_marker,'') !~ '^P' AND first_in_outside AND first_in_area = 'Area 3' THEN 'DL3'
        WHEN COALESCE(event_attendance_marker,'') !~ '^P' AND first_in_outside AND first_in_area = 'Area 4' THEN 'DL4'
        WHEN COALESCE(event_attendance_marker,'') !~ '^P' AND first_in_outside AND first_in_area = 'Area lainnya' THEN 'DLL'
        WHEN check_in IS NOT NULL AND day_type IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF') THEN 'P'
        WHEN check_in IS NOT NULL THEN 'H'
        WHEN time_off_code IS NOT NULL THEN time_off_code
        ELSE NULL
      END AS attendance_code,
      time_off_code,
      NULL::text AS hourly_time_off_breakdown,
      to_char(check_in,'HH24:MI') AS check_in,
      to_char(check_out,'HH24:MI') AS check_out,
      (check_in IS NOT NULL) AS has_clock_in,
      (UPPER(COALESCE(status_akun,''))='AKTIF') AS employee_is_active,
      (rule_is_workday AND day_type NOT IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF')) AS expected_workday,
      day_type AS calendar_day_type,
      CASE WHEN time_off_code='SDR' AND sick_outside_leave THEN sick_outside_area ELSE event_area END AS area,
      (outside_any OR (time_off_code='SDR' AND sick_outside_leave)) AS outside_location,
      CASE
        WHEN check_in IS NULL THEN '-'
        WHEN UPPER(COALESCE(job_code,'')) IN ('WFA','HYBRID')
          OR COALESCE(event_attendance_marker,'') ~ '^(DL|SDL)'
          OR (COALESCE(event_attendance_marker,'') !~ '^P' AND first_in_outside IS TRUE AND COALESCE(first_in_area,'') IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')) THEN 'Ontime'
        WHEN scheduled_in IS NULL THEN 'Ontime'
        WHEN check_in >= scheduled_in + interval '1 minute' THEN 'Late'
        ELSE 'Ontime'
      END AS punctuality_status
    FROM base
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(f) ORDER BY f.date, f.branch, f.full_name), '[]'::jsonb)
    INTO v_rows
  FROM final_rows f;

  RETURN jsonb_build_object(
    'ok',true,
    'records',v_rows,
    'from_date',p_start_date,
    'to_date',p_end_date,
    'total',jsonb_array_length(v_rows)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.hr_get_attendance_monitoring(p_token text, p_start_date date, p_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_emp public.karyawan;
  v_records jsonb := '[]'::jsonb;
  v_summary jsonb;
  v_summary_rows jsonb;
  v_today date := (now() AT TIME ZONE 'Asia/Jakarta')::date;
  v_ontime bigint := 0;
  v_late bigint := 0;
  v_early bigint := 0;
  v_no_out bigint := 0;
  v_no_in bigint := 0;
  v_has_timing boolean := false;
  v_is_approver boolean := false;
BEGIN
  v_emp := public.session_karyawan(p_token);
  v_is_approver := EXISTS (SELECT 1 FROM public.karyawan b WHERE b.approval_line_id=v_emp.employee_id AND b.status_akun='AKTIF');
  IF UPPER(COALESCE(v_emp.role, '')) NOT IN ('HR','ADMIN','SUPERADMIN') AND NOT v_is_approver THEN
    RAISE EXCEPTION 'Access denied.' USING ERRCODE = '42501';
  END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_start_date > p_end_date
     OR p_end_date - p_start_date > 400 THEN
    RAISE EXCEPTION 'Invalid monitoring range (maximum 401 days).';
  END IF;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(x) ORDER BY x.date DESC, x.time DESC, x.employee_name),
    '[]'::jsonb
  )
  INTO v_records
  FROM (
    SELECT
      a.id,
      UPPER(COALESCE(NULLIF(BTRIM(k.nama), ''), a.employee_id)) AS employee_name,
      a.employee_id,
      a.tanggal AS date,
      a.jam AS time,
      CASE WHEN a.tipe = 'MASUK' THEN 'Clock In'
           WHEN a.tipe = 'PULANG' THEN 'Clock Out' ELSE a.tipe END AS type,
      k.job_position,
      CASE
        WHEN EXISTS (
          SELECT 1 FROM storage.objects o
          WHERE o.bucket_id = 'evidence' AND o.name = a.storage_path
        ) THEN a.storage_path
        WHEN NULLIF(BTRIM(a.foto_path), '') ~* '^https?://' THEN BTRIM(a.foto_path)
        WHEN NULLIF(BTRIM(a.foto_url), '') ~* '^https?://' THEN BTRIM(a.foto_url)
        ELSE NULL
      END AS photo_url,
      CASE
        WHEN a.face_distance IS NOT NULL AND a.face_match IS TRUE THEN 'Matched'
        WHEN a.face_distance IS NOT NULL AND a.face_match IS FALSE THEN 'Not matched'
        WHEN a.face_match IS TRUE THEN 'Matched'
        WHEN a.face_local_precheck IS TRUE THEN 'Local precheck only'
        ELSE NULL
      END AS face_recognition,
      NULL::text AS liveness_validation,
      COALESCE(NULLIF(BTRIM(a.employee_branch_snapshot), ''), NULLIF(BTRIM(k.branch), ''), 'Pusat') AS location_setting_name,
      COALESCE(NULLIF(BTRIM(a.branch_target), ''), '—') AS location_gps_name,
      a.area AS area,
      a.catatan AS note,
      a.status_approval AS status_approval,
      a.address AS location_address,
      a.latitude,
      a.longitude,
      a.accuracy,
      a.distance_m,
      a.face_match,
      a.face_distance,
      a.face_local_precheck,
      a.shift_name_snapshot AS shift_name,
      a.shift_code_snapshot AS shift_code,
      a.shift_label_snapshot AS shift_label,
      to_char(a.scheduled_check_in_snapshot, 'HH24:MI') AS schedule_check_in,
      to_char(a.scheduled_check_out_snapshot, 'HH24:MI') AS schedule_check_out,
      CASE WHEN a.tipe='MASUK' THEN
        CASE WHEN UPPER(COALESCE(k.job_code,'')) IN ('WFA','HYBRID')
          OR EXISTS (SELECT 1 FROM public.absensi ai WHERE ai.employee_id=a.employee_id AND ai.tanggal=a.tanggal AND ai.tipe='MASUK'
            AND COALESCE(ai.status_approval,'VALID') NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')
            AND (COALESCE(ai.catatan,'') ~ '\[\[RHATT=(DL[1-5]?|DLL|SDL[1-5]?|SDLL)\]\]'
              OR (COALESCE(ai.catatan,'') !~ '\[\[RHATT=P' AND COALESCE(ai.outside_location,FALSE) IS TRUE
                  AND ai.area IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')))) THEN 'ON_TIME'
          WHEN a.scheduled_check_in_snapshot IS NULL THEN 'ON_TIME'
          WHEN a.jam >= a.scheduled_check_in_snapshot + interval '1 minute' THEN 'LATE'
          ELSE 'ON_TIME' END
        ELSE a.punctuality_status END AS punctuality_status,
      a.attendance_warning,
      a.calendar_day_type_snapshot,
      a.employee_branch_snapshot,
      a.outside_location,
      (a.tipe='PULANG' AND a.scheduled_check_out_snapshot IS NOT NULL AND a.jam < (a.scheduled_check_out_snapshot - make_interval(mins => COALESCE(a.early_window_minutes_snapshot,0)))
        AND UPPER(COALESCE(k.job_code,'')) NOT IN ('WFA','HYBRID')
        AND NOT EXISTS (SELECT 1 FROM public.absensi ai WHERE ai.employee_id=a.employee_id AND ai.tanggal=a.tanggal AND ai.tipe='MASUK'
          AND COALESCE(ai.status_approval,'VALID') NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')
          AND (COALESCE(ai.catatan,'') ~ '\[\[RHATT=(DL[1-5]?|DLL|SDL[1-5]?|SDLL)\]\]'
            OR (COALESCE(ai.catatan,'') !~ '\[\[RHATT=P' AND COALESCE(ai.outside_location,FALSE) IS TRUE
                AND ai.area IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')))) AS is_early_clock_out
    FROM public.absensi a
    LEFT JOIN public.karyawan k ON k.employee_id = a.employee_id
    WHERE a.tanggal BETWEEN p_start_date AND p_end_date
      AND (UPPER(COALESCE(v_emp.role,'')) IN ('HR','ADMIN','SUPERADMIN') OR k.approval_line_id=v_emp.employee_id)
  ) x;

  -- IMPORTANT: group raw events before referencing branch/calendar fields in any subquery.
  -- This avoids SQLSTATE 42803 (ungrouped outer column in subquery).
  WITH daily_events AS (
    SELECT
      a.employee_id::text AS employee_id,
      a.tanggal AS dt,
      BOOL_OR(a.tipe = 'MASUK' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')) AS has_in,
      BOOL_OR(a.tipe = 'PULANG' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')) AS has_out,
      MIN(a.jam) FILTER (WHERE a.tipe='MASUK' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')) AS first_in_time,
      MAX(a.scheduled_check_in_snapshot) FILTER (WHERE a.tipe='MASUK' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')) AS scheduled_in,
      substring(MAX(a.catatan) FILTER (WHERE a.tipe='MASUK' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')) FROM '\[\[RHATT=([A-Za-z0-9]+)\]\]') AS attendance_marker,
      MAX(k.job_code) AS job_code,
      BOOL_OR(COALESCE(a.outside_location,false)) FILTER (WHERE a.tipe='MASUK' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')) AS first_in_outside,
      MAX(a.area) FILTER (WHERE a.tipe='MASUK' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')) AS first_in_area,
      MAX(a.jam) FILTER (WHERE a.tipe='PULANG' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')) AS last_out,
      COALESCE(MAX(a.scheduled_check_out_snapshot) FILTER (WHERE a.tipe='PULANG' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')),
               MAX(a.scheduled_check_out_snapshot) FILTER (WHERE a.tipe='MASUK' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR'))) AS scheduled_out,
      COALESCE(MAX(a.early_window_minutes_snapshot) FILTER (WHERE a.tipe='PULANG' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')),
               MAX(a.early_window_minutes_snapshot) FILTER (WHERE a.tipe='MASUK' AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR'))) AS early_window_minutes,
      MAX(a.employee_branch_snapshot) FILTER (WHERE a.tipe = 'MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS branch_snapshot,
      MAX(a.calendar_day_type_snapshot) FILTER (WHERE a.tipe = 'MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS day_type_snapshot
    FROM public.absensi a
    LEFT JOIN public.karyawan k ON k.employee_id=a.employee_id
    WHERE a.tanggal BETWEEN p_start_date AND p_end_date
      AND a.status_approval NOT IN ('DITOLAK_ATASAN', 'DITOLAK_HR')
      AND (UPPER(COALESCE(v_emp.role,'')) IN ('HR','ADMIN','SUPERADMIN') OR k.approval_line_id=v_emp.employee_id)
    GROUP BY a.employee_id, a.tanggal
  ), daily_resolved AS (
    SELECT
      d.*,
      COALESCE(NULLIF(BTRIM(d.branch_snapshot), ''), NULLIF(BTRIM(k.branch), ''), 'Pusat') AS branch,
      COALESCE(
        d.day_type_snapshot,
        public.attendance_resolved_day_type(
          d.dt,
          COALESCE(NULLIF(BTRIM(d.branch_snapshot), ''), NULLIF(BTRIM(k.branch), ''), 'Pusat')
        )
      ) AS day_type,
      EXISTS (
        SELECT 1 FROM public.attendance_schedule_rules r
        WHERE LOWER(BTRIM(r.branch)) = LOWER(BTRIM(
          COALESCE(NULLIF(BTRIM(d.branch_snapshot), ''), NULLIF(BTRIM(k.branch), ''), 'Pusat')
        ))
          AND r.effective_from <= d.dt
          AND (r.effective_to IS NULL OR r.effective_to >= d.dt)
          AND r.is_workday = TRUE
          AND (
            r.day_of_week = EXTRACT(ISODOW FROM d.dt)::integer
            OR (
              EXTRACT(ISODOW FROM d.dt)::integer = 7
              AND public.attendance_resolved_day_type(
                d.dt,
                COALESCE(NULLIF(BTRIM(d.branch_snapshot), ''), NULLIF(BTRIM(k.branch), ''), 'Pusat')
              ) = 'WORKING_DAY'
              AND r.day_of_week BETWEEN 1 AND 6
            )
          )
          AND COALESCE(
            d.day_type_snapshot,
            public.attendance_resolved_day_type(
              d.dt,
              COALESCE(NULLIF(BTRIM(d.branch_snapshot), ''), NULLIF(BTRIM(k.branch), ''), 'Pusat')
            )
          ) NOT IN ('SUNDAY', 'NATIONAL_HOLIDAY', 'DAY_OFF')
      ) AS expected_workday,
      EXISTS (
        SELECT 1 FROM public.pengajuan_cuti c
        WHERE c.employee_id = d.employee_id
          AND c.status_atasan = 'DISETUJUI'
          AND c.status_hr = 'DISETUJUI'
          AND c.tanggal_mulai <= d.dt
          AND c.tanggal_selesai >= d.dt
      ) AS has_approved_time_off
    FROM daily_events d
    LEFT JOIN public.karyawan k ON k.employee_id = d.employee_id
  )
  SELECT
    COUNT(*) FILTER (WHERE has_in AND (
      UPPER(COALESCE(job_code,'')) IN ('WFA','HYBRID') OR COALESCE(attendance_marker,'') ~ '^(DL|SDL)' OR
      (COALESCE(attendance_marker,'') !~ '^P' AND first_in_outside IS TRUE AND COALESCE(first_in_area,'') IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')) OR
      (scheduled_in IS NOT NULL AND first_in_time < scheduled_in + interval '1 minute'))),
    COUNT(*) FILTER (WHERE has_in AND scheduled_in IS NOT NULL AND
      UPPER(COALESCE(job_code,'')) NOT IN ('WFA','HYBRID') AND COALESCE(attendance_marker,'') !~ '^(DL|SDL)' AND
      NOT (COALESCE(attendance_marker,'') !~ '^P' AND first_in_outside IS TRUE AND COALESCE(first_in_area,'') IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')) AND
      first_in_time >= scheduled_in + interval '1 minute'),
    COUNT(*) FILTER (WHERE has_out AND scheduled_out IS NOT NULL AND
      UPPER(COALESCE(job_code,'')) NOT IN ('WFA','HYBRID') AND COALESCE(attendance_marker,'') !~ '^(DL|SDL)' AND
      NOT (COALESCE(attendance_marker,'') !~ '^P' AND first_in_outside IS TRUE AND COALESCE(first_in_area,'') IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')) AND
      last_out < (scheduled_out - make_interval(mins => COALESCE(early_window_minutes,0)))),
    COUNT(*) FILTER (WHERE has_in AND NOT has_out),
    COALESCE(BOOL_OR(has_in AND (UPPER(COALESCE(job_code,'')) IN ('WFA','HYBRID') OR COALESCE(attendance_marker,'') ~ '^(DL|SDL)' OR
      (COALESCE(attendance_marker,'') !~ '^P' AND first_in_outside IS TRUE AND COALESCE(first_in_area,'') IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')) OR scheduled_in IS NOT NULL)), FALSE)
  INTO v_ontime, v_late, v_early, v_no_out, v_has_timing
  FROM daily_resolved;

  -- No Clock In is calculated from the complete employee-day grid, not from events alone.
  v_summary_rows := (
    public.hr_get_attendance_summary(p_token, p_start_date, p_end_date) -> 'records'
  );
  IF v_summary_rows IS NOT NULL AND jsonb_typeof(v_summary_rows) = 'array' THEN
    SELECT COUNT(*)
    INTO v_no_in
    FROM jsonb_array_elements(v_summary_rows) r
    WHERE COALESCE((r ->> 'employee_is_active')::boolean, FALSE) = TRUE
      AND NOT EXISTS (
        SELECT 1 FROM public.absensi a
        WHERE a.employee_id = r ->> 'employee_id'
          AND a.tanggal = (r ->> 'date')::date
          AND a.tipe = 'MASUK'
          AND COALESCE(a.status_approval,'VALID') NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')
      );
  END IF;

  -- The dashboard should show unknown, not zero, when no punctuality snapshots exist.
  IF NOT v_has_timing THEN
    v_ontime := NULL;
    v_late := NULL;
  END IF;


  v_summary := jsonb_build_object(
    'ontime', v_ontime,
    'lateClockIn', v_late,
    'earlyClockOut', v_early,
    'noClockOut', v_no_out,
    'noClockIn', v_no_in
  );

  RETURN jsonb_build_object(
    'ok', true,
    'summary', v_summary,
    'records', COALESCE(v_records, '[]'::jsonb),
    'total', jsonb_array_length(COALESCE(v_records, '[]'::jsonb)),
    'from_date', p_start_date,
    'to_date', p_end_date,
    'timezone', 'Asia/Jakarta'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.hr_get_leave_list_v2(p_token text, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_emp public.karyawan;
  v_list jsonb;
  v_is_approver boolean := false;
BEGIN
  v_emp := public.session_karyawan(p_token);
  v_is_approver := EXISTS (SELECT 1 FROM public.karyawan b WHERE b.approval_line_id=v_emp.employee_id AND b.status_akun='AKTIF');
  IF UPPER(COALESCE(v_emp.role,'')) NOT IN ('HR','ADMIN','SUPERADMIN') AND NOT v_is_approver THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;
  IF p_year IS NULL OR p_year NOT BETWEEN 2000 AND 2100 THEN
    RAISE EXCEPTION 'Invalid year.' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.submitted_at DESC), '[]'::jsonb)
  INTO v_list
  FROM (
    SELECT
      p.id, p."timestamp" AS submitted_at, p."timestamp" AS timestamp,
      p.employee_id, p.employee_id AS nik,
      UPPER(COALESCE(NULLIF(BTRIM(k.nama),''),NULLIF(BTRIM(p.nama),''),'')) AS nama,
      p.kode_cuti, COALESCE(NULLIF(BTRIM(p.keterangan_cuti),''),p.kode_cuti) AS keterangan_cuti,
      p.tanggal_mulai, p.tanggal_selesai, p.total_hari, p.alasan, p.dokumen_path,
      p.status_atasan, p.status_hr, p.alasan_atasan, p.alasan_hr,
      p.timestamp_atasan, p.timestamp_hr, k.approval_line_name, k.approval_line_id,
      p.delegate_to, d.nama AS delegate_name
    FROM public.pengajuan_cuti p
    LEFT JOIN public.karyawan k ON UPPER(BTRIM(k.employee_id))=UPPER(BTRIM(p.employee_id))
    LEFT JOIN public.karyawan d ON d.employee_id=p.delegate_to
    WHERE EXTRACT(YEAR FROM COALESCE(p.tanggal_mulai,p.tanggal_selesai,p."timestamp"::date))::integer=p_year
      AND (UPPER(COALESCE(v_emp.role,'')) IN ('HR','ADMIN','SUPERADMIN') OR k.approval_line_id=v_emp.employee_id)
  ) r;
  RETURN jsonb_build_object('ok',true,'list',v_list);
END;
$function$;

CREATE OR REPLACE FUNCTION public.hr_get_employee_directory_summary(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_emp public.karyawan; v_list jsonb; v_is_admin boolean;
BEGIN
  v_emp := public.session_karyawan(p_token);
  v_is_admin := UPPER(COALESCE(v_emp.role,'')) IN ('HR','ADMIN','SUPERADMIN');
  IF NOT v_is_admin AND NOT EXISTS (SELECT 1 FROM public.karyawan b WHERE b.approval_line_id=v_emp.employee_id AND b.status_akun='AKTIF') THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE='42501';
  END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.nama),'[]'::jsonb) INTO v_list
  FROM (
    SELECT k.employee_id AS nik,k.employee_id,k.nama,k.branch,k.organization,k.organization AS org,k.organization AS department,
      k.job_level,k.job_level AS level,k.job_position,k.job_position AS posisi,k.job_code,k.grade,k.class,
      k.employment_status,k.employment_status AS "statusKerja",k.status_akun,k.status_akun AS akun,k.role,
      k.join_date,k.contract_end_date,k.approval_line_id,k.approval_line_name,
      COALESCE(k.face_photo_ver,0) AS "facePhotoVer",COALESCE(k.face_version,0) AS "faceVer",k.gender
    FROM public.karyawan k
    WHERE v_is_admin OR k.approval_line_id=v_emp.employee_id
  ) r;
  RETURN jsonb_build_object('ok',true,'list',v_list);
END;
$function$;


CREATE OR REPLACE FUNCTION public.hr_get_employee_directory(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_emp public.karyawan;
  v_is_admin boolean := false;
  v_list jsonb;
BEGIN
  IF p_token IS NULL OR BTRIM(p_token) = '' THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;
  v_emp := public.session_karyawan(p_token);
  v_is_admin := UPPER(COALESCE(v_emp.role,'')) IN ('HR','ADMIN','SUPERADMIN');
  IF NOT v_is_admin AND NOT public.rh_is_active_approver(v_emp.employee_id) THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE='42501';
  END IF;

  SELECT COALESCE(jsonb_agg(
    CASE WHEN v_is_admin THEN to_jsonb(r)
      ELSE jsonb_build_object(
        'id',r.id,'employee_id',r.employee_id,'nik',r.nik,'nama',r.nama,
        'branch',r.branch,'organization',r.organization,'org',r.org,'department',r.department,
        'job_level',r.job_level,'level',r.level,'job_position',r.job_position,'posisi',r.posisi,
        'job_code',r.job_code,'grade',r.grade,'class',r.class,
        'employment_status',r.employment_status,'statusKerja',r."statusKerja",
        'approval_line_name',r.approval_line_name,'atasanNama',r."atasanNama",
        'approval_line_id',r.approval_line_id,'atasanId',r."atasanId",
        'join_date',r.join_date,'joinDate',r."joinDate",
        'working_period',r.working_period,'workingPeriod',r."workingPeriod",
        'status_akun',r.status_akun,'akun',r.akun,'role',r.role,
        'faceVer',r."faceVer",'facePhotoVer',r."facePhotoVer",'gender',r.gender
      ) END ORDER BY r.nama
    ),'[]'::jsonb)
  INTO v_list
  FROM (
    SELECT
      k.id,
      k.employee_id,
      k.employee_id AS nik,
      k.nama,
      k.branch,
      k.organization,
      k.organization AS org,
      k.organization AS department,
      k.job_level,
      k.job_level AS level,
      k.job_position,
      k.job_position AS posisi,
      k.job_code,
      k.grade,
      k.class,
      k.total_reprimand,
      k.reprimand_type,
      k.reprimand_status,
      k.employment_status,
      k.employment_status AS "statusKerja",
      k.approval_line_name,
      k.approval_line_name AS "atasanNama",
      k.approval_line_id,
      k.approval_line_id AS "atasanId",
      k.join_date,
      k.join_date AS "joinDate",
      public.karyawan_working_period(k.join_date, CURRENT_DATE) AS working_period,
      public.karyawan_working_period(k.join_date, CURRENT_DATE) AS "workingPeriod",
      k.contract_start_date,
      k.contract_start_date AS "contractStartDate",
      k.contract_end_date,
      k.contract_end_date AS "contractEndDate",
      k.address,
      k.ktp_number,
      k.place_of_birth,
      k.birth_date,
      k.phone,
      k.email,
      k.education,
      k.gender,
      k.religion,
      k.marital_status,
      k.npwp,
      k.bpjs_kesehatan,
      k.bpjs_ketenagakerjaan,
      k.bank_name,
      k.bank_account,
      k.status_akun,
      k.status_akun AS akun,
      k.role,
      CASE WHEN k.face IS NULL THEN 'NO' ELSE 'YES' END AS face,
      k.face_version AS "faceVer",
      k.face_photo_ver AS "facePhotoVer"
    FROM public.karyawan AS k
    WHERE v_is_admin OR k.approval_line_id=v_emp.employee_id
  ) AS r;
  RETURN jsonb_build_object('ok', true, 'list', v_list);
END;
$function$;

CREATE OR REPLACE FUNCTION public.hr_attendance_today(p_token text, p_date date DEFAULT NULL::date)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_emp public.karyawan; v_d date; v_list json; v_total int; v_hadir int; v_is_admin boolean;
BEGIN
  v_emp := public.session_karyawan(p_token);
  v_is_admin := UPPER(COALESCE(v_emp.role,'')) IN ('HR','ADMIN','SUPERADMIN');
  IF NOT v_is_admin AND NOT EXISTS (SELECT 1 FROM public.karyawan b WHERE b.approval_line_id=v_emp.employee_id AND b.status_akun='AKTIF') THEN
    RAISE EXCEPTION 'Akses ditolak.' USING ERRCODE='42501';
  END IF;
  v_d := COALESCE(p_date,(timezone('Asia/Jakarta',now()))::date);
  SELECT count(*) INTO v_total FROM public.karyawan k WHERE k.status_akun='AKTIF' AND (v_is_admin OR k.approval_line_id=v_emp.employee_id);
  SELECT COALESCE(json_agg(x ORDER BY x.nama),'[]'::json) INTO v_list
  FROM (
    SELECT k.employee_id AS nik,k.nama,
      min(CASE WHEN a.tipe='MASUK' THEN to_char(a.jam,'HH24:MI') END) AS "jamMasuk",
      max(CASE WHEN a.tipe='PULANG' THEN to_char(a.jam,'HH24:MI') END) AS "jamPulang",
      CASE WHEN bool_or(a.tipe='MASUK') AND bool_or(a.tipe='PULANG') THEN 'HADIR'
           WHEN bool_or(a.tipe='MASUK') THEN 'BELUM_PULANG' ELSE 'BELUM_HADIR' END AS status
    FROM public.karyawan k
    LEFT JOIN public.absensi a ON a.employee_id=k.employee_id AND a.tanggal=v_d
      AND a.status_approval IN ('VALID','DISETUJUI','PENDING_ATASAN','PENDING_HR')
    WHERE k.status_akun='AKTIF' AND (v_is_admin OR k.approval_line_id=v_emp.employee_id)
    GROUP BY k.employee_id,k.nama
  ) x;
  SELECT count(*) INTO v_hadir FROM json_array_elements(v_list) e WHERE e->>'status' IN ('HADIR','BELUM_PULANG');
  RETURN json_build_object('ok',true,'tanggal',to_char(v_d,'YYYY-MM-DD'),'total',v_total,'hadir',v_hadir,'list',v_list);
END;
$function$;


CREATE OR REPLACE FUNCTION public.submit_attendance(p_token text, p_tipe text, p_lat double precision, p_lon double precision, p_acc double precision, p_descriptor text, p_catatan text DEFAULT ''::text, p_address text DEFAULT ''::text, p_foto_base64 text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_emp            karyawan;
  v_branch         text;
  v_office         lokasi_kantor;
  v_pasuruan_office lokasi_kantor;
  v_pasuruan_distance double precision;
  v_threshold      double precision;
  v_face_dist      double precision;
  v_distance       double precision;
  v_in_office      boolean;
  v_status         text;
  v_atasan         text;
  v_id             text;
  v_has_masuk      boolean;
  v_has_pulang     boolean;
  v_prior_in_status text;
  v_prior_in_manager text;
  v_prior_in_requires_approval boolean := false;
  v_approval_required boolean := false;
  v_desc_arr       double precision[];
  v_today          date := (timezone('Asia/Jakarta', now()))::date;
  v_now            time := (timezone('Asia/Jakarta', now()))::time;
begin
  -- ===== AUTH =====
  v_emp := public.session_karyawan(p_token);

  -- ===== VALIDASI DASAR =====
  p_tipe := upper(trim(coalesce(p_tipe,'')));
  if p_tipe not in ('MASUK','PULANG') then
    raise exception 'Tipe absensi tidak valid.';
  end if;
  if p_lat is null or p_lon is null then
    raise exception 'GPS belum tersedia.';
  end if;

  -- ===== FIX 1: PARSE FACE DESCRIPTOR DARI TEXT =====
  if p_descriptor is null or trim(p_descriptor) = '' then
    raise exception 'Face descriptor tidak valid.';
  end if;

  -- Handle JSON array "[0.1, 0.2, ...]" ATAU PostgreSQL array "{0.1, 0.2, ...}"
  if left(trim(p_descriptor), 1) = '[' then
    v_desc_arr := translate(trim(p_descriptor), '[]', '{}')::double precision[];
  elsif left(trim(p_descriptor), 1) = '{' then
    v_desc_arr := p_descriptor::double precision[];
  else
    raise exception 'Format face descriptor tidak dikenali.';
  end if;

  if array_length(v_desc_arr, 1) <> 128 then
    raise exception 'Face descriptor harus 128 angka.';
  end if;

  if v_emp.face is null then
    raise exception 'Face ID belum terdaftar.';
  end if;

  -- ===== FACE MATCHING =====
  select coalesce(value::double precision, 0.55)
    into v_threshold
    from public.settings
   where key = 'FACE_MATCH_THRESHOLD';

  v_face_dist := (v_desc_arr::vector <-> v_emp.face);

  if v_face_dist > v_threshold then
    raise exception 'Wajah tidak cocok. Jarak: %.', round(v_face_dist::numeric, 3);
  end if;

  -- ===== LOKASI KANTOR BERDASARKAN MUTASI CABANG EFEKTIF =====
  -- Keep the geofence target aligned with the same branch-history resolver used
  -- by attendance snapshot triggers and the day-off attendance path.
  SELECT h.branch INTO v_branch
  FROM public.attendance_employee_branch_history h
  WHERE h.employee_id = v_emp.employee_id
    AND h.effective_from <= v_today
    AND (h.effective_to IS NULL OR h.effective_to >= v_today)
  ORDER BY h.effective_from DESC
  LIMIT 1;
  v_branch := COALESCE(NULLIF(BTRIM(v_branch), ''), NULLIF(BTRIM(v_emp.branch), ''), 'Pusat');

  select * into v_office
    from public.lokasi_kantor
   where upper(btrim(branch)) = upper(btrim(v_branch)) and status = 'AKTIF'
   order by (branch = v_branch) desc, updated_at desc, branch
   limit 1;

  if not found then
    raise exception 'Lokasi kantor untuk branch % tidak ditemukan.', v_branch;
  end if;

  v_distance  := public.haversine_m(p_lat, p_lon, v_office.latitude, v_office.longitude);
  v_in_office := v_distance <= v_office.radius_m;

  -- PM may also clock in/out at the active Pasuruan office. The employee's
  -- own branch remains the primary location; Pasuruan is an additional option.
  -- Selecting it here makes branch_target and server-side geofence validation
  -- agree, so an in-radius Pasuruan event is stored as VALID (not pending).
  IF upper(coalesce(v_emp.job_code,'')) = 'PM' THEN
    SELECT * INTO v_pasuruan_office
    FROM public.lokasi_kantor
    WHERE lower(btrim(branch)) = 'pasuruan'
      AND status = 'AKTIF'
    ORDER BY updated_at DESC, branch
    LIMIT 1;

    IF FOUND THEN
      v_pasuruan_distance := public.haversine_m(
        p_lat, p_lon, v_pasuruan_office.latitude, v_pasuruan_office.longitude
      );
      IF v_pasuruan_distance <= v_pasuruan_office.radius_m
         AND (NOT v_in_office OR v_pasuruan_distance < v_distance) THEN
        v_office := v_pasuruan_office;
        v_distance := v_pasuruan_distance;
        v_in_office := TRUE;
      END IF;
    END IF;
  END IF;

  IF coalesce(p_acc, 9999) > v_office.max_accuracy_m THEN
    raise exception 'Akurasi GPS terlalu rendah (% m). Maksimal % m.',
      round(p_acc), v_office.max_accuracy_m;
  end if;

  if not v_in_office and (p_catatan is null or trim(p_catatan) = '') then
    raise exception 'Absen di luar radius wajib disertai catatan.';
  end if;

  -- ===== CEK DUPLIKASI =====
  select coalesce(bool_or(tipe='MASUK'), false),
         coalesce(bool_or(tipe='PULANG'), false)
    into v_has_masuk, v_has_pulang
    from public.absensi
   where employee_id = v_emp.employee_id
     and tanggal     = v_today
     and status_approval not in ('DITOLAK_ATASAN','DITOLAK_HR');

  if p_tipe = 'MASUK'  and v_has_masuk  then raise exception 'Sudah Clock In hari ini.';  end if;
  if p_tipe = 'PULANG' and v_has_pulang then raise exception 'Sudah Clock Out hari ini.'; end if;

  -- ===== STATUS APPROVAL =====
  -- Clock Out follows Clock In when the latter is still waiting for approval,
  -- even when Clock Out itself is inside the geofence. This keeps the day coherent.
  v_prior_in_status := NULL;
  v_prior_in_manager := NULL;
  IF p_tipe='PULANG' THEN
    SELECT a.status_approval, a.atasan_id, (COALESCE(a.approval_required,false) OR COALESCE(a.outside_location,false) OR a.approval_manager_at IS NOT NULL OR a.approval_hr_at IS NOT NULL OR a.status_approval IN ('PENDING_ATASAN','PENDING_HR'))
      INTO v_prior_in_status, v_prior_in_manager, v_prior_in_requires_approval
    FROM public.absensi a
    WHERE a.employee_id=v_emp.employee_id AND a.tanggal=v_today AND a.tipe='MASUK'
      AND a.status_approval NOT IN ('DITOLAK_ATASAN','DITOLAK_HR')
    ORDER BY a.jam DESC, a.timestamp DESC LIMIT 1;
  END IF;
  IF p_tipe='PULANG' AND v_prior_in_requires_approval THEN
    v_status := CASE WHEN v_prior_in_status IN ('PENDING_ATASAN','PENDING_HR') THEN v_prior_in_status ELSE 'PENDING_ATASAN' END;
    v_atasan := COALESCE(v_prior_in_manager, v_emp.approval_line_id);
    v_approval_required := TRUE;
  ELSIF v_in_office THEN
    v_status := 'VALID'; v_atasan := null;
  ELSE
    v_status := 'PENDING_ATASAN'; v_atasan := v_emp.approval_line_id;
    v_approval_required := TRUE;
  END IF;

  -- ===== FIX 2 & 3: INSERT + FOTO SEKALIGUS =====
  v_id := 'ABS-' || to_char(timezone('Asia/Jakarta', now()), 'YYYYMMDDHH24MISS')
       || '-' || v_emp.employee_id;

  insert into public.absensi(
    id, employee_id, tanggal, jam, timestamp, tipe,
    latitude, longitude, accuracy, address, catatan,
    branch_target, distance_m, status_approval, atasan_id,
    face_match, face_distance, face_local_precheck, approval_required,
    foto_url                                    -- ← foto base64 disimpan di sini
  ) values (
    v_id, v_emp.employee_id, v_today, v_now, now(), p_tipe,
    p_lat, p_lon, p_acc, p_address, p_catatan,
    v_office.branch, v_distance, v_status, v_atasan,
    true, v_face_dist, false, v_approval_required,
    p_foto_base64                               -- ← langsung tersimpan, TIDAK ada race condition
  );

  return json_build_object(
    'success',        true,
    'id',             v_id,
    'inOffice',       v_in_office,
    'message',        case
                        when v_status = 'VALID' then
                          case when p_tipe='MASUK' then 'Clock In berhasil.'
                               else 'Clock Out berhasil.' end
                        else 'Pengajuan presensi terkirim. Menunggu persetujuan.'
                      end,
    'statusApproval', v_status,
    'tanggal',        to_char(v_today, 'YYYY-MM-DD'),
    'jam',            to_char(v_now, 'HH24:MI:SS'),
    'tipe',           p_tipe
  );
end;
$function$;


GRANT EXECUTE ON FUNCTION public.hr_get_dashboard_panels(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hr_list_attendance_adjustments(text,text,date,date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hr_save_attendance_adjustment(text,text,text,text,date,text,time,text) TO anon, authenticated;


-- Approver-safe organization map: never return grandchildren or other managers' teams.
CREATE OR REPLACE FUNCTION public.get_org_chart(p_token text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog','public'
AS $function$
DECLARE v_emp public.karyawan; v_full boolean; v_approver boolean; v_out json;
BEGIN
  v_emp:=public.session_karyawan(p_token);
  v_full:=UPPER(COALESCE(v_emp.role,'')) IN ('HR','ADMIN','SUPERADMIN');
  v_approver:=public.rh_is_active_approver(v_emp.employee_id);
  IF NOT v_full AND NOT v_approver THEN RAISE EXCEPTION 'Akses ditolak.' USING ERRCODE='42501'; END IF;
  SELECT COALESCE(json_agg(json_build_object(
    'nik',q.employee_id,'nama',q.nama,'posisi',q.job_position,'org',q.organization,
    'atasanId',q.approval_line_id,'faceVer',COALESCE(q.face_photo_ver,0),'directCount',q.direct_count
  ) ORDER BY q.is_self DESC,q.nama),'[]'::json)
  INTO v_out
  FROM (
    SELECT k.employee_id,k.nama,k.job_position,k.organization,k.approval_line_id,k.face_photo_ver,
      (SELECT COUNT(*) FROM public.karyawan c WHERE c.approval_line_id=k.employee_id AND c.status_akun='AKTIF') AS direct_count,
      (k.employee_id=v_emp.employee_id) AS is_self
    FROM public.karyawan k
    WHERE k.status_akun='AKTIF' AND (v_full OR k.employee_id=v_emp.employee_id OR k.approval_line_id=v_emp.employee_id)
  ) q;
  RETURN json_build_object('success',true,'list',v_out);
END;
$function$;


-- Monthly attendance report is role-scoped at the database boundary.
CREATE OR REPLACE FUNCTION public.hr_monthly_report(p_token text, p_year integer, p_month integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog','public'
AS $function$
DECLARE
  v_emp public.karyawan; v_full boolean; v_approver boolean;
  v_start date; v_end date; v_aktif int; v_abs int; v_kontrak int; v_cuti int;
  v_rekap json; v_kontrak_list json; v_cuti_list json; v_inout json;
BEGIN
  v_emp:=public.session_karyawan(p_token);
  v_full:=UPPER(COALESCE(v_emp.role,'')) IN ('HR','ADMIN','SUPERADMIN');
  v_approver:=public.rh_is_active_approver(v_emp.employee_id);
  IF NOT v_full AND NOT v_approver THEN RAISE EXCEPTION 'Akses ditolak.' USING ERRCODE='42501'; END IF;
  IF p_year IS NULL OR p_month IS NULL OR p_month<1 OR p_month>12 OR p_year<1900 OR p_year>9999 THEN
    RAISE EXCEPTION 'Tahun atau bulan tidak valid.' USING ERRCODE='22023';
  END IF;
  v_start:=make_date(p_year,p_month,1); v_end:=(v_start+interval '1 month - 1 day')::date;

  SELECT COUNT(*) INTO v_aktif FROM public.karyawan k WHERE k.status_akun='AKTIF'
    AND (v_full OR k.approval_line_id=v_emp.employee_id);
  SELECT COUNT(*) INTO v_abs FROM public.absensi a JOIN public.karyawan k ON k.employee_id=a.employee_id
    WHERE a.tanggal BETWEEN v_start AND v_end AND a.status_approval IN ('VALID','DISETUJUI','PENDING_ATASAN','PENDING_HR')
      AND (v_full OR k.approval_line_id=v_emp.employee_id);
  SELECT COUNT(*) INTO v_kontrak FROM public.karyawan k WHERE k.status_akun='AKTIF'
    AND k.contract_end_date BETWEEN v_start AND v_end AND (v_full OR k.approval_line_id=v_emp.employee_id);
  SELECT COUNT(*) INTO v_cuti FROM public.pengajuan_cuti c JOIN public.karyawan k ON k.employee_id=c.employee_id
    WHERE c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI' AND c.tanggal_mulai<=v_end AND c.tanggal_selesai>=v_start
      AND (v_full OR k.approval_line_id=v_emp.employee_id);

  SELECT COALESCE(json_agg(json_build_object('kategori',g.kategori,'jumlah',g.jumlah,'keterangan',g.keterangan) ORDER BY g.urutan),'[]'::json)
  INTO v_rekap FROM (
    SELECT 'Hadir (Clock In)' AS kategori,COUNT(DISTINCT (a.employee_id,a.tanggal)) AS jumlah,
      'Termasuk yang belum clock out' AS keterangan,1 AS urutan
    FROM public.absensi a JOIN public.karyawan k ON k.employee_id=a.employee_id
    WHERE a.tipe='MASUK' AND a.tanggal BETWEEN v_start AND v_end AND a.status_approval IN ('VALID','DISETUJUI','PENDING_ATASAN','PENDING_HR')
      AND (v_full OR k.approval_line_id=v_emp.employee_id)
    UNION ALL
    SELECT 'Menunggu Approval',COUNT(*),'Absensi menunggu persetujuan atasan atau HR',2
    FROM public.absensi a JOIN public.karyawan k ON k.employee_id=a.employee_id
    WHERE a.tanggal BETWEEN v_start AND v_end AND a.status_approval IN ('PENDING_ATASAN','PENDING_HR')
      AND (v_full OR k.approval_line_id=v_emp.employee_id)
    UNION ALL
    SELECT 'Ditolak',COUNT(*),'Absensi ditolak pada periode ini',3
    FROM public.absensi a JOIN public.karyawan k ON k.employee_id=a.employee_id
    WHERE a.tanggal BETWEEN v_start AND v_end AND a.status_approval IN ('DITOLAK_ATASAN','DITOLAK_HR')
      AND (v_full OR k.approval_line_id=v_emp.employee_id)
    UNION ALL
    SELECT 'Cuti Disetujui',COUNT(*),'Pengajuan cuti disetujui yang beririsan dengan periode',4
    FROM public.pengajuan_cuti c JOIN public.karyawan k ON k.employee_id=c.employee_id
    WHERE c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI' AND c.tanggal_mulai<=v_end AND c.tanggal_selesai>=v_start
      AND (v_full OR k.approval_line_id=v_emp.employee_id)
  ) g;

  SELECT COALESCE(json_agg(json_build_object('nik',k.employee_id,'nama',k.nama,'bagian',k.organization,
    'tanggal',to_char(k.contract_end_date,'YYYY-MM-DD')) ORDER BY k.contract_end_date),'[]'::json)
  INTO v_kontrak_list FROM public.karyawan k WHERE k.status_akun='AKTIF' AND k.contract_end_date BETWEEN v_start AND v_end
    AND (v_full OR k.approval_line_id=v_emp.employee_id);

  SELECT COALESCE(json_agg(json_build_object('nama',c.nama,'departemen',k.organization,'kode',c.kode_cuti,
    'keterangan',c.keterangan_cuti,'tanggalMulai',to_char(c.tanggal_mulai,'YYYY-MM-DD'),
    'tanggalSelesai',to_char(c.tanggal_selesai,'YYYY-MM-DD')) ORDER BY c.tanggal_mulai),'[]'::json)
  INTO v_cuti_list FROM public.pengajuan_cuti c JOIN public.karyawan k ON k.employee_id=c.employee_id
  WHERE c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI' AND c.tanggal_mulai<=v_end AND c.tanggal_selesai>=v_start
    AND (v_full OR k.approval_line_id=v_emp.employee_id);

  SELECT COALESCE(json_agg(x ORDER BY x.tanggal),'[]'::json) INTO v_inout FROM (
    SELECT 'MASUK' AS status,k.employee_id AS nik,k.nama,k.organization AS bagian,to_char(k.join_date,'YYYY-MM-DD') AS tanggal
    FROM public.karyawan k WHERE k.join_date BETWEEN v_start AND v_end AND (v_full OR k.approval_line_id=v_emp.employee_id)
    UNION ALL
    SELECT 'KELUAR' AS status,k.employee_id AS nik,k.nama,k.organization AS bagian,
      to_char(k.updated_at AT TIME ZONE 'Asia/Jakarta','YYYY-MM-DD') AS tanggal
    FROM public.karyawan k WHERE k.status_akun='NONAKTIF'
      AND (k.updated_at AT TIME ZONE 'Asia/Jakarta')::date BETWEEN v_start AND v_end
      AND (v_full OR k.approval_line_id=v_emp.employee_id)
  ) x;
  PERFORM public.log_activity(p_token,'EXPORT','LAPORAN','hr_monthly_report',
    'Laporan '||p_year||'-'||lpad(p_month::text,2,'0'));
  RETURN json_build_object('ok',true,'ringkasan',json_build_object('karyawanAktif',v_aktif,'totalAbsensi',v_abs,
    'kontrakBerakhir',v_kontrak,'pengambilanCuti',v_cuti),'rekap',v_rekap,'kontrak',v_kontrak_list,'cuti',v_cuti_list,'inout',v_inout);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_org_chart(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hr_monthly_report(text,integer,integer) TO anon, authenticated;
