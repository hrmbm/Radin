'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const sw = fs.readFileSync(path.join(__dirname, '..', 'sw.js'), 'utf8');
let passed = 0, failed = 0;
function check(name, ok) { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`); ok ? passed++ : failed++; }
function sliceBetween(start, end) {
  const a = html.indexOf(start);
  if (a < 0) return '';
  const b = html.indexOf(end, a + start.length);
  return b < 0 ? '' : html.slice(a, b);
}
function sha(value) { return crypto.createHash('sha256').update(value).digest('hex'); }

const release = (html.match(/<meta name="reholz-release" content="([^"]+)"/) || [])[1] || '';
const swExpected = (sw.match(/const RH_EXPECTED_HTML_RELEASE = '([^']+)'/) || [])[1] || '';
check('Stage 3 HTML release marker matches Service Worker v66', release === 'v14.7.19-stage4-attendance-monitor-session-scope-fix' && swExpected === release && /rehholz-app-shell-v73/.test(sw) && /v73-attendance-monitor-session-scope-fix/.test(sw));

// The employee slip is the existing per-employee Cetak PDF. It contains reimbursement rows,
// but is not a standalone reimbursement-only document.
const slipBuilder = sliceBetween('function incentiveEmployeePrintPages(row,p,formula,signatory){', 'function titleCasePrintName(');
check('Employee slip content and its three-column signature labels are unchanged',
  sha(slipBuilder) === 'b357602697e1eff5c662386ef7e628667d8a8337aac142bae93b89eeb8de4fc1' &&
  /Diajukan Oleh,/.test(slipBuilder) && /Disetujui Oleh,/.test(slipBuilder) && /Diterima Oleh,/.test(slipBuilder));

// Clean up conflicting historical CSS to one deliberate 14 mm hand-signature gap.
const detailSignatureRules = [...html.matchAll(/body\.rk-printing-incentive \.rk-incentive-exact-signatures>div>b\s*\{([^}]*)\}/g)].map(m => m[1]);
const rulesWithGap = detailSignatureRules.filter(rule => /margin(?:-top)?\s*:\s*(?:5\.5mm|12mm|14mm)/.test(rule));
check('Employee detail slip signature name uses a consistent 14 mm label-to-name gap',
  rulesWithGap.length >= 4 && rulesWithGap.every(rule => /margin(?:-top)?\s*:\s*(?:14mm(?:\s+0\s+0)?)(?:!important)?/.test(rule)) &&
  !/body\.rk-printing-incentive \.rk-incentive-exact-signatures>div>b\s*\{[^}]*5\.5mm/.test(html));
check('No stale 5.5 mm signature spacing remains in the employee slip print CSS',
  !/body\.rk-printing-incentive \.rk-incentive-exact-signatures>div>b[^}]*5\.5mm/.test(html));
const wrapBuilder = sliceBetween('function incentiveWrapPrintPages(items,mode,allSelected){', 'function incentiveRowsSum(');
check('Slip still uses two half-page forms on one Letter print sheet',
  /@page\s*\{\s*size:\s*215\.9mm\s+279\.4mm/.test(html) && /rk-incentive-pair-sheet/.test(wrapBuilder));
const logoPng = fs.readFileSync(path.join(__dirname, '..', 'assets', 'reholz-logo-print.png'));
const logoWidth = logoPng.readUInt32BE(16), logoHeight = logoPng.readUInt32BE(20);
check('Employee detail slip logo preserves the source image aspect ratio',
  logoWidth === 300 && logoHeight === 115 && /rk-incentive-exact-logo img \{[^}]*width:30\.7mm!important;[^}]*height:auto!important;[^}]*object-fit:contain!important;/.test(html));
check('Rekap logo remains naturally contained and is not stretched',
  /rk-ledger-brand img \{display:block!important;width:30mm!important;height:auto!important;max-width:30mm!important;object-fit:contain!important;/.test(html));

// Cetak Rekap and Cetak Reimbursement retain their established print systems unchanged.
const ledgerBuilder = sliceBetween('function incentiveEmployeeLedgerSummary(rows,p,globalSignatory){', 'function incentiveWrapPrintPages(');
const reimbursementBuilder = sliceBetween('function printIncentiveReimbursement(){', 'function saveIncentiveUnderpayment()');
const bkkBuilder = sliceBetween('function printIncentiveBkk(){', 'function printIncentiveReimbursement()');
check('Cetak Rekap ledger builder remains byte-for-byte unchanged from v63',
  sha(ledgerBuilder) === 'ba0345f054f53284fea468322ff442a1c81d5fd6a060be9985cc2e37b6f06190');
check('Cetak Reimbursement function and layout remain byte-for-byte unchanged from v63',
  sha(reimbursementBuilder) === '3bdc7e5c39d215799110ebf22456033c6efefc3e8d73d483495a8451cb6e5379' && /size:A4 landscape/.test(reimbursementBuilder) && /margin-top:22mm/.test(reimbursementBuilder));
check('Cetak BKK output remains byte-for-byte unchanged from v63',
  sha(bkkBuilder) === '077001f0193526e2fc4eec90d8a6fd554bef26a5a2e586cb4ea0942a95e4af3f');
check('Cetak PDF and Cetak Rekap continue to call the original slip/ledger modes',
  /function printIncentiveEmployeeRecap\(\)\{return printIncentiveEmployeeMode\('slip'\);\}/.test(html) &&
  /function printIncentiveEmployeeLedger\(\)\{return printIncentiveEmployeeMode\('ledger'\);\}/.test(html));
check('Standalone Reimbursement report preserves its A4 landscape signature geometry',
  /@page\{size:A4 landscape;margin:9mm 10mm 10mm\}/.test(reimbursementBuilder) &&
  /\.rh-reimburse-sign b\{display:block;margin-top:22mm/.test(reimbursementBuilder));

// Confirm no server-side behavior, approvals or RPC names changed in this print-only release.
check('Reimbursement report RPC and approval state logic remain unchanged',
  /rpcOptional\('hr_get_reimbursement_recap'/.test(reimbursementBuilder) &&
  /getReimbursementSignedUrls/.test(reimbursementBuilder) &&
  /process_reimbursement_approval/.test(html));

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
