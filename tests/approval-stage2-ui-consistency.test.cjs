'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
let passed = 0, failed = 0;
function check(name, ok) {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
  ok ? passed++ : failed++;
}
function extractBetween(start, end) {
  const a = html.indexOf(start), b = html.indexOf(end, a + start.length);
  if (a < 0 || b < 0) return '';
  return html.slice(a, b);
}
const mobileDetail = extractBetween('function openMobileReimbursementDetail(', 'function openMobileReimbursementById(');
const desktopDetail = extractBetween('  function openDesktopReimbursementDetail(', '  function submitDesktopReimbursementAction(');
const sharedBuilder = extractBetween('function reimbursementStatusPresentation(', 'function openMobileReimbursementDetail(');
const canonicalLoader = extractBetween('function loadApprovalQueueCanonical(', 'window.loadApprovalQueueCanonical=');

check('one canonical loader is exported for both clients', !!canonicalLoader && /window\.loadApprovalQueueCanonical=loadApprovalQueueCanonical/.test(html));
check('mobile and desktop details call the same markup builder', /buildReimbursementApprovalDetail\(row,id,canAct\)/.test(mobileDetail) && /window\.buildReimbursementApprovalDetail\(row,id,canAct\)/.test(desktopDetail));
check('mobile and desktop details call the same attachment preview', /paintReimbursementAttachmentPreview\(row,id,'rhReimProof'\)/.test(mobileDetail) && /window\.paintReimbursementAttachmentPreview\(row,id,'rhReimProof'\)/.test(desktopDetail));
check('top hero is reserved for inline transaction evidence', /rh-reim-evidence-hero/.test(sharedBuilder) && /id="rhReimProof"/.test(sharedBuilder));
check('redundant attachment label, unavailable preview message and open/download link are absent from reimbursement detail', !/Bukti transaksi|Pratinjau tidak tersedia|Buka \/ unduh bukti|Buka bukti/.test(sharedBuilder));
check('requester label is renamed', /Pengajuan Reimbursement/.test(sharedBuilder) && !/Pengaju<\//.test(sharedBuilder));
check('overbudget highlight is conditional on amount greater than zero', /over>0\?' is-overbudget':''/.test(sharedBuilder) && /rh-reim-overbudget\.is-overbudget/.test(html));
check('irrelevant future approval-stage helper text is removed from the reimbursement detail', !/Menunggu penyelesaian tahap atasan langsung|Pengajuan ini ditampilkan dari antrean persetujuan/.test(sharedBuilder));
check('unknown attachment without extension gets an inline image attempt then viewer fallback', /unknown\.src=url/.test(sharedBuilder) && /unknown\.onerror=function\(\)\{if\(!switched\)\{switched=true;showFrame\(url\);\}\}/.test(sharedBuilder));
check('PDF, image, video and audio MIME paths are supported inline', /mime==='application\/pdf'/.test(sharedBuilder) && /mime\.indexOf\('image\/'\)/.test(sharedBuilder) && /mime\.indexOf\('video\/'\)/.test(sharedBuilder) && /mime\.indexOf\('audio\/'\)/.test(sharedBuilder));
check('mobile action buttons restore their matching labels after a failed request', /b\.getAttribute\('data-reim-detail-action'\)==='APPROVE'\?'Setujui':'Tolak'/.test(html));
check('shared queue isolates in-flight requests and cached data by session generation', /RH_APPROVAL_QUEUE_INFLIGHT_GENERATION===generation/.test(canonicalLoader) && /RH_APPROVAL_QUEUE_DATA_GENERATION===generation/.test(canonicalLoader) && /RH_APPROVAL_QUEUE_INFLIGHT===flight/.test(canonicalLoader));

// Execute the shared renderer against the example from the supplied screenshot/context.
if (sharedBuilder) {
  const context = {
    window: {},
    Date,
    Number,
    String,
    Math,
    esc(value) { return String(value == null ? '' : value).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;'); },
    tlItem(cls, title, sub) { return `<div class="tl-item ${cls}"><b>${this.esc ? this.esc(title) : String(title)}</b>${sub ? `<span>${String(sub)}</span>` : ''}</div>`; },
    reimbursementAttachmentPath(row) { return row.attachment_path || ''; },
    reimbursementMoney(value) { return 'Rp ' + Math.round(Number(value)||0).toLocaleString('id-ID'); },
    tglID(value) { return value || '—'; }
  };
  context.tlItem = (cls, title, sub) => `<div class="tl-item ${cls}"><b>${context.esc(title)}</b>${sub ? `<span>${context.esc(sub)}</span>` : ''}</div>`;
  vm.createContext(context);
  try {
    vm.runInContext(sharedBuilder + '\nthis.build = buildReimbursementApprovalDetail;', context);
    const row = {
      id:'RMB-2EF85E2470564AEE8251', employee_name:'SAMUEL SATURDAY GERRIT', employee_id:'ST 260802',
      category:'TRANSPORT', request_date:'2026-11-13', amount:328800, over_budget_amount:328800,
      note:'kopi', attachment_path:'ST 260802/TRANSPORT/f7246bbf-abe2-45ae-ad77-d19b2f269147',
      created_at:'2026-11-13T08:54:35.280558Z', status:'PENDING_ATASAN', pending_stage:'ATASAN'
    };
    const markup = context.build(row, row.id, true);
    check('sample reimbursement detail includes requester, amount, overbudget and evidence slot',
      markup.includes('Pengajuan Reimbursement') && markup.includes('SAMUEL SATURDAY GERRIT') && markup.includes('ST 260802') && markup.includes('Rp 328.800') && markup.includes('rhReimProof'));
    check('sample overbudget detail receives the visual warning class', /rh-reim-overbudget is-overbudget/.test(markup));
    check('sample detail includes approval actions and required rejection note', markup.includes('data-reim-detail-action="APPROVE"') && markup.includes('data-reim-detail-action="REJECT"') && markup.includes('Catatan keputusan (wajib untuk penolakan)'));
    check('Reimbursement desktop actions reuse the same button/action-group classes as Time Off', markup.includes('rh-reim-actions rk-cuti-detail-actions') && markup.includes('class="rk-btn"') && markup.includes('class="rk-btn danger"') && !markup.includes('class="rh-reim-approve"')); 
    const timeline = markup.slice(markup.indexOf('class="tl"'));
    check('sample timeline places active approver above the requester', timeline.indexOf('Menunggu persetujuan atasan langsung') >= 0 && timeline.indexOf('Menunggu persetujuan atasan langsung') < timeline.indexOf('Diajukan oleh SAMUEL'));
    const pendingHr = Object.assign({}, row, { status:'PENDING_HR', manager_approver_name:'MGR SAMPLE', manager_approval_at:'2026-11-15T08:00:00Z' });
    const hrMarkup = context.build(pendingHr, row.id, true);
    const hrTimeline = hrMarkup.slice(hrMarkup.indexOf('class="tl"'));
    check('PENDING_HR timeline order is Superadmin, manager, requester', hrTimeline.indexOf('Menunggu persetujuan Superadmin') < hrTimeline.indexOf('Disetujui oleh MGR SAMPLE') && hrTimeline.indexOf('Disetujui oleh MGR SAMPLE') < hrTimeline.indexOf('Diajukan oleh SAMUEL'));
    const approved = Object.assign({}, row, { status:'DISETUJUI', manager_approver_name:'MGR SAMPLE', manager_approval_at:'2026-11-15T08:00:00Z', hr_approver_name:'HR SAMPLE', hr_approval_at:'2026-11-16T08:00:00Z' });
    const approvedMarkup = context.build(approved, row.id, false);
    const approvedTimeline = approvedMarkup.slice(approvedMarkup.indexOf('class="tl"'));
    check('approved timeline order is final approver, manager, requester', approvedTimeline.indexOf('Disetujui oleh HR SAMPLE') < approvedTimeline.indexOf('Disetujui oleh MGR SAMPLE') && approvedTimeline.indexOf('Disetujui oleh MGR SAMPLE') < approvedTimeline.indexOf('Diajukan oleh SAMUEL'));
    const rejected = Object.assign({}, row, { status:'DITOLAK_ATASAN', manager_note:'Tidak sesuai ketentuan' });
    const rejectedMarkup = context.build(rejected, row.id, false);
    const rejectedTimeline = rejectedMarkup.slice(rejectedMarkup.indexOf('class="tl"'));
    check('manager rejection timeline still places the approver decision above requester', rejectedTimeline.indexOf('Ditolak atasan langsung') < rejectedTimeline.indexOf('Diajukan oleh SAMUEL'));
    const rejectedHr = Object.assign({}, row, { status:'DITOLAK_HR', manager_approver_name:'MGR SAMPLE', manager_approval_at:'2026-11-15T08:00:00Z', hr_note:'Bukti tidak sesuai' });
    const rejectedHrMarkup = context.build(rejectedHr, row.id, false);
    const rejectedHrTimeline = rejectedHrMarkup.slice(rejectedHrMarkup.indexOf('class="tl"'));
    check('Superadmin rejection timeline places HR decision first, manager approval second, requester last', rejectedHrTimeline.indexOf('Ditolak Superadmin') < rejectedHrTimeline.indexOf('Disetujui oleh MGR SAMPLE') && rejectedHrTimeline.indexOf('Disetujui oleh MGR SAMPLE') < rejectedHrTimeline.indexOf('Diajukan oleh SAMUEL'));
  } catch (error) {
    console.error(error);
    check('shared renderer executes against example request', false);
  }
}
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
