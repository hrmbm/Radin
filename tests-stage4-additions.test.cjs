'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const root = __dirname;
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const sw = fs.readFileSync(path.join(root, 'sw.js'), 'utf8');
const migrationA = fs.readFileSync(path.join(root, 'migrations/001_area_surabaya_sekitarnya.sql'), 'utf8');
const migrationB = fs.existsSync(path.join(root, 'migrations/002_admin_personal_attendance.sql')) ? fs.readFileSync(path.join(root, 'migrations/002_admin_personal_attendance.sql'), 'utf8') : '';
let passed = 0, failed = 0;
function check(name, fn) {
  let ok = false; try { ok = typeof fn === 'function' ? !!fn() : !!fn; } catch (e) { ok = false; }
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`); if (ok) passed++; else failed++;
}
function between(start, end) { const a=html.indexOf(start), b=html.indexOf(end,a); return a>=0&&b>a?html.slice(a,b):''; }

// A — Surabaya & Sekitarnya is a location setting, not a new attendance code.
check('normal attendance area selector shows Surabaya & Sekitarnya by display name', /<option value="Surabaya &amp; Sekitarnya">Surabaya &amp; Sekitarnya<\/option>/.test(html));
check('Piket area is displayed by its exact name without an attendance-code suffix', /Surabaya &amp; Sekitarnya<\/option>/.test(html) && !/Surabaya &amp; Sekitarnya \(P\)/.test(html));
check('Standby selector deliberately does not include Surabaya & Sekitarnya', (() => { const i=html.indexOf("ATT.dayOffChoice === 'STANDBY'"); const j=html.indexOf("ATT.dayOffChoice === 'PIKET'",i); const t=html.slice(i,j); return t && !/Surabaya &amp; Sekitarnya/.test(t); })());
check('internal SBY marker is not a display attendance code', /n===6\)return mode==='PIKET'\?'P':''/.test(html) && /ordinary office code P/.test(html));
check('SBY location is accepted from saved Clock In and reused on Clock Out', /Surabaya & Sekitarnya'\]\.indexOf\(value\.area\)/.test(html) && /ATT\.areaLock/.test(html));
check('normal and Piket submit accept SBY but Standby submit rejects it', /areaCode === 'SBY' && ATT\.dayOffChoice === 'STANDBY'/.test(html));
check('area label normalization is case-safe after lowercasing', /var area=String\(attMonFirst\(x,\['area','attendance_area','work_area','lokasi_area'\]\)\|\|''\)\.toLowerCase\(\);[\s\S]{0,520}area === 'surabaya & sekitarnya' \|\| area === 'sby'/.test(html));
check('attendance recap/export location column is derived by the shared label helper', /key==='location_setting_name'\) v=attMonLocationSetting\(x\)/.test(html) && /attMonLocationSetting\(x\),/.test(html));
check('summary attendance code remains H for normal SBY attendance', /if\(areaMarker==='SBY'\|\|area==='SURABAYA & SEKITARNYA'\)\{return \(hasCheckIn\|\|hasCheckOut\)\?'H':'—';\}/.test(html));
check('no display/report variants SDR-SBY, PSBY or DLSBY were introduced', !/(SDR-SBY|PSBY|DLSBY)/i.test(html + migrationA));
check('database stores the display area name and still validates GPS outside active radius', /WHEN 'SBY' THEN 'Surabaya & Sekitarnya'/.test(migrationA) && /v_outside := NEW\.distance_m > v_radius/.test(migrationA) && /IF v_area_code IS NOT NULL AND v_distance_is_verifiable AND NOT v_outside THEN/.test(migrationA));
check('report payload preserves raw GPS outside state while allowance logic remains office-equivalent', /'outside_location', \(coalesce\(d\.clock_in_outside,false\) OR coalesce\(d\.clock_out_outside,false\)\)/.test(migrationA) && /WHEN d.effective_area='Surabaya & Sekitarnya' THEN FALSE/.test(migrationA));
check('database check constraint accepts the new display location only', /'Surabaya & Sekitarnya'::text/.test(migrationA) && !/SDR-SBY|PSBY|DLSBY/.test(migrationA));
check('server day-off guard assigns P for SBY Piket and blocks SBY in Standby', /WHEN 'Surabaya & Sekitarnya' THEN 0/.test(migrationA) && /WHEN v_area_no = 0 THEN 'P'/.test(migrationA) && /v_area_no NOT BETWEEN 1 AND 5/.test(migrationA) && /v_mode <> 'PIKET'/.test(migrationA));
check('Piket code and Piket hour calculation treat SBY as Surabaya office-equivalent', /WHEN v_area_no = 0 THEN 'P'/.test(migrationA) && /c\.effective_area='Surabaya & Sekitarnya'/.test(migrationA));
check('incentive calculation excludes SBY from Dinas Luar flag while retaining normal attendance eligibility', /WHEN d\.effective_area='Surabaya & Sekitarnya' THEN FALSE/.test(migrationA) && /AS outside_flag/.test(migrationA));
check('HR attendance summary preserves explicit P marker and reports ordinary H for SBY normal work', /WHEN event_attendance_marker IN \('P','P1','P2','P3','P4','PL'\) THEN event_attendance_marker/.test(migrationA) && /WHEN event_area = 'Surabaya & Sekitarnya' AND check_in IS NOT NULL THEN 'H'/.test(migrationA));

// B — Admin remains administratively read-only but can clock in/out personally.
const startAttendance = between('async function startAttendance(type) {', 'function rhReadLocalClockOutMode');
const submitAttendance = between('async function submitAttendance() {', 'function finishAttendance');
check('Admin is not blocked by the personal Clock In entry point', !/isAdminReadOnly\(\)/.test(startAttendance));
check('Admin is not blocked by the personal Clock Out/submit entry point', !/isAdminReadOnly\(\)/.test(submitAttendance));
check('Admin generic API guard no longer blocks simpanAbsensi', /if \(fn === 'simpanAbsensi'\)/.test(html) && !/\^\(simpanAbsensi\|submitCuti/.test(html));
check('Admin optional RPC guard no longer blocks submit_attendance_with_photo', /\^\(submit_cuti\|process_approval/.test(html) && !/\^\(submit_attendance_with_photo/.test(html));
check('Admin read-only notice explains personal attendance remains available', /Akses Admin hanya untuk melihat data administrasi\. Clock In dan Clock Out pribadi tetap tersedia\./.test(html));
check('database Admin attendance wrapper authenticates session and delegates to validated internal function', /session_karyawan\(p_token\)/.test(migrationB) && /submit_attendance_with_photo__v12_internal/.test(migrationB) && !/role.*ADMIN.*RAISE EXCEPTION/i.test(migrationB));

// C — Desktop Reimbursement reuses the existing Hybrid module and is role-limited.
check('desktop sidebar has Reimbursement group and Pengajuan Reimbursement submenu', /<button type="button" class="rk-parent"[\s\S]{0,300}>Reimbursement<span/.test(html) && /data-p="reimbursementRequest"[\s\S]{0,320}>Pengajuan Reimbursement/.test(html));
check('desktop reimbursement mount uses the existing reimbursementApp node', /id="rkDeskReimbursementMount"/.test(html) && /mount\.appendChild\(app\)/.test(html));
check('mobile mount is restored when desktop console deactivates', /restoreReimbursementMobileMount\(\)/.test(html) && /reimbursementAppOriginalParent\.appendChild\(app\)/.test(html));
check('only Hybrid loads reimbursement data; non-Hybrid sees safe limited placeholder', /function loadReimbursementPage\(\)[\s\S]{0,260}if\(!rhIsHybridUser\(\)\)\{host\.innerHTML/.test(html));
check('non-Hybrid desktop page is blurred and overlayed, including Admin', /rh-reim-limited/.test(html) && /blockedReimbursement=cur==='reimbursementRequest'&&!isDesktopHybrid\(\)/.test(html));
check('non-Hybrid still mounts the safe placeholder behind the blur instead of an empty panel', /if \(p === 'reimbursementRequest'\) renderDesktopReimbursementRequest\(\);/.test(html));
check('Hybrid access is based on job_code HYBRID and excludes read-only Admin', /return String\(code\)\.trim\(\)\.toUpperCase\(\)==='HYBRID' && !\(typeof isAdminReadOnly/.test(html));

// D — print button colors.
check('BKK and Reimbursement print actions use the same green primary rk-btn style', /class="rk-btn" id="rkIncEmpPrintBkk"/.test(html) && /class="rk-btn" id="rkIncEmpPrintReimburse"/.test(html) && !/class="rk-btn ghost" id="rkIncEmpPrintBkk"|class="rk-btn ghost" id="rkIncEmpPrintReimburse"/.test(html));

// Release/build integrity.
const htmlRelease = (html.match(/var RH_HTML_RELEASE = '([^']+)'/)||[])[1];
const swExpected = (sw.match(/RH_EXPECTED_HTML_RELEASE = '([^']+)'/)||[])[1];
check('HTML and Service Worker release markers match', !!htmlRelease && htmlRelease===swExpected);
check('Service Worker shell cache and release are advanced beyond v66/v67', /rehholz-app-shell-v73/.test(sw) && /v73-attendance-monitor-session-scope-fix/.test(sw));
check('migrations are staged transactionally and do not contain live credentials', /BEGIN;/.test(migrationA) && /COMMIT;/.test(migrationA) && /BEGIN;/.test(migrationB) && /COMMIT;/.test(migrationB) && !/service_role_key|sb_secret|password\s*=/.test(migrationA+ migrationB));


console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
