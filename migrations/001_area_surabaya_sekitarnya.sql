-- ReHolz Tahap 4 Paket A — Surabaya & Sekitarnya
-- Staging-first migration. Run only after reviewing the matching Paket A frontend snapshot.
BEGIN;

ALTER TABLE public.absensi DROP CONSTRAINT IF EXISTS absensi_area_check;
ALTER TABLE public.absensi ADD CONSTRAINT absensi_area_check
  CHECK (area IS NULL OR area = ANY (ARRAY[
    'Area 1'::text, 'Area 2'::text, 'Area 3'::text, 'Area 4'::text,
    'Area lainnya'::text, 'Surabaya & Sekitarnya'::text
  ]));

-- GPS is still validated as outside the active office radius. The selected location
-- is stored as a display label, while attendance code remains H (P/SDR are unchanged).
CREATE OR REPLACE FUNCTION public.hris_validate_outside_location_attendance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_area_code text;
  v_branch text;
  v_radius numeric;
  v_outside boolean;
  v_distance_is_verifiable boolean := false;
BEGIN
  v_area_code := substring(COALESCE(NEW.catatan,'') from '\[\[RHAREA=(A1|A2|A3|A4|AX|SBY)\]\]');

  IF v_area_code IS NOT NULL THEN
    NEW.area := CASE v_area_code
      WHEN 'A1' THEN 'Area 1'
      WHEN 'A2' THEN 'Area 2'
      WHEN 'A3' THEN 'Area 3'
      WHEN 'A4' THEN 'Area 4'
      WHEN 'AX' THEN 'Area lainnya'
      WHEN 'SBY' THEN 'Surabaya & Sekitarnya'
      ELSE 'Area lainnya'
    END;
    NEW.catatan := BTRIM(regexp_replace(COALESCE(NEW.catatan,''),
      '[[:space:]]*\[\[RHAREA=(A1|A2|A3|A4|AX|SBY)\]\][[:space:]]*',' ','g'));
  END IF;

  -- Cabang snapshot diprioritaskan agar riwayat tidak berubah mengikuti cabang
  -- karyawan yang mungkin sudah dipindahkan setelah tanggal presensi.
  -- submit_attendance menghitung distance_m terhadap lokasi branch_target.
  -- Karena itu radius validasi harus berasal dari branch_target yang sama,
  -- bukan cabang historis yang dapat berbeda setelah mutasi karyawan.
  SELECT COALESCE(
           NULLIF(BTRIM(NEW.branch_target),''),
           NULLIF(BTRIM(NEW.employee_branch_snapshot),''),
           NULLIF(BTRIM(k.branch),'')
         )
    INTO v_branch
  FROM public.karyawan k
  WHERE k.employee_id = NEW.employee_id;

  IF v_branch IS NULL THEN
    v_branch := COALESCE(NULLIF(BTRIM(NEW.branch_target),''),
                         NULLIF(BTRIM(NEW.employee_branch_snapshot),''));
  END IF;

  SELECT lk.radius_m
    INTO v_radius
  FROM public.lokasi_kantor lk
  WHERE lk.status = 'AKTIF'
    AND LOWER(BTRIM(lk.branch)) = LOWER(BTRIM(COALESCE(v_branch,'')))
  ORDER BY lk.updated_at DESC
  LIMIT 1;

  IF NEW.distance_m IS NOT NULL THEN
    IF v_radius IS NULL THEN
      RAISE EXCEPTION 'Radius kantor aktif tidak ditemukan untuk cabang %; presensi dibatalkan.',
        COALESCE(v_branch,'(kosong)') USING ERRCODE='23514';
    END IF;
    v_distance_is_verifiable := true;
    v_outside := NEW.distance_m > v_radius;
  ELSIF TG_OP='INSERT' THEN
    RAISE EXCEPTION 'Jarak GPS hasil perhitungan server tidak tersedia; presensi dibatalkan.'
      USING ERRCODE='23514';
  ELSE
    -- Update historis tanpa distance_m tidak boleh mengubah hasil geofence.
    v_outside := COALESCE(NEW.outside_location,FALSE);
  END IF;

  IF v_area_code IS NOT NULL AND v_distance_is_verifiable AND NOT v_outside THEN
    RAISE EXCEPTION 'Area luar kantor tidak sesuai: GPS berada dalam radius kantor. Perbarui lokasi GPS.'
      USING ERRCODE='23514';
  END IF;

  NEW.outside_location := COALESCE(v_outside,FALSE);

  IF NEW.tipe IN ('MASUK','PULANG') AND NEW.outside_location IS TRUE THEN
    IF NULLIF(BTRIM(COALESCE(NEW.catatan,'')),'') IS NULL THEN
      RAISE EXCEPTION 'Keterangan wajib diisi untuk presensi di luar kantor.' USING ERRCODE='23514';
    END IF;
    IF NEW.area IS NULL OR NEW.area NOT IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya','Surabaya & Sekitarnya') THEN
      RAISE EXCEPTION 'Pilih Pengaturan Lokasi yang sesuai untuk presensi di luar kantor.' USING ERRCODE='23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$


;

------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.hris_reholz_attendance_incentive_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_mode text := upper(coalesce(current_setting('app.reholz_dayoff_mode', true), ''));
  v_approver text;
  v_area_no integer;
  v_code text;
