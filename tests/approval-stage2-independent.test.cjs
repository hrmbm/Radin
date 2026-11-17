'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const sw = fs.readFileSync(path.join(root, 'sw.js'), 'utf8');
let failed = 0, passed = 0;
function check(name, ok) { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`); ok ? passed++ : failed++; }
const helper = html.match(/function reimbursementCanActApprovalRow\(row,user\)\{[\s\S]*?\n\}/);
check('single canonical reimbursement authorization helper exists', !!helper);
if (helper) {
  const c = {}; vm.createContext(c);
  vm.runInContext(helper[0] + '\nthis.canAct = reimbursementCanActApprovalRow;', c);
  const row = { employee_id:'EMPLOYEE', job_code:'HYBRID', approval_line_id:'ST 000002', status:'PENDING_ATASAN', pending_stage:'ATASAN' };
  const cases = [
    ['assigned Superadmin may approve manager stage', true, row, {role:'SUPERADMIN',nik:'ST 000002'}],
    ['assigned Karyawan manager may approve manager stage', true, row, {role:'KARYAWAN',nik:'ST 000002'}],
    ['wrong manager is blocked', false, {...row,approval_line_id:'OTHER'}, {role:'KARYAWAN',nik:'ST 000002'}],
    ['missing approval_line_id is blocked', false, {...row,approval_line_id:''}, {role:'KARYAWAN',nik:'ST 000002'}],
    ['requester cannot approve own request', false, {...row,employee_id:'ST 000002'}, {role:'KARYAWAN',nik:'ST 000002'}],
    ['Admin is read-only', false, row, {role:'ADMIN',nik:'ST 000002'}],
    ['non-HYBRID reimbursement is blocked', false, {...row,job_code:'REGULAR'}, {role:'SUPERADMIN',nik:'ST 000002'}],
    ['manager cannot approve HR stage', false, {...row,status:'PENDING_HR',pending_stage:'HR'}, {role:'KARYAWAN',nik:'ST 000002'}],
    ['Superadmin may approve HR stage', true, {...row,status:'PENDING_HR',pending_stage:'HR'}, {role:'SUPERADMIN',nik:'ST 000002'}],
    ['terminal status cannot be approved', false, {...row,status:'DISETUJUI'}, {role:'SUPERADMIN',nik:'ST 000002'}]
  ];
  for (const [name,expected,r,u] of cases) check(name, c.canAct(r,u) === expected);
}
const bridge = html.match(/Object\.assign\(window,\s*\{([\s\S]*?)\}\);\s*window\.ReimbursementMoney/);
for (const name of ['reimbursementRpc','reimbursementRequestId','reimbursementCanActApprovalRow','reimbursementDecisionConfirmed','loadMyReimbursementRequests'])
  check(`desktop classic-script bridge exports ${name}`, !!bridge && new RegExp(`\\b${name}\\s*:`).test(bridge[1]));
check('mobile inline detail handler is exported to window', /window\.openMobileReimbursementById\s*=\s*openMobileReimbursementById/.test(html));
check('mobile approve/reject handler is exported to window', /window\.actMobileReimbursement\s*=\s*actMobileReimbursement/.test(html));
check('desktop bulk approval waits for refreshBadge promise', /Promise\.all\(\[renderMyApprovalsPage\(\),refreshBadge\(\)\.catch/.test(html));
check('refreshBadge returns a promise', /function refreshBadge\(queueResult\)\s*\{[\s\S]{0,300}return Promise\.all\(/.test(html));
check('personal approval queue does not await HR-wide monitoring', /if\(isHR\(\)\)\{\s*var monitorLoad=renderPendingTrackingPage\(\)/.test(html) && /Promise\.all\(\[corePromise,reimbursementPromise\]\)/.test(html));
check('canonical queue keeps Presensi/Time Off and Reimbursement failures independent', /errors:\{core:core\.error\|\|null,reimbursement:reim\.error\|\|null\}/.test(html));
check('mobile refresh consumes the canonical approval queue', /function refreshPending\(\)[\s\S]{0,260}loadApprovalQueueCanonical\(\)/.test(html));
check('desktop personal queue consumes the same canonical approval queue', /function renderMyApprovalsPage\(\)[\s\S]{0,2600}window\.loadApprovalQueueCanonical\(\)/.test(html));
check('desktop queue filters reimbursement by assigned approver', /reim\.forEach\(function\(x\)\{var id=reimbursementRequestId\(x\);if\(id&&reimbursementCanActApprovalRow\(x,S\.user\)\)/.test(html));
check('mobile action rechecks authorization before RPC', /if\(!target\|\|!reimbursementCanActApprovalRow\(target,S\.user\)\)/.test(html));
check('mobile reject requires a reason', /if\(!approve&&!note\)\{toast\('Catatan penolakan wajib diisi\.'/ .test(html));
check('decision uncertainty is verified against server approval identity', /hr_get_reimbursement_approval_status/.test(html) && /manager_approval_by/.test(html) && /hr_approval_by/.test(html));
const marker = (html.match(/<meta name="reholz-release" content="([^"]+)"\s*>/) || [])[1];
const expected = (sw.match(/const RH_EXPECTED_HTML_RELEASE = '([^']+)'/) || [])[1];
check('HTML and Service Worker release markers match', !!marker && marker === expected);
check('Service Worker cache release advanced to v66', /rehholz-app-shell-v72/.test(sw) && /v72-reimbursement-desktop-ui/.test(sw));
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
