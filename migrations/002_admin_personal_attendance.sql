-- ReHolz Tahap 4 Paket B — Admin dapat melakukan presensi pribadi.
-- This only removes the role-level attendance prohibition. The session, GPS,
-- face verification, approval pipeline, and trigger checks remain in force.
BEGIN;
CREATE OR REPLACE FUNCTION public.submit_attendance_with_photo(p_token text, p_tipe text, p_lat double precision, p_lon double precision, p_acc double precision, p_descriptor text, p_catatan text, p_address text, p_foto_base64 text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_emp public.karyawan;
BEGIN
  v_emp := public.session_karyawan(p_token);
  RETURN public.submit_attendance_with_photo__v12_internal(
    p_token => p_token,
    p_tipe => p_tipe,
    p_lat => p_lat,
    p_lon => p_lon,
    p_acc => p_acc,
    p_descriptor => p_descriptor,
    p_catatan => p_catatan,
    p_address => p_address,
    p_foto_base64 => p_foto_base64
  );
END;
$function$;
COMMIT;