BEGIN
  IF NEW.tipe = 'MASUK' AND EXISTS (
    SELECT 1 FROM public.pengajuan_cuti c
    WHERE c.employee_id = NEW.employee_id
      AND c.status_atasan = 'DISETUJUI'
      AND c.status_hr = 'DISETUJUI'
      AND c.tanggal_mulai <= NEW.tanggal
      AND c.tanggal_selesai >= NEW.tanggal
  ) THEN
    RAISE EXCEPTION 'Selamat Menjalankan Time Off Anda' USING ERRCODE = 'P0001';
  END IF;

  -- Marker RHATT dari browser tidak dipercaya. Marker lama maupun baru dibuang
  -- sebelum server menambahkan marker kanonis yang dihitung sendiri.
  NEW.catatan := btrim(regexp_replace(coalesce(NEW.catatan,''),
    '[[:space:]]*\[\[RHATT=(P[1-5]?|PL|SDL[1-5]|SDLL|DL[1-5]|DLL)\]\][[:space:]]*', ' ', 'gi'));

  IF NEW.tipe = 'MASUK' AND v_mode = '' AND (
       coalesce(NEW.calendar_day_type_snapshot IN ('SUNDAY','NATIONAL_HOLIDAY','JOINT_LEAVE','DAY_OFF'), false)
       OR coalesce(NEW.schedule_is_workday_snapshot = FALSE, false)
  ) THEN
    RAISE EXCEPTION 'Clock In pada hari libur harus melalui pilihan Piket atau Standby.' USING ERRCODE = '22023';
  END IF;

  IF v_mode = '' THEN
    RETURN NEW;
  END IF;
  IF NEW.tipe <> 'MASUK' THEN
    RAISE EXCEPTION 'Mode Piket/Standby hanya berlaku untuk Clock In.' USING ERRCODE = '22023';
  END IF;
  IF NOT (
    coalesce(NEW.calendar_day_type_snapshot IN ('SUNDAY','NATIONAL_HOLIDAY','JOINT_LEAVE','DAY_OFF'), false)
    OR coalesce(NEW.schedule_is_workday_snapshot = FALSE, false)
  ) THEN
    RAISE EXCEPTION 'Kalender tidak memvalidasi hari ini sebagai hari libur. Clock In Piket/Standby dibatalkan.' USING ERRCODE = '22023';
  END IF;

  v_area_no := CASE NEW.area
    WHEN 'Area 1' THEN 1
    WHEN 'Area 2' THEN 2
    WHEN 'Area 3' THEN 3
    WHEN 'Area 4' THEN 4
    WHEN 'Area lainnya' THEN 5
    WHEN 'Surabaya & Sekitarnya' THEN 0
    ELSE NULL
  END;

  IF v_mode = 'STANDBY' THEN
    IF coalesce(NEW.outside_location,false) IS NOT TRUE OR v_area_no IS NULL OR v_area_no NOT BETWEEN 1 AND 5 THEN
      RAISE EXCEPTION 'Standby hanya berlaku untuk dinas luar Area 1–4 atau Area Lain.' USING ERRCODE = '22023';
    END IF;
    v_code := CASE WHEN v_area_no = 5 THEN 'SDLL' ELSE 'SDL' || v_area_no::text END;
  ELSIF v_mode = 'PIKET' THEN
    IF coalesce(NEW.outside_location,false) THEN
      IF v_area_no IS NULL THEN
        RAISE EXCEPTION 'Piket dinas luar wajib memiliki Area 1–4 atau Area Lain.' USING ERRCODE = '22023';
      END IF;
      v_code := CASE WHEN v_area_no = 0 THEN 'P' WHEN v_area_no = 5 THEN 'PL' ELSE 'P' || v_area_no::text END;
    ELSE
      IF NEW.area IS NOT NULL THEN
        RAISE EXCEPTION 'Piket kantor tidak boleh memiliki area dinas luar.' USING ERRCODE = '22023';
      END IF;
      v_code := 'P';
    END IF;
  ELSE
    RAISE EXCEPTION 'Mode kehadiran hari libur tidak dikenal.' USING ERRCODE = '22023';
  END IF;

  SELECT k.approval_line_id INTO v_approver
  FROM public.karyawan k
  JOIN public.karyawan a ON a.employee_id = k.approval_line_id AND a.status_akun = 'AKTIF'
  WHERE k.employee_id = NEW.employee_id;
  IF v_approver IS NULL THEN
    RAISE EXCEPTION 'Atasan langsung belum terpetakan. Hubungi HR sebelum Clock In Piket/Standby.' USING ERRCODE = '22023';
  END IF;

  NEW.atasan_id := v_approver;
  NEW.status_approval := 'PENDING_ATASAN';
  NEW.catatan := concat_ws(' ', nullif(btrim(NEW.catatan),''), '[[RHATT=' || v_code || ']]');
  RETURN NEW;
END;
$function$


;

