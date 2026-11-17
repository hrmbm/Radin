'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const sw = fs.readFileSync(path.join(root, 'sw.js'), 'utf8');
let passed = 0, failed = 0;
function check(name, ok) {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
  if (ok) passed++; else failed++;
}
function extractBetween(startText, endText) {
  const start = html.indexOf(startText);
  const end = html.indexOf(endText, start);
  return start >= 0 && end > start ? html.slice(start, end) : '';
}
(async function run() {
  // Single RPC broker and no more direct PostgREST RPCs outside its implementation.
  const rpcCalls = html.match(/\.rpc\(/g) || [];
  check('all database RPC requests pass through one central client.rpc call', rpcCalls.length === 1 && /function rpcUncached[\s\S]{0,900}c\.rpc\(fn, params\)/.test(html));
  check('classic desktop RPCs use the canonical window.rhRpc bridge', /rhRpc: function\(fn, params, timeoutMs\)/.test(html) && /function rpcOptionalDirect[\s\S]{0,1500}window\.rhRpc\(fn, args, timeout\)/.test(html));
  check('attendance live map and monitoring use the canonical RPC broker', /window\.rhRpc\('hr_get_attendance_monitoring'/.test(html) && /window\.rhRpc\('hr_get_attendance_summary'/.test(html));
  check('day-off attendance context uses the core RPC wrapper', /async function rhReadRpcForDayOff[\s\S]{0,500}return await rpc\(fn, args, 20000\)/.test(html));
  check('optional reads no longer use an outer token-bearing dedupe cache', !/rhReadDedupe\('opt\|/.test(html));

  // Dedupe/cache safeguards.
  const cacheStart = html.indexOf('var RH_READ_DEDUPE_TTL =');
  const cacheEnd = html.indexOf('var RH_RPC_READ_WHITELIST', cacheStart);
  const cacheCode = cacheStart >= 0 && cacheEnd > cacheStart ? html.slice(cacheStart, cacheEnd) : '';
  check('read dedupe has a fixed maximum entry count', /RH_READ_DEDUPE_MAX\s*=\s*96/.test(cacheCode));
  check('read dedupe purges expired settled entries and bounds cache size', /function rhReadDedupeTrim\(\)[\s\S]*?RH_READ_DEDUPE_MAX[\s\S]*?delete RH_READ_DEDUPE\[oldestKey\]/.test(cacheCode));
  check('rejected read promises are removed so retries can issue a fresh request', /function rhReadDedupe\([\s\S]*?function\(error\)[\s\S]*?delete RH_READ_DEDUPE\[cacheKey\]/.test(cacheCode));
  check('read cache keys omit p_token and other credential fields', /function rhReadParamsKey\([\s\S]*?p_token\|token\|access_token\|authorization/.test(html));
  check('read cache scope is isolated by session generation, user and role', /function rhReadSessionScope\([\s\S]*?SESSION_GEN[\s\S]*?user\.nik[\s\S]*?user\.role/.test(html));
  check('all get_ and hr_get_ reads are recognized for dedupe', /RH_RPC_READ_WHITELIST\s*=\s*\/\^\(\?:get_\[a-z0-9_\]\+\|hr_get_\[a-z0-9_\]\+/.test(html));

  // Runtime tests for cache correctness.
  const withTimeoutStart = html.indexOf('function withTimeout(');
  const withTimeoutEnd = html.indexOf('\n\nvar SESSION_GEN', withTimeoutStart);
  const withTimeoutCode = withTimeoutStart >= 0 && withTimeoutEnd > withTimeoutStart ? html.slice(withTimeoutStart, withTimeoutEnd) : '';
  const timeoutContext = { setTimeout: function(){ timeoutContext.setCount++; return 9; }, clearTimeout: function(id){ timeoutContext.clearCount++; }, setCount:0, clearCount:0, Promise:Promise, Error:Error };
  vm.createContext(timeoutContext);
  vm.runInContext(withTimeoutCode + '\nthis.testWithTimeout=withTimeout;', timeoutContext);
  const timeoutResult = await timeoutContext.testWithTimeout(Promise.resolve('ok'), 500, 'test');
  check('successful requests clear their timeout timer immediately', timeoutResult === 'ok' && timeoutContext.setCount === 1 && timeoutContext.clearCount === 1);

  const dedupeContext = { Date:Date, Promise:Promise, Object:Object, Infinity:Infinity };
  vm.createContext(dedupeContext);
  vm.runInContext(cacheCode + '\nthis.callDedupe=rhReadDedupe;this.trimDedupe=rhReadDedupeTrim;this.cache=RH_READ_DEDUPE;', dedupeContext);
  let reads = 0, release;
  const pending = new Promise(resolve => { release = resolve; });
  const a = dedupeContext.callDedupe('same', () => { reads++; return pending; });
  const b = dedupeContext.callDedupe('same', () => { reads++; return Promise.resolve('duplicate'); });
  check('concurrent identical reads share one in-flight Promise', a === b && reads === 0);
  release('shared');
  const vals = await Promise.all([a,b]);
  check('shared read resolves once for all callers', reads === 1 && vals[0] === 'shared' && vals[1] === 'shared');
  let failedCalls = 0;
  try { await dedupeContext.callDedupe('retry', () => { failedCalls++; return Promise.reject(new Error('first failure')); }); } catch (_) {}
  const retry = await dedupeContext.callDedupe('retry', () => { failedCalls++; return Promise.resolve('recovered'); });
  check('a rejected read can be retried immediately without reusing its error', failedCalls === 2 && retry === 'recovered');
  dedupeContext.RH_READ_DEDUPE_MAX = 3;
  for (let i=0;i<10;i++) await dedupeContext.callDedupe('bounded-'+i, () => Promise.resolve(i));
  check('read dedupe runtime cache remains within configured bound', Object.keys(dedupeContext.cache).length <= 3);

  const paramsFns = extractBetween('function rhReadSessionScope()', 'var RH_RPC_READ_WHITELIST');
  const scopeContext = { SESSION_GEN:4, S:{user:{nik:'EMP-1',role:'KARYAWAN'}}, Object:Object, String:String, JSON:JSON };
  vm.createContext(scopeContext);
  vm.runInContext(paramsFns + '\nthis.scope=rhReadSessionScope;this.params=rhReadParamsKey;', scopeContext);
  const safeKey = scopeContext.params({p_token:'SECRET-TOKEN',p_start_date:'2026-11-01'});
  const firstScope = scopeContext.scope();
  scopeContext.SESSION_GEN = 5;
  const secondScope = scopeContext.scope();
  check('credential values are absent from serialized cache-key parameters', safeKey.indexOf('SECRET-TOKEN') < 0 && safeKey.indexOf('2026-11-01') >= 0);
  check('cache scope changes when the login generation changes', firstScope !== secondScope);

  // Duplicate-prewarm protection and data reuse.
  check('Time Off reference prewarm is single-flight for the current session', /var RH_TIMEOFF_PREWARM_PROMISE = null[\s\S]*?if \(RH_TIMEOFF_PREWARM_PROMISE && RH_TIMEOFF_PREWARM_GEN === gen\) return RH_TIMEOFF_PREWARM_PROMISE/.test(html));
  check('Time Off prewarm ignores stale-session completions', /function prewarmTimeoffReferenceData\(\)[\s\S]*?if \(stale\(gen\)\) return/.test(html));
  check('team prewarm reuses the same-user, same-session, same-day result for 30 seconds', /teamMeta\.nik === String\(S\.user\.nik\)[\s\S]*?teamMeta\.gen === gen[\s\S]*?teamMeta\.date === teamDate[\s\S]*?< 30000/.test(html));
  check('team fetch records a session-scoped cache timestamp', /function loadTeam\(\)[\s\S]*?DATA\._teamMeta = \{ nik:nik, gen:gen, date:date, at:Date\.now\(\) \}/.test(html));
  check('no-clock-in detail query is reused for the same session and date range', /noInDetailKey[\s\S]*?noInDetailRows[\s\S]*?noInDetailPromise[\s\S]*?window\.rhRpc\('hr_get_attendance_summary'/.test(html));
  check('attendance range refresh invalidates the previous no-clock-in detail cache', /attMonitorState\.from=from;attMonitorState\.to=to;attMonitorState\.loaded=false;[\s\S]{0,240}noInDetailRows=null;attMonitorState\.noInDetailPromise=null/.test(html));

  // HR dashboard and directory data minimization.
  const prewarmStart = html.indexOf('async function prewarmSemiStaticData()');
  const prewarmEnd = html.indexOf('function loadMyDescriptor()', prewarmStart);
  const prewarmCode = prewarmStart >= 0 && prewarmEnd > prewarmStart ? html.slice(prewarmStart, prewarmEnd) : '';
  check('HR/Admin login prewarm reads local caches but no longer fetches a full company directory', /directoryRole[\s\S]*?kvGet\('empSummary'\)[\s\S]*?kvGet\('karData'\)[\s\S]*?rows = \[\]/.test(prewarmCode) && !/getKaryawanSummary|getKaryawanOptions/.test(prewarmCode));
  check('company-wide employee face photos are not prewarmed during HR/Admin login', /Intentionally do not warm the company-wide photo list here/.test(prewarmCode));
  const dashStart = html.indexOf('function renderDash()');
  const dashEnd = html.indexOf('function setDashStat(', dashStart);
  const dashCode = dashStart >= 0 && dashEnd > dashStart ? html.slice(dashStart, dashEnd) : '';
  check('dashboard uses the role-secured compact employee directory summary', /hr_get_employee_directory_summary/.test(dashCode) && !/hr_get_employee_directory'/.test(dashCode));
  check('dashboard no longer triggers the employee-manager catalog preload', !/ensureKar\(false\)/.test(dashCode));
  check('dashboard does not request unused face-progress data', !/getFaceProgress/.test(dashCode) && !/dashCache\.fp/.test(dashCode));
  check('dashboard refresh reuses the queue result already fetched for rendering', /function refreshBadge\(queueResult\)[\s\S]*?queuePromise = queueResult \? Promise.resolve\(queueResult\) : window\.loadApprovalQueueCanonical/.test(html) && /refreshBadge\(\{ data: dashCache\.ap \|\| \{\} \}\)/.test(dashCode));
  check('dashboard does not request full personal, bank or identity fields by default', !/rpcOptional\('hr_get_employee_directory', \{\}\)/.test(dashCode));
  check('dashboard edit action fetches full employee details only after explicit edit click and Superadmin check', /data-dash-attention-edit[\s\S]*?if \(!isSuperAdminRole\(\)\)[\s\S]*?rpcOptional\('hr_get_employee_directory', \{\}\)/.test(html));
  check('non-Superadmin dashboard users are blocked before full personal directory fetch', /if \(!isSuperAdminRole\(\)\) \{ rkToast\('Akses lihat saja\. Hanya Superadmin dapat mengubah data karyawan\.'\); return; \}[\s\S]{0,180}rpcOptional\('hr_get_employee_directory', \{\}\)/.test(html));
  check('dashboard missing-data cards use server-provided boolean field-presence flags', /function dashAttentionRows[\s\S]*?x\.has_phone !== true[\s\S]*?x\.has_religion !== true[\s\S]*?x\.has_education !== true/.test(html));
  check('dashboard profile and edit actions keep full-detail loading outside initial dashboard path', /function empOpenDetails[\s\S]*?empLoadDetailExtra\(wanted\)/.test(html) && /data-dash-attention-edit[\s\S]*?empOpenEditor\(editNik,'edit'\)/.test(html));

  // Duplicate screen navigation and directory request protection.
  check('employee manager menu relies on go() as its single screen loader', /id="menuKaryawanMgr"[^>]*onclick="go\('s-kar'\)"/.test(html));
  check('employee manager network loads are single-flight per session generation', /var RH_KAR_MGR_PROMISE = null[\s\S]*?if \(RH_KAR_MGR_PROMISE && RH_KAR_MGR_PROMISE_GEN === SESSION_GEN\) return RH_KAR_MGR_PROMISE[\s\S]*?RH_KAR_MGR_PROMISE_GEN = gen/.test(html));

  // Database/source audit invariants and release.
  check('frontend does not open Supabase realtime subscriptions', !/\.channel\s*\(|\.subscribe\s*\(/.test(html));
  check('Stage 4 release marker matches Service Worker and shell cache', /content="v14\.7\.19-stage4-attendance-monitor-session-scope-fix"/.test(html) && /RH_EXPECTED_HTML_RELEASE = 'v14\.7\.19-stage4-attendance-monitor-session-scope-fix'/.test(sw) && /rehholz-app-shell-v73/.test(sw) && /v73-attendance-monitor-session-scope-fix/.test(sw));

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})().catch(error => { console.error(error); process.exit(1); });
