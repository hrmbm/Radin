"""Playwright UI regression tests for HRIS Reimbursement UI v73.
Run: python tests/ui/test_reimbursement_ui.py
Requires Playwright and a Chromium executable available to the environment.
"""
from pathlib import Path
import json
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).with_name('fixture.html')
RESULTS = []

def check(name, condition, details=''):
    ok = bool(condition)
    RESULTS.append({'name': name, 'status': 'PASS' if ok else 'FAIL', 'details': details})
    print(('PASS' if ok else 'FAIL') + ' ' + name + ((' — ' + details) if details else ''))
    if not ok:
        raise AssertionError(name + ((': ' + details) if details else ''))


def make_page(browser, width, height):
    page = browser.new_page(viewport={'width': width, 'height': height}, device_scale_factor=1)
    page.set_content(FIXTURE.read_text(encoding='utf-8'), wait_until='domcontentloaded')
    page.wait_for_timeout(150)
    page.add_style_tag(content='*,*::before,*::after{animation:none!important;transition:none!important;caret-color:transparent!important;}')
    return page


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, executable_path='/usr/bin/chromium', args=['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'])
        try:
            # Desktop large: two-column form + history and no horizontal overflow.
            page = make_page(browser, 1440, 1000)
            grid = page.locator('.reimbursement-workspace').evaluate("e=>getComputedStyle(e).display")
            cols = page.locator('.reimbursement-workspace').evaluate("e=>getComputedStyle(e).gridTemplateColumns")
            check('desktop 1440 uses two-column workspace', grid == 'grid' and len(cols.split()) == 2, cols)
            check('desktop summary spans above category selector', page.locator('.reimbursement-summary').count() == 1 and page.locator('.reimbursement-tabs [role=tab]').count() == 2)
            check('desktop form and history are separate panels', page.locator('.reimbursement-form-card').count() == 1 and page.locator('.reimbursement-history-panel').count() == 1)
            check('desktop form exposes all four original inputs', all(page.locator('#'+x).count() == 1 for x in ['rhReimbursementDate','rhReimbursementAmount','rhReimbursementNote','rhReimbursementFile']))
            check('desktop contains no horizontal overflow', page.evaluate('document.documentElement.scrollWidth <= window.innerWidth'))
            check('history item is keyboard-operable button', page.locator('.reimbursement-history-item').first.evaluate("e=>e.tagName==='BUTTON' && e.getAttribute('aria-label')"))
            page.locator('.reimbursement-history-item').first.press('Enter')
            check('history item opens matching request detail action', page.evaluate('window.__openedHistory') == 'RB-260811')

            # Category tabs still drive the same shared state and amounts.
            page.get_by_role('tab', name='Transport').click()
            check('Transport tab switches shared category state', page.evaluate("RH_REIMBURSEMENT_STATE.category") == 'TRANSPORT')
            check('Transport title and available balance update', page.locator('#rhReimbursementFormTitle').inner_text() == 'Pengajuan Transport' and '700.000' in page.locator('.reimbursement-balance-main>strong').inner_text())
            page.get_by_role('tab', name='Entertain').click()
            check('Entertain tab restores original category', page.evaluate("RH_REIMBURSEMENT_STATE.category") == 'ENTERTAIN')

            # Over-budget condition and note-required rule.
            page.locator('#rhReimbursementAmount').fill('1000000')
            page.locator('#rhReimbursementAmount').dispatch_event('input')
            check('overbudget state updates submit label', page.locator('#rhReimbursementSubmit').inner_text() == 'Ajukan Over Budget')
            check('overbudget guidance is visible', page.locator('#rhReimbursementOverNote').evaluate("e=>getComputedStyle(e).display!='none' && e.classList.contains('is-visible')"))
            check('overbudget marks note as required', 'wajib' in page.locator('#rhReimbursementNoteRequired').inner_text().lower())
            page.evaluate('submitReimbursementRequest()')
            page.wait_for_timeout(50)
            check('missing overbudget note blocks upload', len(page.evaluate('window.__testCalls')) == 0 and any('Catatan wajib' in x for x in page.evaluate('window.__toasts')))

            # Valid attachment, file upload and submission keep the original API/RPC contract.
            page.locator('#rhReimbursementNote').fill('Jamuan buyer di luar kantor')
            page.locator('#rhReimbursementFile').set_input_files({'name':'bukti.png','mimeType':'image/png','buffer':bytes.fromhex('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082')})
            page.evaluate('submitReimbursementRequest()')
            page.wait_for_function('window.__testCalls.length >= 2', timeout=5000)
            calls = page.evaluate('window.__testCalls')
            check('valid form uploads exactly one evidence file', sum(1 for x in calls if x['type']=='api' and x['fn']=='uploadReimbursementAttachment') == 1)
            rpc = next((x for x in calls if x['type']=='rpc' and x['fn']=='hr_submit_reimbursement_request'), None)
            check('valid form submits existing reimbursement RPC', rpc is not None)
            check('RPC payload keeps category/date/amount/note/storage path', rpc is not None and rpc['args'].get('p_category')=='ENTERTAIN' and rpc['args'].get('p_tanggal')=='2026-11-17' and rpc['args'].get('p_nominal')==1000000 and rpc['args'].get('p_catatan')=='Jamuan buyer di luar kantor' and rpc['args'].get('p_lampiran')=='test/attachment.png')
            page.wait_for_function('window.__loadAfterSubmit === 1', timeout=3000)
            check('success reloads the existing reimbursement page once', page.evaluate('window.__loadAfterSubmit') == 1)

            # Invalid attachment size/type must never reach upload.
            page.locator('#rhReimbursementAmount').fill('500000')
            page.locator('#rhReimbursementAmount').dispatch_event('input')
            page.locator('#rhReimbursementFile').set_input_files({'name':'too-large.png','mimeType':'image/png','buffer':b'x'*(8*1024*1024+1)})
            before = len(page.evaluate('window.__testCalls'))
            page.evaluate('submitReimbursementRequest()')
            check('oversized attachment is rejected before upload', len(page.evaluate('window.__testCalls')) == before and any('maksimal 8 MB' in x for x in page.evaluate('window.__toasts')))
            page.locator('#rhReimbursementFile').set_input_files({'name':'notes.txt','mimeType':'text/plain','buffer':b'test'})
            page.evaluate('submitReimbursementRequest()')
            check('unsupported attachment type is rejected before upload', len(page.evaluate('window.__testCalls')) == before and any('JPG, PNG, WEBP' in x for x in page.evaluate('window.__toasts')))
            page.close()

            # Responsive breakpoints: desktop narrower, tablet, and mobile.
            for width, height, expected_cols, label in [
                (1280, 900, 2, 'desktop 1280'),
                (1024, 900, 1, 'desktop 1024 stacks panels to preserve readable form width'),
                (768, 900, 1, 'tablet 768 remains single column'),
                (390, 844, 1, 'mobile 390 remains single column'),
                (360, 800, 1, 'mobile 360 remains single column'),
            ]:
                vp = make_page(browser, width, height)
                display = vp.locator('.reimbursement-workspace').evaluate("e=>getComputedStyle(e).display")
                columns = vp.locator('.reimbursement-workspace').evaluate("e=>getComputedStyle(e).gridTemplateColumns")
                count = len(columns.split()) if display == 'grid' else 1
                check(label + ' layout breakpoint', count == expected_cols, f'display={display}; columns={columns}')
                check(label + ' has no horizontal overflow', vp.evaluate('document.documentElement.scrollWidth <= window.innerWidth'))
                check(label + ' keeps all form controls usable', all(vp.locator('#'+x).count() == 1 for x in ['rhReimbursementDate','rhReimbursementAmount','rhReimbursementNote','rhReimbursementFile','rhReimbursementSubmit']))
                vp.locator('#rhReimbursementAmount').fill('1000000')
                vp.locator('#rhReimbursementAmount').dispatch_event('input')
                check(label + ' keeps overbudget guidance visible', vp.locator('#rhReimbursementOverNote').evaluate("e=>getComputedStyle(e).display!='none' && e.classList.contains('is-visible')"))
                vp.close()
        finally:
            browser.close()
    passed = sum(x['status']=='PASS' for x in RESULTS)
    failed = sum(x['status']=='FAIL' for x in RESULTS)
    result = {'suite':'Reimbursement Desktop UI v73','passed':passed,'failed':failed,'total':len(RESULTS),'results':RESULTS}
    out = ROOT/'tests'/'ui'/'RESULTS.json'
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
    print(f'RESULT {passed}/{len(RESULTS)} passed; {failed} failed')
    if failed: raise SystemExit(1)

if __name__ == '__main__':
    main()