------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.submit_dayoff_attendance_with_photo(p_token text, p_tipe text, p_lat double precision, p_lon double precision, p_acc double precision, p_descriptor text, p_catatan text, p_address text, p_foto_base64 text, p_attendance_mode text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_emp public.karyawan;
  v_mode text := upper(coalesce(p_attendance_mode,''));
  v_today date := (timezone('Asia/Jakarta', now()))::date;
  v_branch text;
  v_office public.lokasi_kantor%ROWTYPE;
  v_pasuruan_office public.lokasi_kantor%ROWTYPE;
  v_pasuruan_distance double precision;
  v_distance double precision;
  v_outside boolean;
  v_area_marker text;
  v_clean_note text;
  v_submit_note text;
  v_result json;
BEGIN
  v_emp := public.session_karyawan(p_token);
  IF substring(coalesce(p_catatan,'') FROM '\[\[RHAREA=SBY\]\]') IS NOT NULL AND v_mode <> 'PIKET' THEN
    RAISE EXCEPTION 'Surabaya & Sekitarnya is not a Standby / Dinas Luar category.' USING ERRCODE = '22023';
  END IF;
  IF upper(coalesce(p_tipe,'')) <> 'MASUK' THEN
    RAISE EXCEPTION 'Mode Piket/Standby hanya berlaku untuk Clock In.' USING ERRCODE = '22023';
  END IF;
  IF v_mode NOT IN ('PIKET','STANDBY') THEN
    RAISE EXCEPTION 'Mode hari libur tidak valid.' USING ERRCODE = '22023';
  END IF;
  IF p_lat IS NULL OR p_lon IS NULL OR p_descriptor IS NULL OR p_acc IS NULL THEN
    RAISE EXCEPTION 'GPS dan verifikasi Face ID wajib tersedia.' USING ERRCODE = '22023';
  END IF;

  SELECT h.branch INTO v_branch
  FROM public.attendance_employee_branch_history h
  WHERE h.employee_id = v_emp.employee_id
    AND h.effective_from <= v_today
    AND (h.effective_to IS NULL OR h.effective_to >= v_today)
  ORDER BY h.effective_from DESC LIMIT 1;
  v_branch := coalesce(nullif(btrim(v_branch),''), nullif(btrim(v_emp.branch),''));
  SELECT * INTO v_office
  FROM public.lokasi_kantor l
  WHERE upper(btrim(l.branch)) = upper(btrim(coalesce(v_branch,'')))
    AND l.status = 'AKTIF'
  ORDER BY (l.branch = v_branch) DESC, l.updated_at DESC, l.branch
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Lokasi kantor aktif untuk branch % tidak ditemukan.', v_branch USING ERRCODE = '22023';
  END IF;
  v_distance := public.haversine_m(p_lat, p_lon, v_office.latitude, v_office.longitude);
  v_outside := v_distance > v_office.radius_m;

  -- PM's Pasuruan office is treated as an ordinary office for day-off mode too.
  IF upper(coalesce(v_emp.job_code,'')) = 'PM' THEN
    SELECT * INTO v_pasuruan_office
    FROM public.lokasi_kantor l
    WHERE lower(btrim(l.branch))='pasuruan' AND l.status='AKTIF'
    ORDER BY l.updated_at DESC,l.branch
    LIMIT 1;
    IF FOUND THEN
      v_pasuruan_distance := public.haversine_m(
        p_lat,p_lon,v_pasuruan_office.latitude,v_pasuruan_office.longitude
      );
      IF v_pasuruan_distance <= v_pasuruan_office.radius_m
         AND (v_outside OR v_pasuruan_distance < v_distance) THEN
        v_office := v_pasuruan_office;
        v_distance := v_pasuruan_distance;
        v_outside := FALSE;
      END IF;
    END IF;
  END IF;

  IF coalesce(p_acc,9999) > v_office.max_accuracy_m THEN
    RAISE EXCEPTION 'Akurasi GPS terlalu rendah (% m). Maksimal % m.', round(p_acc), v_office.max_accuracy_m USING ERRCODE = '22023';
  END IF;
  v_area_marker := substring(coalesce(p_catatan,'') FROM '\[\[RHAREA=(A1|A2|A3|A4|AX|SBY)\]\]');

  IF v_mode = 'STANDBY' AND NOT v_outside THEN
    RAISE EXCEPTION 'Standby hanya berlaku untuk karyawan yang dinas luar Area 1–5.' USING ERRCODE = '22023';
  END IF;
  IF v_mode = 'PIKET' AND v_outside AND v_area_marker IS NULL THEN
    RAISE EXCEPTION 'Piket dinas luar wajib memilih Area 1–5.' USING ERRCODE = '22023';
  END IF;
  IF v_mode = 'PIKET' AND NOT v_outside AND v_area_marker IS NOT NULL THEN
    RAISE EXCEPTION 'Piket kantor tidak boleh memilih area dinas luar.' USING ERRCODE = '22023';
  END IF;
  -- Strip only the untrusted RHATT marker before insert. Keep RHAREA in the
  -- submitted note so the existing area-validation trigger can parse it.
  v_submit_note := btrim(regexp_replace(coalesce(p_catatan,''),
    '[[:space:]]*\[\[RHATT=(P[1-5]?|SDL[1-5]|SDLL|DL[1-5])\]\][[:space:]]*', ' ', 'gi'));
  v_clean_note := btrim(regexp_replace(coalesce(v_submit_note,''),
    '[[:space:]]*\[\[RHAREA=(A1|A2|A3|A4|AX|SBY)\]\][[:space:]]*', ' ', 'gi'));
  IF v_outside AND nullif(v_clean_note,'') IS NULL THEN
    RAISE EXCEPTION 'Keterangan wajib diisi untuk Piket/Standby di luar kantor.' USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('app.reholz_dayoff_mode', v_mode, true);
  v_result := public.submit_attendance_with_photo(
    p_token, 'MASUK', p_lat, p_lon, p_acc, p_descriptor, v_submit_note, coalesce(p_address,''), p_foto_base64
  );
  PERFORM set_config('app.reholz_dayoff_mode', '', true);
  RETURN v_result;
END;
$function$


;

------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.hr_get_attendance_summary(p_token text, p_start_date date, p_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_emp public.karyawan;
  v_rows jsonb;
BEGIN
  v_emp := public.session_karyawan(p_token);
  IF UPPER(COALESCE(v_emp.role, '')) NOT IN ('HR','ADMIN','SUPERADMIN') THEN
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
      AND (k.contract_end_date IS NULL OR k.contract_end_date >= d.dt)
      AND (UPPER(COALESCE(k.status_akun,'')) = 'AKTIF' OR d.dt <= (k.updated_at AT TIME ZONE 'Asia/Jakarta')::date)
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
      COALESCE(
        MAX(a.area) FILTER (WHERE a.tipe='MASUK' AND COALESCE(a.outside_location,FALSE) IS TRUE),
        MAX(a.area) FILTER (WHERE a.tipe='PULANG' AND COALESCE(a.outside_location,FALSE) IS TRUE)
      ) AS event_area,
      BOOL_OR(COALESCE(a.outside_location,FALSE)) AS outside_any
    FROM public.absensi a
    WHERE a.tanggal BETWEEN p_start_date AND p_end_date
    GROUP BY a.employee_id, a.tanggal
  ), base AS (
    SELECT
      e.*,
      a.check_in,
      a.check_out,
      a.event_attendance_marker,
      a.event_area,
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
        WHEN outside_any AND event_area = 'Area 1' THEN 'DL1'
        WHEN outside_any AND event_area = 'Area 2' THEN 'DL2'
        WHEN outside_any AND event_area = 'Area 3' THEN 'DL3'
        WHEN outside_any AND event_area = 'Area 4' THEN 'DL4'
        WHEN outside_any AND event_area = 'Area lainnya' THEN 'DLL'
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
      (rule_is_workday AND day_type NOT IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF')) AS expected_workday,
      day_type AS calendar_day_type,
      CASE WHEN time_off_code='SDR' AND sick_outside_leave THEN sick_outside_area ELSE event_area END AS area,
      (outside_any OR (time_off_code='SDR' AND sick_outside_leave)) AS outside_location
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
$function$


;

------------------------------------------------------------------------------------------

-- public.hr_get_employee_attendance_history(p_token text, p_employee_id text, p_year integer, p_month integer)


CREATE OR REPLACE FUNCTION public.hris_incentive_calculate(p_start_date date, p_end_date date, p_employee_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_formula public.incentive_formula_versions%ROWTYPE;
  v_records jsonb;
  v_cfg jsonb;
  v_reimbursement_entertain_limit numeric(14,2);
  v_reimbursement_transport_limit numeric(14,2);
BEGIN
  IF p_start_date IS NULL OR p_end_date IS NULL OR p_start_date > p_end_date
     OR (p_end_date - p_start_date) > 62 THEN
    RAISE EXCEPTION 'Rentang periode insentif tidak valid (maksimal 63 hari inklusif).' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_formula
  FROM public.incentive_formula_versions
  WHERE effective_from <= p_end_date
  ORDER BY effective_from DESC, version_no DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Belum ada formula yang efektif untuk periode ini. Simpan formula backend terlebih dahulu.' USING ERRCODE = 'P0002';
  END IF;
  v_cfg := v_formula.config;
  SELECT entertain_limit,transport_limit INTO v_reimbursement_entertain_limit,v_reimbursement_transport_limit
  FROM public.incentive_reimbursement_limits WHERE id=1;

  WITH employees AS (
    SELECT k.employee_id, k.nama, k.branch, k.organization, k.job_position, k.job_code, k.bank_name, k.bank_account, k.join_date, k.contract_end_date
    FROM public.karyawan k
    WHERE k.status_akun = 'AKTIF'
      AND (p_employee_id IS NULL OR k.employee_id = p_employee_id)
  
      AND NOT EXISTS (
        SELECT 1
        FROM public.incentive_employee_exclusions AS exclusion
        WHERE exclusion.employee_id = k.employee_id
          AND exclusion.is_excluded = true
      )
), raw_events AS (
    SELECT a.*
    FROM public.absensi a
    JOIN employees e ON e.employee_id = a.employee_id
    WHERE a.tanggal BETWEEN p_start_date AND p_end_date
  ), daily0 AS (
    SELECT
      a.employee_id, a.tanggal,
      min(a.jam) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_in,
      max(a.jam) FILTER (WHERE a.tipe='PULANG' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_out,
      max(a.status_approval) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_in_status,
      max(a.status_approval) FILTER (WHERE a.tipe='PULANG' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_out_status,
      bool_or(a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS valid_clock_in,
      bool_or(a.tipe='PULANG' AND a.status_approval IN ('VALID','DISETUJUI')) AS valid_clock_out,
      bool_or(a.status_approval IN ('VALID','DISETUJUI')) AS any_final,
      bool_or(a.status_approval IN ('PENDING_ATASAN','PENDING_HR')) AS has_pending,
      bool_or(a.status_approval IN ('DITOLAK_ATASAN','DITOLAK_HR')) AS has_rejected,
      bool_or(a.outside_location) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_in_outside,
      bool_or(a.outside_location) FILTER (WHERE a.tipe='PULANG' AND a.status_approval IN ('VALID','DISETUJUI')) AS clock_out_outside,
      -- Prefer Clock In area, otherwise accept approved Clock Out area.
      COALESCE(
        max(a.area) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI') AND a.outside_location IS TRUE AND a.area IS NOT NULL),
        max(a.area) FILTER (WHERE a.tipe='PULANG' AND a.status_approval IN ('VALID','DISETUJUI') AND a.outside_location IS TRUE AND a.area IS NOT NULL)
      ) AS area,
      count(DISTINCT a.area) FILTER (WHERE a.tipe IN ('MASUK','PULANG') AND a.status_approval IN ('VALID','DISETUJUI') AND a.outside_location IS TRUE AND a.area IS NOT NULL) AS area_count,
      substring(max(a.catatan) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI'))
        FROM '\[\[RHATT=(P[1-5]?|SDL[1-5]|SDLL)\]\]') AS attendance_marker,
      max(a.punctuality_status) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS punctuality_status,
      max(a.scheduled_check_in_snapshot) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS scheduled_check_in,
      max(a.late_tolerance_minutes_snapshot) FILTER (WHERE a.tipe='MASUK' AND a.status_approval IN ('VALID','DISETUJUI')) AS late_tolerance_minutes,
      count(*) AS event_count,
      string_agg(DISTINCT a.status_approval, ', ' ORDER BY a.status_approval) AS statuses
    FROM raw_events a
    GROUP BY a.employee_id, a.tanggal
  ), sick_outside_days AS (
    SELECT c.employee_id::text AS employee_id, g.dt::date AS tanggal,
      NULL::time AS clock_in, NULL::time AS clock_out,
      NULL::text AS clock_in_status, NULL::text AS clock_out_status,
      FALSE AS valid_clock_in, FALSE AS valid_clock_out, FALSE AS any_final,
      FALSE AS has_pending, FALSE AS has_rejected,
      FALSE AS clock_in_outside, FALSE AS clock_out_outside,
      c.area_sakit::text AS area, 1::bigint AS area_count,
      NULL::text AS attendance_marker, NULL::text AS punctuality_status,
      NULL::time AS scheduled_check_in, NULL::integer AS late_tolerance_minutes,
      0::bigint AS event_count, 'APPROVED_SDR_DL'::text AS statuses,
      TRUE AS sick_outside
    FROM public.pengajuan_cuti c
    CROSS JOIN LATERAL generate_series(c.tanggal_mulai,c.tanggal_selesai,interval '1 day') g(dt)
    JOIN employees e ON e.employee_id=c.employee_id
    CROSS JOIN LATERAL (
      SELECT COALESCE((
        SELECT bh.branch
        FROM public.attendance_employee_branch_history bh
        WHERE bh.employee_id=c.employee_id
          AND bh.effective_from<=g.dt::date
          AND (bh.effective_to IS NULL OR bh.effective_to>=g.dt::date)
        ORDER BY bh.effective_from DESC LIMIT 1
      ), NULLIF(BTRIM(e.branch),''), 'Pusat') AS day_branch
    ) branch_at_day
    JOIN LATERAL (
      SELECT sr.is_workday
      FROM public.attendance_schedule_rules sr
      WHERE LOWER(BTRIM(sr.branch))=LOWER(BTRIM(branch_at_day.day_branch))
        AND sr.effective_from<=g.dt::date
        AND (sr.effective_to IS NULL OR sr.effective_to>=g.dt::date)
        AND (
          public.attendance_resolved_day_type(g.dt::date,branch_at_day.day_branch) NOT IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF')
          OR (EXTRACT(ISODOW FROM g.dt::date)::integer=7
              AND public.attendance_resolved_day_type(g.dt::date,branch_at_day.day_branch)='WORKING_DAY')
        )
        AND (
          sr.day_of_week=EXTRACT(ISODOW FROM g.dt::date)::integer
          OR (EXTRACT(ISODOW FROM g.dt::date)::integer=7
              AND public.attendance_resolved_day_type(g.dt::date,branch_at_day.day_branch)='WORKING_DAY'
              AND sr.day_of_week BETWEEN 1 AND 6 AND sr.is_workday=TRUE)
        )
        AND NOT (
          EXTRACT(ISODOW FROM g.dt::date)::integer=7
          AND public.attendance_resolved_day_type(g.dt::date,branch_at_day.day_branch)='WORKING_DAY'
          AND sr.day_of_week=7 AND sr.is_workday=FALSE
        )
      ORDER BY CASE WHEN sr.day_of_week=EXTRACT(ISODOW FROM g.dt::date)::integer THEN 0 ELSE 1 END,
               sr.effective_from DESC,sr.day_of_week
      LIMIT 1
    ) schedule_for_day ON schedule_for_day.is_workday=TRUE
    WHERE c.kode_cuti='SDR' AND c.dinas_luar_sakit IS TRUE
      AND c.area_sakit IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')
      AND c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI'
      AND g.dt::date BETWEEN p_start_date AND p_end_date
      AND NOT EXISTS (SELECT 1 FROM daily0 d WHERE d.employee_id=c.employee_id AND d.tanggal=g.dt::date)
  ), daily_seed AS (
    SELECT d.*,
      EXISTS (SELECT 1 FROM public.pengajuan_cuti c WHERE c.employee_id=d.employee_id
        AND c.kode_cuti='SDR' AND c.dinas_luar_sakit IS TRUE AND c.area_sakit IS NOT NULL
        AND c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI'
        AND c.tanggal_mulai<=d.tanggal AND c.tanggal_selesai>=d.tanggal) AS sick_outside,
      COALESCE((SELECT c.area_sakit FROM public.pengajuan_cuti c WHERE c.employee_id=d.employee_id
        AND c.kode_cuti='SDR' AND c.dinas_luar_sakit IS TRUE AND c.area_sakit IS NOT NULL
        AND c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI'
        AND c.tanggal_mulai<=d.tanggal AND c.tanggal_selesai>=d.tanggal
        ORDER BY c.tanggal_mulai DESC, c."timestamp" DESC LIMIT 1),d.area) AS effective_area
    FROM daily0 d
    UNION ALL
    SELECT sd.*, sd.area AS effective_area FROM sick_outside_days sd
  ), day0 AS (
    SELECT d.*,
      CASE WHEN d.sick_outside THEN TRUE
           WHEN d.effective_area='Surabaya & Sekitarnya' THEN FALSE
           ELSE (coalesce(d.clock_in_outside,false) OR coalesce(d.clock_out_outside,false)) END AS outside_flag,
      EXISTS (
        SELECT 1 FROM public.pengajuan_cuti c
        WHERE c.employee_id=d.employee_id
          AND c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI'
          AND c.tanggal_mulai <= d.tanggal AND c.tanggal_selesai >= d.tanggal
          AND NOT (d.sick_outside AND c.kode_cuti='SDR' AND c.dinas_luar_sakit IS TRUE AND c.area_sakit=d.effective_area)
      ) AS timeoff_conflict
    FROM daily_seed d
  ), classified AS (
    SELECT d.*,
      CASE
        WHEN d.sick_outside AND d.effective_area='Area 1' THEN 'SDR-DL1'
        WHEN d.sick_outside AND d.effective_area='Area 2' THEN 'SDR-DL2'
        WHEN d.sick_outside AND d.effective_area='Area 3' THEN 'SDR-DL3'
        WHEN d.sick_outside AND d.effective_area='Area 4' THEN 'SDR-DL4'
        WHEN d.sick_outside AND d.effective_area='Area lainnya' THEN 'SDR-DLL'
        WHEN d.attendance_marker IS NOT NULL THEN d.attendance_marker
        WHEN d.outside_flag AND d.effective_area='Area 1' THEN 'DL1'
        WHEN d.outside_flag AND d.effective_area='Area 2' THEN 'DL2'
        WHEN d.outside_flag AND d.effective_area='Area 3' THEN 'DL3'
        WHEN d.outside_flag AND d.effective_area='Area 4' THEN 'DL4'
        WHEN d.outside_flag AND d.effective_area='Area lainnya' THEN 'DL5'
        WHEN d.any_final THEN 'H'
        ELSE '—'
      END AS attendance_code,
      CASE d.effective_area
        WHEN 'Area 1' THEN 'AREA 1' WHEN 'Area 2' THEN 'AREA 2'
        WHEN 'Area 3' THEN 'AREA 3' WHEN 'Area 4' THEN 'AREA 4'
        WHEN 'Area lainnya' THEN 'AREA LAIN' ELSE NULL END AS area_rate_key,
      CASE
        WHEN d.punctuality_status IN ('EARLY','ON_TIME') THEN TRUE
        WHEN d.punctuality_status='LATE' THEN FALSE
        WHEN d.clock_in IS NOT NULL AND d.scheduled_check_in IS NOT NULL
          AND d.late_tolerance_minutes IS NOT NULL
          THEN d.clock_in <= (d.scheduled_check_in + make_interval(mins => d.late_tolerance_minutes))::time
        ELSE FALSE
      END AS on_time_by_snapshot
    FROM day0 d
  ), rated AS (
    SELECT c.*,
      CASE WHEN c.sick_outside OR (c.attendance_code IN ('SDL1','SDL2','SDL3','SDL4','SDL5','SDLL')
                 AND coalesce((v_cfg->'eligibility'->>'standby_as_outside')::boolean,true))
          OR (c.outside_flag AND c.attendance_code IN ('DL1','DL2','DL3','DL4','DL5'))
        THEN NULLIF(v_cfg->'outside_rates'->c.area_rate_key->>upper(coalesce(e.job_code,'')),'')::numeric
        ELSE NULL END AS outside_rate,
      (NOT c.sick_outside AND (c.attendance_marker = 'P' OR c.attendance_marker IN ('P1','P2','P3','P4','P5'))) AS is_picket,
      (NOT c.sick_outside AND c.attendance_marker IN ('SDL1','SDL2','SDL3','SDL4','SDL5','SDLL')) AS is_standby,
      (c.any_final AND NOT c.timeoff_conflict AND NOT c.sick_outside) AS attendance_eligible,
      (c.any_final AND NOT c.timeoff_conflict AND NOT c.sick_outside AND NOT c.outside_flag
        AND coalesce(c.attendance_marker,'') NOT IN ('P1','P2','P3','P4','P5','SDL1','SDL2','SDL3','SDL4','SDL5','SDLL')) AS transport_eligible,
      (c.any_final AND NOT c.timeoff_conflict AND NOT c.sick_outside) AS phone_eligible,
      (c.valid_clock_in AND NOT c.timeoff_conflict AND NOT c.sick_outside AND NOT c.outside_flag
        AND c.on_time_by_snapshot) AS meal_eligible,
      ((c.sick_outside OR c.any_final) AND NOT c.timeoff_conflict AND (c.sick_outside OR c.area_count <= 1)
        AND (c.sick_outside OR c.outside_flag) AND c.area_rate_key IS NOT NULL
        AND (c.sick_outside OR c.attendance_code IN ('DL1','DL2','DL3','DL4','DL5')
          OR (c.attendance_code IN ('SDL1','SDL2','SDL3','SDL4','SDL5','SDLL')
            AND coalesce((v_cfg->'eligibility'->>'standby_as_outside')::boolean,true)))) AS outside_eligible,
      CASE
        WHEN NOT c.sick_outside AND c.clock_in IS NOT NULL AND c.clock_out IS NOT NULL AND c.clock_out > c.clock_in
         AND c.clock_in_status='DISETUJUI' AND c.clock_out_status IN ('VALID','DISETUJUI')
         AND NOT c.timeoff_conflict AND c.area_count <= 1
         AND ((c.attendance_marker='P' AND (NOT coalesce(c.clock_in_outside,false) OR c.effective_area='Surabaya & Sekitarnya'))
           OR (c.attendance_marker IN ('P1','P2','P3','P4','P5') AND coalesce(c.clock_in_outside,false)))
        THEN CASE
          WHEN floor(extract(epoch FROM (c.clock_out-c.clock_in))/3600)::integer >= coalesce((v_cfg->>'piket_min_hours')::integer,4)
          THEN least(coalesce((v_cfg->>'piket_max_hours')::integer,8),
               floor(extract(epoch FROM (c.clock_out-c.clock_in))/3600)::integer)
          ELSE 0
        END
        ELSE 0
      END AS picket_paid_hours
    FROM classified c
    JOIN employees e ON e.employee_id=c.employee_id
  ), daily_calc AS (
    SELECT r.*, e.nama, e.branch, e.organization, e.job_position, e.job_code,
      CASE WHEN r.meal_eligible THEN
        CASE WHEN upper(coalesce(e.job_code,''))='OB' THEN coalesce((v_cfg->>'meal_ob')::numeric,0)
             ELSE coalesce((v_cfg->>'meal_other')::numeric,0) END
      ELSE 0 END AS meal_amount_day,
      CASE WHEN r.outside_eligible AND r.outside_rate IS NOT NULL THEN r.outside_rate ELSE 0 END AS outside_amount_day,
      CASE WHEN r.is_picket AND r.picket_paid_hours >= coalesce((v_cfg->>'piket_min_hours')::integer,4)
        THEN r.picket_paid_hours * coalesce((v_cfg->>'piket_hourly_rate')::numeric,15000) ELSE 0 END AS picket_amount_day,
      (r.is_picket AND r.picket_paid_hours >= coalesce((v_cfg->>'piket_min_hours')::integer,4)) AS picket_eligible,
      array_remove(ARRAY[
        CASE WHEN r.timeoff_conflict THEN 'Konflik: ada absensi pada tanggal Time Off final; hari dikecualikan.' END,
        CASE WHEN r.area_count > 1 AND NOT r.sick_outside THEN 'Konflik area: lebih dari satu Area pada tanggal yang sama; tarif area dan Piket dikecualikan.' END,
        CASE WHEN r.has_pending THEN 'Ada event absensi yang masih menunggu approval; event pending tidak dihitung.' END,
        CASE WHEN r.has_rejected THEN 'Ada event absensi yang ditolak; event tersebut tidak dihitung.' END,
        CASE WHEN r.outside_flag AND NOT r.sick_outside AND r.area IS NULL THEN 'Dinas luar tanpa Area tervalidasi pada Clock In/Clock Out; tarif DL tidak dihitung.' END,
        CASE WHEN r.sick_outside AND (r.outside_rate IS NULL OR r.outside_rate <= 0) THEN 'Tarif SDR-DL belum aktif: periksa kombinasi Area dan Kode Jabatan pada Formula Insentif.' END,
        CASE WHEN r.outside_eligible AND (r.outside_rate IS NULL OR r.outside_rate <= 0) THEN 'Tarif DL untuk kombinasi Area/Job Code kosong atau nol; nominal tidak dibayarkan.' END,
        CASE WHEN r.valid_clock_in AND r.clock_in IS NOT NULL AND r.punctuality_status IS NULL AND r.scheduled_check_in IS NULL THEN 'Uang makan tidak dihitung: snapshot jadwal masuk tidak tersedia.' END,
        CASE WHEN r.is_picket AND (r.clock_in IS NULL OR r.clock_out IS NULL) THEN 'Piket belum memiliki pasangan Clock In dan Clock Out; jam Piket belum dapat dihitung.' END,
        CASE WHEN r.is_picket AND r.clock_in IS NOT NULL AND r.clock_out IS NOT NULL AND r.clock_out <= r.clock_in THEN 'Durasi Piket tidak valid: Clock Out tidak setelah Clock In.' END,
        CASE WHEN r.is_picket AND r.clock_in IS NOT NULL AND r.clock_out IS NOT NULL AND r.clock_out > r.clock_in
          AND r.picket_paid_hours < coalesce((v_cfg->>'piket_min_hours')::integer,4) THEN 'Durasi Piket di bawah 4 jam; nominal Piket Rp0.' END,
        CASE WHEN r.is_picket AND r.clock_in_status IS DISTINCT FROM 'DISETUJUI' THEN 'Piket belum mendapat persetujuan final; nominal Piket tidak dihitung.' END,
        CASE WHEN nullif(btrim(e.job_code),'') IS NULL AND r.outside_flag THEN 'Job Code kosong; tarif dinas luar tidak dihitung.' END
      ], NULL) AS day_warnings
    FROM rated r JOIN employees e ON e.employee_id=r.employee_id
  ), period_calendar_base AS (
    SELECT e.employee_id, g.dt::date AS tanggal,
      COALESCE((
        SELECT bh.branch
        FROM public.attendance_employee_branch_history bh
        WHERE bh.employee_id=e.employee_id
          AND bh.effective_from<=g.dt::date
          AND (bh.effective_to IS NULL OR bh.effective_to>=g.dt::date)
        ORDER BY bh.effective_from DESC LIMIT 1
      ), NULLIF(BTRIM(e.branch),''), 'Pusat') AS day_branch
    FROM employees e
    CROSS JOIN LATERAL generate_series(p_start_date,p_end_date,interval '1 day') g(dt)
    WHERE (e.join_date IS NULL OR g.dt::date>=e.join_date)
      AND (e.contract_end_date IS NULL OR g.dt::date<=e.contract_end_date)
  ), period_calendar AS (
    SELECT b.employee_id, b.tanggal, b.day_branch,
      public.attendance_resolved_day_type(b.tanggal,b.day_branch) AS day_type,
      COALESCE(schedule_for_day.is_workday,FALSE)
        AND public.attendance_resolved_day_type(b.tanggal,b.day_branch)
          NOT IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF') AS is_workday,
      (schedule_for_day.is_workday IS NOT NULL) AS schedule_known
    FROM period_calendar_base b
    LEFT JOIN LATERAL (
      SELECT sr.is_workday
      FROM public.attendance_schedule_rules sr
      WHERE LOWER(BTRIM(sr.branch))=LOWER(BTRIM(b.day_branch))
        AND sr.effective_from<=b.tanggal
        AND (sr.effective_to IS NULL OR sr.effective_to>=b.tanggal)
        AND (
          public.attendance_resolved_day_type(b.tanggal,b.day_branch) NOT IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF')
          OR (EXTRACT(ISODOW FROM b.tanggal)::integer=7
              AND public.attendance_resolved_day_type(b.tanggal,b.day_branch)='WORKING_DAY')
        )
        AND (
          sr.day_of_week=EXTRACT(ISODOW FROM b.tanggal)::integer
          OR (EXTRACT(ISODOW FROM b.tanggal)::integer=7
              AND public.attendance_resolved_day_type(b.tanggal,b.day_branch)='WORKING_DAY'
              AND sr.day_of_week BETWEEN 1 AND 6 AND sr.is_workday=TRUE)
        )
        AND NOT (
          EXTRACT(ISODOW FROM b.tanggal)::integer=7
          AND public.attendance_resolved_day_type(b.tanggal,b.day_branch)='WORKING_DAY'
          AND sr.day_of_week=7 AND sr.is_workday=FALSE
        )
      ORDER BY CASE WHEN sr.day_of_week=EXTRACT(ISODOW FROM b.tanggal)::integer THEN 0 ELSE 1 END,
               sr.effective_from DESC,sr.day_of_week
      LIMIT 1
    ) schedule_for_day ON TRUE
  ), period_day_flags AS (
    SELECT pc.employee_id, pc.tanggal, pc.day_branch, pc.day_type, pc.is_workday, pc.schedule_known,
      COALESCE(att.outside_attendance,FALSE) OR COALESCE(sick.sick_outside,FALSE) AS outside_day,
      COALESCE(att.home_branch_attendance,FALSE) AS home_return_day,
      COALESCE(att.special_dayoff_marker,FALSE) AS special_dayoff_marker,
      COALESCE(sick.sick_outside,FALSE) AS sick_outside_day
    FROM period_calendar pc
    LEFT JOIN LATERAL (
      SELECT
        BOOL_OR(a.status_approval IN ('VALID','DISETUJUI') AND a.outside_location IS TRUE
          AND a.area IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')) AS outside_attendance,
        BOOL_OR(a.status_approval IN ('VALID','DISETUJUI')
          AND NULLIF(BTRIM(a.branch_target),'') IS NOT NULL
          AND LOWER(BTRIM(a.branch_target))=LOWER(BTRIM(pc.day_branch))
          AND COALESCE(a.outside_location,FALSE)=FALSE) AS home_branch_attendance,
        BOOL_OR(a.status_approval IN ('VALID','DISETUJUI')
          AND substring(COALESCE(a.catatan,'') FROM '\[\[RHATT=(P[1-5]?|SDL[1-5]|SDLL)\]\]') IS NOT NULL) AS special_dayoff_marker
      FROM raw_events a
      WHERE a.employee_id=pc.employee_id AND a.tanggal=pc.tanggal
    ) att ON TRUE
    LEFT JOIN LATERAL (
      SELECT EXISTS (
        SELECT 1 FROM public.pengajuan_cuti c
        WHERE c.employee_id=pc.employee_id AND c.kode_cuti='SDR'
          AND c.dinas_luar_sakit IS TRUE
          AND c.area_sakit IN ('Area 1','Area 2','Area 3','Area 4','Area lainnya')
          AND c.status_atasan='DISETUJUI' AND c.status_hr='DISETUJUI'
          AND c.tanggal_mulai<=pc.tanggal AND c.tanggal_selesai>=pc.tanggal
      ) AS sick_outside
    ) sick ON TRUE
  ), employee_period_flags AS (
    SELECT e.employee_id,
      COUNT(*) FILTER (WHERE f.is_workday) AS scheduled_work_days,
      COUNT(*) FILTER (WHERE f.is_workday AND f.outside_day) AS outside_work_days,
      BOOL_OR(f.home_return_day) AS returned_home,
      COALESCE(jsonb_agg(jsonb_build_object(
        'date',f.tanggal,'workday',f.is_workday,
        'sick_outside',f.sick_outside_day,
        'outside_day',f.outside_day,
        'home_return',f.home_return_day,
        'standby_or_picket',f.special_dayoff_marker
      ) ORDER BY f.tanggal) FILTER (
        WHERE f.is_workday
           OR (NOT f.is_workday AND (f.special_dayoff_marker OR f.sick_outside_day))
      ),'[]'::jsonb) AS family_trip_dates,
      COUNT(*) FILTER (WHERE NOT f.is_workday AND (f.special_dayoff_marker OR f.sick_outside_day)) AS special_off_days,
      COUNT(*) FILTER (WHERE f.day_type NOT IN ('SUNDAY','NATIONAL_HOLIDAY','DAY_OFF') AND NOT f.schedule_known) AS schedule_unknown_days
    FROM employees e
    LEFT JOIN period_day_flags f ON f.employee_id=e.employee_id
    GROUP BY e.employee_id
  ), pm_pasuruan_daily AS (
    SELECT a.employee_id, a.tanggal
    FROM raw_events a
    JOIN employees e ON e.employee_id=a.employee_id
    WHERE UPPER(COALESCE(e.job_code,''))='PM'
      AND LOWER(BTRIM(COALESCE(a.branch_target,'')))='pasuruan'
      AND a.status_approval IN ('VALID','DISETUJUI')
      AND COALESCE(a.outside_location,FALSE)=FALSE
      AND a.tipe IN ('MASUK','PULANG')
    GROUP BY a.employee_id,a.tanggal
  ), pm_pasuruan_period AS (
    SELECT e.employee_id,
      COUNT(p.tanggal)::integer AS pasuruan_days,
      COALESCE(jsonb_agg(p.tanggal ORDER BY p.tanggal) FILTER (WHERE p.tanggal IS NOT NULL),'[]'::jsonb) AS pasuruan_dates
    FROM employees e
    LEFT JOIN pm_pasuruan_daily p ON p.employee_id=e.employee_id
    GROUP BY e.employee_id
  ), per_employee AS (
    SELECT e.employee_id, e.nama, e.branch, e.organization, e.job_position, e.job_code, e.bank_name, e.bank_account,
      count(*) FILTER (WHERE d.attendance_eligible) AS attendance_days,
      count(*) FILTER (WHERE d.meal_eligible) AS punctual_days,
      coalesce(sum(d.meal_amount_day),0)::numeric(18,0) AS meal_amount,
      count(*) FILTER (WHERE d.transport_eligible) AS transport_days,
      CASE WHEN count(*) FILTER (WHERE d.transport_eligible) >= coalesce((v_cfg->>'transport_threshold')::integer,25)
        THEN coalesce((v_cfg->>'transport_cap')::numeric,0)
        ELSE (count(*) FILTER (WHERE d.transport_eligible) * coalesce((v_cfg->>'transport_daily')::numeric,0)) END::numeric(18,0) AS transport_amount,
      count(*) FILTER (WHERE d.phone_eligible) AS phone_days,
      CASE WHEN count(*) FILTER (WHERE d.phone_eligible) >= coalesce((v_cfg->>'phone_threshold')::integer,25)
        THEN coalesce((v_cfg->>'phone_cap')::numeric,0)
        ELSE (count(*) FILTER (WHERE d.phone_eligible) * coalesce((v_cfg->>'phone_daily')::numeric,0)) END::numeric(18,0) AS phone_amount,
      count(*) FILTER (WHERE d.outside_eligible) AS outside_days,
      coalesce(sum(d.outside_amount_day),0)::numeric(18,0) AS outside_amount,
      coalesce(sum(d.outside_amount_day) FILTER (WHERE d.area_rate_key='AREA 1'),0)::numeric(18,0) AS area_1_amount,
      coalesce(sum(d.outside_amount_day) FILTER (WHERE d.area_rate_key='AREA 2'),0)::numeric(18,0) AS area_2_amount,
      coalesce(sum(d.outside_amount_day) FILTER (WHERE d.area_rate_key='AREA 3'),0)::numeric(18,0) AS area_3_amount,
      coalesce(sum(d.outside_amount_day) FILTER (WHERE d.area_rate_key='AREA 4'),0)::numeric(18,0) AS area_4_amount,
      coalesce(sum(d.outside_amount_day) FILTER (WHERE d.area_rate_key='AREA LAIN'),0)::numeric(18,0) AS area_lain_amount,
      count(*) FILTER (WHERE d.picket_eligible) AS picket_days,
      coalesce(sum(d.picket_paid_hours),0) AS picket_hours,
      coalesce(sum(d.picket_amount_day),0)::numeric(18,0) AS picket_amount,
      CASE WHEN COALESCE(epf.scheduled_work_days,0)>0
        AND epf.outside_work_days=epf.scheduled_work_days
        AND COALESCE(epf.schedule_unknown_days,0)=0
        AND COALESCE(epf.returned_home,FALSE)=FALSE
        THEN 360000 ELSE 0 END::numeric(18,0) AS family_trip_amount,
      CASE WHEN UPPER(COALESCE(e.job_code,''))='PM' AND COALESCE(pp.pasuruan_days,0)>4
        THEN pp.pasuruan_days*80000 ELSE 0 END::numeric(18,0) AS extra_transport_amount,
      COALESCE(epf.scheduled_work_days,0) AS family_trip_scheduled_work_days,
      COALESCE(epf.outside_work_days,0) AS family_trip_outside_work_days,
      COALESCE(epf.returned_home,FALSE) AS returned_home,
      COALESCE(epf.family_trip_dates,'[]'::jsonb) AS family_trip_dates,
      COALESCE(epf.special_off_days,0) AS family_trip_special_off_days,
      COALESCE(epf.schedule_unknown_days,0) AS family_trip_schedule_unknown_days,
      COALESCE(pp.pasuruan_days,0) AS extra_transport_days,
      COALESCE(pp.pasuruan_dates,'[]'::jsonb) AS extra_transport_dates,
      coalesce(jsonb_agg(jsonb_build_object(
        'date', d.tanggal,
        'attendance_code', d.attendance_code,
        'clock_in', d.clock_in,
        'clock_out', d.clock_out,
        'clock_in_status', d.clock_in_status,
        'clock_out_status', d.clock_out_status,
        'area', d.effective_area,
        'outside_location', (coalesce(d.clock_in_outside,false) OR coalesce(d.clock_out_outside,false)),
        'punctuality_status', d.punctuality_status,
        'scheduled_check_in', d.scheduled_check_in,
        'late_tolerance_minutes', d.late_tolerance_minutes,
        'meal_eligible', d.meal_eligible,
        'meal_amount', d.meal_amount_day,
        'transport_eligible', d.transport_eligible,
        'phone_eligible', d.phone_eligible,
        'outside_eligible', d.outside_eligible,
        'outside_rate_key', d.area_rate_key,
        'outside_job_code', e.job_code,
        'outside_rate', d.outside_rate,
        'outside_rate_configured', (d.outside_rate IS NOT NULL AND d.outside_rate > 0),
        'outside_amount', d.outside_amount_day,
        'picket_hours_paid', d.picket_paid_hours,
        'picket_amount', d.picket_amount_day,
        'warnings', to_jsonb(d.day_warnings)
      ) ORDER BY d.tanggal) FILTER (WHERE d.event_count > 0 OR d.sick_outside), '[]'::jsonb) AS details,
      coalesce(jsonb_agg(jsonb_build_object('date',d.tanggal,'warnings',to_jsonb(d.day_warnings)) ORDER BY d.tanggal)
        FILTER (WHERE cardinality(d.day_warnings)>0), '[]'::jsonb) AS warnings
    FROM employees e
    LEFT JOIN daily_calc d ON d.employee_id=e.employee_id
    LEFT JOIN employee_period_flags epf ON epf.employee_id=e.employee_id
    LEFT JOIN pm_pasuruan_period pp ON pp.employee_id=e.employee_id
    GROUP BY e.employee_id, e.nama, e.branch, e.organization, e.job_position, e.job_code,
      e.bank_name, e.bank_account, epf.scheduled_work_days, epf.outside_work_days,
      epf.returned_home, epf.family_trip_dates, epf.special_off_days, epf.schedule_unknown_days,
      pp.pasuruan_days, pp.pasuruan_dates
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'employee_id', x.employee_id,
    'nama', x.nama,
    'branch', x.branch,
    'organization', x.organization,
    'job_position', x.job_position,
    'job_code', x.job_code,
    'bank_name', x.bank_name,
    'bank_account', x.bank_account,
    'attendance_days', x.attendance_days,
    'punctual_days', x.punctual_days,
    'meal_days', x.punctual_days,
    'meal_amount', x.meal_amount,
    'transport_days', x.transport_days,
    'transport_amount', x.transport_amount,
    'phone_days', x.phone_days,
    'phone_amount', x.phone_amount,
    'outside_days', x.outside_days,
    'outside_amount', x.outside_amount,
    'area_1_amount', x.area_1_amount,
    'area_2_amount', x.area_2_amount,
    'area_3_amount', x.area_3_amount,
    'area_4_amount', x.area_4_amount,
    'area_lain_amount', x.area_lain_amount,
    'family_trip_amount', x.family_trip_amount,
    'extra_transport_amount', x.extra_transport_amount,
    'underpayment_last_month_amount', COALESCE((
      SELECT u.amount
      FROM public.incentive_underpayments u
      WHERE u.employee_id=x.employee_id
        AND u.period_start=p_start_date
        AND u.period_end=p_end_date
      LIMIT 1
    ),0),
    'reimbursement_entertain_amount', COALESCE((
      SELECT SUM(a.amount) FROM public.hr_reimbursement_requests a
      WHERE a.employee_id=x.employee_id AND upper(coalesce(x.job_code,''))='HYBRID' AND a.category='ENTERTAIN'
        AND a.period_start=p_start_date AND a.period_end=p_end_date
        AND a.status='DISETUJUI'
    ),0),
    'reimbursement_transport_amount', COALESCE((
      SELECT SUM(a.amount) FROM public.hr_reimbursement_requests a
      WHERE a.employee_id=x.employee_id AND upper(coalesce(x.job_code,''))='HYBRID' AND a.category='TRANSPORT'
        AND a.period_start=p_start_date AND a.period_end=p_end_date
        AND a.status='DISETUJUI'
    ),0),
    'reimbursement_over_budget_amount',
      GREATEST(0,COALESCE((SELECT SUM(a.amount) FROM public.hr_reimbursement_requests a
        WHERE a.employee_id=x.employee_id AND upper(coalesce(x.job_code,''))='HYBRID' AND a.category='ENTERTAIN'
          AND a.period_start=p_start_date AND a.period_end=p_end_date AND a.status='DISETUJUI'),0)-v_reimbursement_entertain_limit)
      + GREATEST(0,COALESCE((SELECT SUM(a.amount) FROM public.hr_reimbursement_requests a
        WHERE a.employee_id=x.employee_id AND upper(coalesce(x.job_code,''))='HYBRID' AND a.category='TRANSPORT'
          AND a.period_start=p_start_date AND a.period_end=p_end_date AND a.status='DISETUJUI'),0)-v_reimbursement_transport_limit),
    'picket_days', x.picket_days,
    'picket_hours', x.picket_hours,
    'picket_amount', x.picket_amount,
    'family_trip_scheduled_work_days', x.family_trip_scheduled_work_days,
    'family_trip_outside_work_days', x.family_trip_outside_work_days,
    'family_trip_returned_home', x.returned_home,
    'family_trip_dates', x.family_trip_dates,
    'family_trip_special_off_days', x.family_trip_special_off_days,
    'family_trip_schedule_unknown_days', x.family_trip_schedule_unknown_days,
    'extra_transport_days', x.extra_transport_days,
    'extra_transport_dates', x.extra_transport_dates,
    'extra_amount', 0,
    'total_amount',
      COALESCE(x.meal_amount,0)+COALESCE(x.transport_amount,0)+COALESCE(x.phone_amount,0)
      +COALESCE(x.outside_amount,0)+COALESCE(x.picket_amount,0)+COALESCE(x.family_trip_amount,0)
      +COALESCE(x.extra_transport_amount,0)
      +COALESCE((SELECT SUM(a.amount) FROM public.hr_reimbursement_requests a
        WHERE a.employee_id=x.employee_id AND upper(coalesce(x.job_code,''))='HYBRID' AND a.period_start=p_start_date AND a.period_end=p_end_date
          AND a.status='DISETUJUI'),0)
      +COALESCE((SELECT u.amount FROM public.incentive_underpayments u
        WHERE u.employee_id=x.employee_id AND u.period_start=p_start_date AND u.period_end=p_end_date LIMIT 1),0),
    'details', x.details,
    'warnings', x.warnings
  ) ORDER BY x.nama), '[]'::jsonb) INTO v_records
  FROM per_employee x;

  RETURN jsonb_build_object(
    'ok', true,
    'period', jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'timezone','Asia/Jakarta'),
    'formula', jsonb_build_object('version',v_formula.version_no,'effective_from',v_formula.effective_from,'config',v_formula.config),
    'records', v_records
  );
END;
$function$


;

------------------------------------------------------------------------------------------

COMMIT;
