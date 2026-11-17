'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const sw = fs.readFileSync(path.join(root, 'sw.js'), 'utf8');
let passed = 0, failed = 0;
function check(name, ok) {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
  if (ok) passed++; else failed++;
}
function fn(name) {
  const start = html.indexOf(`function ${name}(`);
  if (start < 0) return '';
  const end = html.indexOf('\n}', start);
  return end < 0 ? '' : html.slice(start, end + 2);
}

// All three approval types must enter the same queue adapter, regardless of viewport.
const directQueueCalls = html.match(/api\(['"]getPendingApprovalsFull['"]/g) || [];
check('one direct pending-approval API call remains, inside the canonical loader', directQueueCalls.length === 1 && /function loadApprovalQueueCanonical\(\)[\s\S]{0,1800}api\('getPendingApprovalsFull'/.test(html));
check('canonical queue normalizes attendance, Time Off and keeps reimbursement in the same result', /core\.absensi\.map\(normalizeApprovalAttendanceRow\),cuti=core\.cuti\.map\(normalizeApprovalTimeOffRow\),reimbursement=reim\.rows\.slice\(\)/.test(html));
check('mobile approval refresh uses the canonical queue', /function refreshPending\(\)[\s\S]{0,300}loadApprovalQueueCanonical\(\)/.test(html));
check('desktop approval inbox uses the canonical queue', /function renderMyApprovalsPage\(\)[\s\S]{0,3000}window\.loadApprovalQueueCanonical\(\)/.test(html));
check('desktop attendance detail fallback uses the canonical queue', /function openDesktopAttendanceDetail\(id\)[\s\S]{0,15000}window\.loadApprovalQueueCanonical\(\)/.test(html));
check('desktop attendance detail prefers the shared current queue over potentially stale desktop cache rows', /function findRow\(\) \{[\s\S]{0,900}DATA\.appr && Array\.isArray\(DATA\.appr\.absensi\)[\s\S]{0,500}currentQueue\.concat\(ownRows, desktopCache\)/.test(html));
check('desktop attendance action rechecks current row from the canonical queue', /function submitDesktopAttendanceAction\(id, action\)[\s\S]{0,1800}window\.loadApprovalQueueCanonical\(\)/.test(html));
check('desktop Time Off list supplements history from the canonical approval queue', /function loadCutiData\(force\)[\s\S]{0,1800}window\.loadApprovalQueueCanonical\(\)/.test(html));
check('desktop decision dispatcher reads from the canonical queue', /function aprAct\(kind, id, action\)[\s\S]{0,1000}window\.loadApprovalQueueCanonical\(\)/.test(html));

// Mobile and desktop now share the exact same attendance-photo renderer/resolver.
check('mobile attendance photo uses shared renderer', /function paintMobileAttendanceEvidence\([\s\S]{0,1200}paintAttendanceEvidencePreview\(/.test(html));
check('desktop attendance photo uses shared renderer', /function openDesktopAttendanceDetail\(id\)[\s\S]{0,15000}window\.paintAttendanceEvidencePreview\(/.test(html));
check('desktop always invokes the shared photo renderer so the reserved photo panel shows either evidence or a visible empty/error state', /if \(photoBox && typeof window\.paintAttendanceEvidencePreview === 'function'\) \{[\s\S]{0,500}window\.paintAttendanceEvidencePreview\(photoBox, row/.test(html));
check('shared attendance renderer resolves private evidence through the same signed-URL resolver', /function paintAttendanceEvidencePreview\([\s\S]{0,3500}resolveEvidenceDisplayUrl\(source, !!forceRefresh\)/.test(html));
check('shared attendance renderer guards stale detail views and supports one refresh plus retry', /rhAttendanceEvidenceRowId/.test(html) && /if \(!forceRefresh\) load\(true\)/.test(html) && /Coba lagi/.test(html));

// Time Off uses one path/MIME extractor in both renderers; private reimbursement bucket remains separate.
check('mobile Time Off attachment uses shared path and MIME helpers', /function mobileTimeOffAttachmentValue\(row\)[\s\S]{0,500}approvalTimeOffAttachmentValue/.test(html) && /function mobileTimeOffAttachmentMime\(row, value\)[\s\S]{0,500}approvalTimeOffAttachmentMime/.test(html));
check('desktop Time Off attachment uses shared path and MIME helpers', /function cutiAttachmentValue\(row\)[\s\S]{0,500}approvalTimeOffAttachmentValue/.test(html) && /window\.approvalTimeOffAttachmentMime\(x,file\)/.test(html));
check('Time Off normalizer retains common identity, period, state and attachment fields', /function normalizeApprovalTimeOffRow\(row\)[\s\S]{0,2600}dokumenUrl: attachment,[\s\S]{0,100}attachmentMime: approvalTimeOffAttachmentMime/.test(html));
check('reimbursement still uses its dedicated signed-URL API and display resolver', /getReimbursementSignedUrls/.test(html) && /function getReimbursementAttachmentDisplayUrl\(raw\)/.test(html));
check('attendance still uses its dedicated evidence authorization/signed URL API', /getEvidenceSignedUrl/.test(html));

// Exercise the normalization helpers on representative snake_case and camelCase payloads.
const attendanceFns = ['attendanceEvidenceSource', 'normalizeAbsensiEvidence', 'normalizeApprovalAttendanceRow'].map(fn);
check('attendance normalization functions are extractable for runtime unit checks', attendanceFns.every(Boolean));
if (attendanceFns.every(Boolean)) {
  const context = { window: {} };
  vm.createContext(context);
  vm.runInContext(attendanceFns.join('\n') + '\nthis.normalizeAttendance = normalizeApprovalAttendanceRow; this.attendanceSource = attendanceEvidenceSource;', context);
  const row = context.normalizeAttendance({
    absensi_id: 'ABS-TEST-1', employee_id: 'ST 123456', employee_name: 'TEST EMPLOYEE',
    foto_path: 'ST 123456/ABS-TEST-1.jpg', latitude: -7.5, longitude: 112.7,
    status_approval: 'PENDING_ATASAN', submitted_at: '2026-11-16T07:00:00+07:00'
  });
  check('attendance row normalizes ID, employee, photo path, coordinates and status', row.id === 'ABS-TEST-1' && row.nik === 'ST 123456' && row.fotoUrl === 'ST 123456/ABS-TEST-1.jpg' && row.latitude === -7.5 && row.longitude === 112.7 && row.statusApproval === 'PENDING_ATASAN');
  const rawJpeg = '/9j/' + 'A'.repeat(180);
  const normalizedRawJpeg = context.attendanceSource({ fotoUrl: rawJpeg });
  check('raw JPEG attendance evidence is normalized to a data URI instead of a fake Storage path', normalizedRawJpeg.indexOf('data:image/jpeg;base64,') === 0);
}

const cutiFns = ['approvalRowFirstValue', 'approvalTimeOffAttachmentValue', 'approvalTimeOffAttachmentMime', 'normalizeApprovalTimeOffRow'].map(fn);
check('Time Off normalization functions are extractable for runtime unit checks', cutiFns.every(Boolean));
if (cutiFns.every(Boolean)) {
  const context = { window: {} };
  vm.createContext(context);
  vm.runInContext(cutiFns.join('\n') + '\nthis.normalizeTimeOff = normalizeApprovalTimeOffRow;', context);
  const pathRow = context.normalizeTimeOff({
    request_id: 'CT-TEST-1', employee_id: 'ST 123456', employee_name: 'TEST EMPLOYEE',
    kode_cuti: 'CUTI_TAHUNAN', tanggal_mulai: '2026-11-20', tanggal_selesai: '2026-11-21',
    status_atasan: 'PENDING', status_hr: 'PENDING', file_path: 'time-off/ST123/file.pdf', mime_type: 'application/pdf'
  });
  check('Time Off row normalizes identity, dates, status, path and MIME', pathRow.id === 'CT-TEST-1' && pathRow.nik === 'ST 123456' && pathRow.tanggalMulai === '2026-11-20' && pathRow.tanggalSelesai === '2026-11-21' && pathRow.statusAtasan === 'PENDING' && pathRow.dokumenUrl === 'time-off/ST123/file.pdf' && pathRow.attachmentMime === 'application/pdf');
  const base64 = '/9j/' + 'A'.repeat(180);
  const embedded = context.normalizeTimeOff({ request_id: 'CT-TEST-2', attachment: base64 });
  check('embedded JPEG Time Off evidence gets a valid image data URI', embedded.dokumenUrl.indexOf('data:image/jpeg;base64,') === 0 && embedded.attachmentMime === 'image/jpeg');
}

const marker = (html.match(/<meta name="reholz-release" content="([^"]+)"\s*>/) || [])[1];
const expected = (sw.match(/const RH_EXPECTED_HTML_RELEASE = '([^']+)'/) || [])[1];
check('HTML release marker and Service Worker expectation match', !!marker && marker === expected);
check('Service Worker cache and release were advanced for the Stage 2 attendance popup proportion fix', /rehholz-app-shell-v72/.test(sw) && /v72-reimbursement-desktop-ui/.test(sw));

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
