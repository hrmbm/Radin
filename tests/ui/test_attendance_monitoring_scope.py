"""Runtime regression for SESSION_GEN ES-module/classic-script boundary."""
from pathlib import Path
import re
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
HTML = (ROOT / 'index.html').read_text(encoding='utf-8')

# Extract the live accessor exactly as shipped in the module.
module_match = re.search(
    r"var SESSION_GEN = 0;\s*function stale\(gen\) \{ return gen !== SESSION_GEN; \}\s*"
    r"// Expose a live accessor[\s\S]*?window\.rhGetSessionGeneration = function\(\) \{ return SESSION_GEN; \};",
    HTML,
)
assert module_match, 'Module session-generation bridge not found'
module_code = module_match.group(0) + "\nwindow.__testBumpSession = function(){ SESSION_GEN++; };"

helper_match = re.search(
    r"function attMonitorSessionGeneration\(\)\s*\{[\s\S]*?\n  \}", HTML
)
assert helper_match, 'Desktop session generation helper not found'
helper_code = helper_match.group(0)

# Extract the actual fetchAttendanceMonitoring function by balanced braces.
fetch_start = HTML.index('  function fetchAttendanceMonitoring()')
brace_start = HTML.index('{', fetch_start)
depth = 0
quote = None
escaped = False
line_comment = False
block_comment = False
fetch_end = None
idx = brace_start
while idx < len(HTML):
    ch = HTML[idx]
    nxt = HTML[idx + 1] if idx + 1 < len(HTML) else ''
    if line_comment:
        if ch == '\n':
            line_comment = False
        idx += 1
        continue
    if block_comment:
        if ch == '*' and nxt == '/':
            block_comment = False
            idx += 2
        else:
            idx += 1
        continue
    if quote:
        if escaped:
            escaped = False
        elif ch == '\\':
            escaped = True
        elif ch == quote:
            quote = None
        idx += 1
        continue
    if ch == '/' and nxt == '/':
        line_comment = True
        idx += 2
        continue
    if ch == '/' and nxt == '*':
        block_comment = True
        idx += 2
        continue
    if ch in "'\"`":
        quote = ch
        idx += 1
        continue
    if ch == '{':
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0:
            fetch_end = idx + 1
            break
    idx += 1
assert fetch_end, 'Could not isolate fetchAttendanceMonitoring function'
fetch_code = HTML[fetch_start:fetch_end]

classic_code = r"""
var attMonitorState = {
  from:'', to:'', loaded:false, source:'', payload:null, rows:[],
  noInDetailKey:'', noInDetailRows:null, noInDetailPromise:null
};
function attMonHasPayload(payload) { return !!payload && Array.isArray(payload.records); }
function attMonRows(payload) { return payload.records; }
function paintAttendanceMonitoringSummary() {}
function paintAttendanceMonitoringRows() {}
function rkToast(message) { window.__toast = message; }
window.__rpcCalls = [];
window.rhRpc = function(fn, params, timeout) {
  window.__rpcCalls.push({fn:fn, params:params, timeout:timeout});
  return Promise.resolve({records:[{id:'test-row'}]});
};
""" + helper_code + "\n" + fetch_code + r"""
window.__testFetchAttendance = fetchAttendanceMonitoring;
window.__getAttendanceState = function(){ return JSON.parse(JSON.stringify(attMonitorState)); };
"""

page_errors = []
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, executable_path='/usr/bin/chromium', args=['--no-sandbox'])
    page = browser.new_page()
    page.on('pageerror', lambda error: page_errors.append(str(error)))
    page.set_content('''<!doctype html><html><head><meta charset="utf-8"></head><body>
      <input id="rkAttFrom" value="2026-11-01">
      <input id="rkAttTo" value="2026-11-17">
      <table><tbody id="rkAttMonitorBody"></tbody></table>
      <button id="rkAttFetch">Tampilkan Absensi</button>
      <span id="rkAttMonitorCount"></span>
      <script type="module">''' + module_code + '''</script>
      <script>''' + classic_code + '''</script>
    </body></html>''', wait_until='load')
    page.wait_for_function("typeof window.rhGetSessionGeneration === 'function' && typeof window.__testFetchAttendance === 'function'")

    # First load must cross the classic-script -> ES-module bridge and call the expected RPC.
    page.evaluate('window.__testFetchAttendance()')
    page.wait_for_function("window.__getAttendanceState().loaded === true")
    first = page.evaluate("({ calls:window.__rpcCalls.slice(), state:window.__getAttendanceState(), gen:window.rhGetSessionGeneration() })")
    assert first['gen'] == 0, first
    assert first['state']['noInDetailKey'] == '0|2026-11-01|2026-11-17', first
    assert len(first['calls']) == 1 and first['calls'][0]['fn'] == 'hr_get_attendance_monitoring', first
    assert first['calls'][0]['params'] == {'p_start_date':'2026-11-01','p_end_date':'2026-11-17'}, first

    # A later login/session change must be visible through the live accessor and change the cache key.
    page.evaluate('window.__testBumpSession()')
    page.evaluate('window.__testFetchAttendance()')
    page.wait_for_function("window.__rpcCalls.length === 2")
    second = page.evaluate("({ calls:window.__rpcCalls.slice(), state:window.__getAttendanceState(), gen:window.rhGetSessionGeneration() })")
    assert second['gen'] == 1, second
    assert second['state']['noInDetailKey'] == '1|2026-11-01|2026-11-17', second
    assert len(second['calls']) == 2, second
    assert not page_errors, page_errors
    print('PASS actual fetchAttendanceMonitoring executes without SESSION_GEN ReferenceError')
    print('PASS first fetch calls hr_get_attendance_monitoring with expected date parameters')
    print('PASS cache key tracks live session generation after login/session change')
    print('PASS no uncaught browser page errors')
    browser.close()
