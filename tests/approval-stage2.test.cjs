'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const sw = fs.readFileSync(path.join(__dirname, '..', 'sw.js'), 'utf8');
let failed = 0;
function check(name, condition) {
  console.log((condition ? 'PASS ' : 'FAIL ') + name);
  if (!condition) failed++;
}
const match = html.match(/function reimbursementCanActApprovalRow\(row,user\)\{[\s\S]*?\n\}/);
check('canonical reimbursement permission helper exists', !!match);
if (match) {
  const context = {};
  vm.createContext(context);
  vm.runInContext(match[0] + '\nthis.permissionCheck = reimbursementCanActApprovalRow;', context);
  const can = context.permissionCheck;
  const base = { employee_id: 'EMP1', job_code: 'HYBRID', approval_line_id: 'MGR1', status: 'PENDING_ATASAN', pending_stage: 'ATASAN' };
  const cases = [
    ['assigned manager can approve stage 1', true, {...base}, {role:'KARYAWAN',nik:'MGR1'}],
    ['wrong manager cannot approve', false, {...base,approval_line_id:'MGR2'}, {role:'KARYAWAN',nik:'MGR1'}],
    ['missing manager mapping cannot approve', false, {...base,approval_line_id:''}, {role:'KARYAWAN',nik:'MGR1'}],
    ['HR role cannot approve manager stage', false, {...base}, {role:'HR',nik:'MGR1'}],
    ['assigned Superadmin can approve manager stage', true, {...base}, {role:'SUPERADMIN',nik:'MGR1'}],
    ['Superadmin can approve HR stage', true, {...base,status:'PENDING_HR',pending_stage:'HR'}, {role:'SUPERADMIN',nik:'SA1'}],
    ['manager cannot approve HR stage', false, {...base,status:'PENDING_HR',pending_stage:'HR'}, {role:'KARYAWAN',nik:'MGR1'}],
    ['Admin is read-only', false, {...base}, {role:'ADMIN',nik:'MGR1'}],
    ['requester cannot approve own request', false, {...base,employee_id:'MGR1'}, {role:'KARYAWAN',nik:'MGR1'}],
    ['non-HYBRID request cannot be approved', false, {...base,job_code:'REGULAR'}, {role:'KARYAWAN',nik:'MGR1'}],
    ['mismatched stage metadata is rejected', false, {...base,pending_stage:'HR'}, {role:'KARYAWAN',nik:'MGR1'}],
    ['terminal request cannot be approved', false, {...base,status:'DISETUJUI'}, {role:'SUPERADMIN',nik:'MGR1'}]
  ];
  for (const [name, expected, row, user] of cases) check(name, can(row,user) === expected);
}
check('mobile detail renders actions only through canonical permission check', /canAct=!!fromAppr&&reimbursementCanActApprovalRow\(row,S\.user\)/.test(html));
check('mobile action rechecks permission before mutation', /if\(!target\|\|!reimbursementCanActApprovalRow\(target,S\.user\)\)/.test(html));
check('mobile reimbursement mutation uses required RPC wrapper', /reimbursementRpc\('process_reimbursement_approval',[\s\S]{0,180}45000/.test(html));
check('desktop inbox validates permission before mutation', /if\(!item\|\|!reimbursementCanActApprovalRow\(item\.row,S\.user\)\)/.test(html));
check('desktop detail validates permission before mutation', /if\(!reimbursementCanActApprovalRow\(row,S\.user\)\)/.test(html));
check('desktop queue item uses canonical permission check', /var canAct = kind==='reimbursement' \? reimbursementCanActApprovalRow\(x,S\.user\)/.test(html));
check('bulk approval validates reimbursement permission', /kind==='reimbursement'\)\{if\(!reimbursementCanActApprovalRow\(item\.row,S\.user\)\)/.test(html));
check('no reimbursement mutation is routed through silent optional RPC', !/rpcOptional\(['"]process_reimbursement_approval/.test(html));
check('uncertain response is verified against server approver identity', /hr_get_reimbursement_approval_status/.test(html) && /manager_approval_by/.test(html) && /hr_approval_by/.test(html));
const marker = (html.match(/<meta name="reholz-release" content="([^"]+)"\s*>/) || [])[1];
const expected = (sw.match(/const RH_EXPECTED_HTML_RELEASE = '([^']+)'/) || [])[1];
check('service worker release marker matches HTML', !!marker && marker === expected);
check('service worker cache release was advanced to v66', /rehholz-app-shell-v72/.test(sw) && /v72-reimbursement-desktop-ui/.test(sw));
console.log(`\n${failed ? 'FAILED' : 'ALL PASS'} — ${failed} failed checks`);
process.exit(failed ? 1 : 0);
