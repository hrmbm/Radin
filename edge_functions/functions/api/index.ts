// supabase/functions/api/index.ts

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const supabase = createClient(

  Deno.env.get('SUPABASE_URL')!,

  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

)

// ============================================

// CORS HEADERS

// ============================================

const corsHeaders = {

  'Access-Control-Allow-Origin': '*',

  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',

  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// ============================================

// MAIN HANDLER

// ============================================

serve(async (req) => {

  if (req.method === 'OPTIONS') {

    return new Response('ok', { headers: corsHeaders })

  }

  try {

    const { fn, args } = await req.json()

    const result = await callApi(fn, args || [])

    return new Response(

      JSON.stringify({ ok: true, result }),

      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }

    )

  } catch (err: any) {

    return new Response(

      JSON.stringify({ ok: false, error: err.message || String(err) }),

      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }

    )

  }

})

// ============================================

// ROUTER (mirip callApi\_ di GAS)

// ============================================

async function callApi(fn: string, args: any[]) {

  const whitelist: Record<string, Function> = {

    login,

    getFastBootstrap,

    getStatusHariIni,

    getRiwayatKehadiran,

    getLokasiKantor,

    getMasterCuti,

    simpanAbsensi,

    uploadAbsensiFoto,

    getEvidenceSignedUrl,
    uploadReimbursementAttachment,
    getReimbursementSignedUrl,
    getReimbursementSignedUrls,
    adminDeleteReimbursement,
    matchFaceDescriptor,

    getMyProfile,

    pingServer,

    // ... tambahkan fungsi lain sesuai kebutuhan

  }

  const handler = whitelist[fn]

  if (!handler) throw new Error('Fungsi tidak diizinkan: ' + fn)

  return await handler(...args)

}

// ============================================

// FUNGSI: pingServer

// ============================================

async function pingServer() {

  return { ok: true, time: new Date().toISOString() }

}

// ============================================

// FUNGSI: login

// ============================================

async function login(nik: string, pin: string) {

  nik = String(nik || '').trim()

  pin = String(pin || '').trim()

  if (!nik || !pin) throw new Error('NIK dan PIN wajib diisi.')

  const { data, error } = await supabase

    .from('karyawan')

    .select('nik, nama, role, organization, pin, branch, status_akun')

    .eq('nik', nik)

    .single()

  if (error || !data) throw new Error('NIK atau PIN salah.')

  if (data.status_akun && data.status_akun.toUpperCase() !== 'AKTIF') throw new Error('Akun karyawan tidak aktif.')

  if (data.pin !== pin) throw new Error('NIK atau PIN salah.')

  // Format response harus persis seperti yang diharapkan frontend

  return {

    success: true,

    role: data.role || 'KARYAWAN',

    employee: {

      nik: data.nik,

      nama: data.nama,

      role: data.role || 'KARYAWAN',

      organization: data.organization || '',

      branch: data.branch || '',

      position: '', 

      level: '',

      statusKerja: '',

      atasanNama: '',

      atasanId: '',

      joinDate: ''

    }

  }

}

// ============================================

// FUNGSI: getMyProfile

// ============================================

async function getMyProfile(nik: string) {

  const { data, error } = await supabase

    .from('karyawan')

    .select('*')

    .eq('nik', nik)

    .single()

  if (error || !data) throw new Error('Profil tidak ditemukan.')

  // A Karyawan with active direct reports is an Approver. Resolve this server-side
  // and pass the flag through getFastBootstrap to the browser role/navigation layer.
  const { count: directReportCount, error: reportError } = await supabase
    .from('karyawan')
    .select('employee_id', { count: 'exact', head: true })
    .eq('approval_line_id', data.employee_id || data.nik || nik)
    .eq('status_akun', 'AKTIF')

  if (reportError) console.warn('[getMyProfile] Direct-report lookup failed:', reportError.message)
  return { ...data, hasSubordinates: (directReportCount || 0) > 0 }

}

// ============================================

// FUNGSI: getLokasiKantor

// ============================================

async function getLokasiKantor() {

  const { data } = await supabase

    .from('lokasi_kantor')

    .select('*')

    .eq('status', 'AKTIF')

  return data || []

}

// ============================================

// FUNGSI: getMasterCuti

// ============================================

async function getMasterCuti() {

  const { data } = await supabase

    .from('master_cuti')

    .select('*')

  return data || []

}

// ============================================

// FUNGSI: getStatusHariIni

// ============================================

async function getStatusHariIni(nik: string) {

  nik = String(nik || '').trim()

  const empty = { masuk: false, pulang: false, jamMasuk: '', jamPulang: '', statusApproval: 'VALID' }

  if (!nik) return empty

  const today = new Date().toISOString().split('T')[0]

  const { data } = await supabase

    .from('absensi')

    .select('tipe, jam, status_approval')

    .eq('employee_id', nik)

    .eq('tanggal', today)

  if (!data || !data.length) return empty

  const result = { ...empty }

  for (const row of data) {

    if (row.tipe === 'MASUK') {

      result.masuk = true

      result.jamMasuk = row.jam?.slice(0, 5) || ''

      result.statusApproval = row.status_approval

    }

    if (row.tipe === 'PULANG') {

      result.pulang = true

      result.jamPulang = row.jam?.slice(0, 5) || ''

    }

  }

  return result

}

// ============================================

// FUNGSI: getFastBootstrap

// (SATU PANGGILAN = SEMUA DATA)

// ============================================

async function getFastBootstrap(nik: string) {

  nik = String(nik || '').trim()

  if (!nik) throw new Error('NIK tidak tersedia.')

  // Jalankan semua query secara PARALEL (ini keunggulan besar!)

  const [profileRes, statusRes, officeRes, cutiRes, pendingRes] = await Promise.all([

    getMyProfile(nik),

    getStatusHariIni(nik),

    getLokasiKantor(),

    getSisaCuti(nik),

    getPendingTotal(nik),

  ])

  return {

    profile: profileRes,

    status: statusRes,

    office: officeRes,

    sisaCuti: cutiRes,

    faceStatus: {

      registered: profileRes.face_registered || false,

      canRegister: false, // cek dari face_registration table

    },

    pendingTotal: pendingRes,

    // get_my_profile already returns the active direct-report flag. Preserve it for
    // ordinary employees; higher privileged roles remain full-access regardless.
    hasSubordinates: profileRes.hasSubordinates === true || ['HR', 'ADMIN', 'SUPERADMIN'].includes(String(profileRes.role || '').toUpperCase()),

  }

}

async function getSisaCuti(nik: string) {

  // Hitung sisa cuti dari master_cuti - cuti yang sudah diambil

  const { data: master } = await supabase.from('master_cuti').select('kode, kuota')

  const { data: used } = await supabase

    .from('cuti')

    .select('kode, total_hari, status_atasan, status_hr')

    .eq('nik', nik)

    .eq('status_atasan', 'DISETUJUI')

    .eq('status_hr', 'DISETUJUI')

  const result: Record<string, any> = {}

  for (const m of master || []) {

    const totalUsed = (used || [])

      .filter(c => c.kode === m.kode)

      .reduce((sum, c) => sum + (c.total_hari || 0), 0)

    result[m.kode] = { kuota: m.kuota, terpakai: totalUsed, sisa: m.kuota - totalUsed }

  }

  return result

}

async function getPendingTotal(nik: string) {

  const { count } = await supabase

    .from('absensi')

    .select('*', { count: 'exact', head: true })

    .in('status_approval', ['PENDING_ATASAN', 'PENDING_HR'])

  return count || 0

}

// ============================================

// FUNGSI: getRiwayatKehadiran

// (SQL query langsung, TIDAK perlu scan semua)

// ============================================

async function getRiwayatKehadiran(nik: string, year: number, month: number) {

  const startDate = `${year}-${String(month).padStart(2, '0')}-01`

  const endDate = new Date(year, month, 0).toISOString().split('T')[0]

  const { data } = await supabase

    .from('absensi')

    .select('*')

    .eq('employee_id', nik)

    .gte('tanggal', startDate)

    .lte('tanggal', endDate)

    .order('tanggal', { ascending: false })

  // Group by tanggal (sama seperti logika GAS tapi jauh lebih cepat)

  const map: Record<string, any> = {}

  for (const row of data || []) {

    const tgl = row.tanggal

    if (!map[tgl]) map[tgl] = {}

    const detail = {

      jam: row.jam?.slice(0, 5) || '',

      fotoUrl: row.foto_url,

      latitude: row.latitude,

      longitude: row.longitude,

      accuracy: row.accuracy,

      address: row.address,

      statusApproval: row.status_approval,

      faceMatch: row.face_match,

      faceDistance: row.face_distance,

    }

    if (row.tipe === 'MASUK') map[tgl].masuk = detail

    if (row.tipe === 'PULANG') map[tgl].pulang = detail

  }

  return Object.keys(map).sort().reverse().map(tgl => {

    const item = map[tgl]

    let status = 'BELUM LENGKAP'

    if (item.masuk && item.pulang) status = 'HADIR'

    else if (item.masuk) status = 'BELUM CLOCK OUT'

    return { tanggal: tgl, status, masuk: item.masuk, pulang: item.pulang }

  })

}

// ============================================

// FUNGSI: matchFaceDescriptor (pgvector!)

// Ini adalah GAME CHANGER - face matching di DB

// ============================================

async function matchFaceDescriptor(descriptor: number[]) {

  if (!Array.isArray(descriptor) || descriptor.length !== 128) {

    throw new Error('Descriptor tidak valid.')

  }

  const { data, error } = await supabase.rpc('match_face', {

    query_descriptor: descriptor,

    match_threshold: 0.45,

    match_count: 1,

  })

  if (error) throw new Error('Face matching error: ' + error.message)

  if (!data || !data.length) return { match: false, nik: null, nama: null, distance: null }

  const best = data[0]

  return {

    match: best.distance < 0.45,

    nik: best.nik,

    nama: best.nama,

    distance: best.distance,

  }

}

// ============================================

// FUNGSI: simpanAbsensi

// (Tanpa LockService! PostgreSQL handle concurrent)

// ============================================

async function simpanAbsensi(

  nik: string, nama: string, organization: string,

  tipe: string, fotoUrl: string,

  lat: number, lon: number, acc: number, addr: string,

  faceMatch: string, faceDistance: number

) {

  nik = String(nik || '').trim()

  const now = new Date()

  const today = now.toISOString().split('T')[0]

  const jam = now.toTimeString().slice(0, 8)

  const id = crypto.randomUUID()

  // Cek apakah sudah absen tipe yang sama hari ini

  const { data: existing } = await supabase

    .from('absensi')

    .select('id')

    .eq('employee_id', nik)

    .eq('tanggal', today)

    .eq('tipe', tipe)

    .single()

  if (existing) throw new Error(`Anda sudah ${tipe} hari ini.`)

  // Tentukan status approval

  const statusApproval = 'VALID' // bisa disesuaikan logic-nya

  const { error } = await supabase.from('absensi').insert({

    id,

    tanggal: today,

    jam,

    employee_id: nik,

    nama,

    organization,

    tipe,

    foto_url: fotoUrl,

    latitude: lat,

    longitude: lon,

    accuracy: acc,

    address: addr,

    status_approval: statusApproval,

    face_match: faceMatch,

    face_distance: faceDistance,

  })

  if (error) throw new Error('Gagal menyimpan: ' + error.message)

  return {

    id,

    jam: jam.slice(0, 5),

    statusApproval,

  }

}

// ============================================

// FUNGSI: uploadAbsensiFoto

// (Supabase Storage, bukan Google Drive)

// ============================================

// ============================================
// FOTO ABSENSI PRIVATE (bucket: evidence)
// Token sesi aplikasi harus diverifikasi di SQL sebelum operasi Storage.
// Semua operasi Storage menggunakan service_role di server, tidak pernah di HTML.
// ============================================
async function uploadAbsensiFoto(token: string, absensiId: string, base64: string) {
  token = String(token || '').trim()
  absensiId = String(absensiId || '').trim()
  base64 = String(base64 || '')
  if (!token) throw new Error('Sesi tidak tersedia. Silakan login ulang.')
  if (!absensiId) throw new Error('ID absensi tidak tersedia.')
  const match = base64.match(/^data:image\/jpeg;base64,([A-Za-z0-9+/=]+)$/)
  if (!match) throw new Error('Foto harus berupa JPEG yang valid.')
  const binary = atob(match[1])
  if (binary.length < 100 || binary.length > 5 * 1024 * 1024) {
    throw new Error('Ukuran foto tidak valid atau melebihi 5 MB.')
  }

  const auth = await supabase.rpc('authorize_evidence_upload', {
    p_token: token,
    p_absensi_id: absensiId,
  })
  if (auth.error) throw new Error('Validasi sesi/foto gagal: ' + auth.error.message)
  const authData = typeof auth.data === 'string' ? JSON.parse(auth.data) : auth.data
  if (!authData || authData.success !== true || !authData.storage_path) {
    throw new Error('Sesi atau kepemilikan absensi tidak valid.')
  }

  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0))
  const path = String(authData.storage_path)
  const { error: uploadError } = await supabase.storage
    .from('evidence')
    .upload(path, bytes, {
      contentType: 'image/jpeg',
      upsert: true,
      cacheControl: '3600',
    })
  if (uploadError) throw new Error('Upload foto gagal: ' + uploadError.message)

  const saved = await supabase.rpc('save_evidence_path', {
    p_token: token,
    p_absensi_id: absensiId,
    p_storage_path: path,
    p_public_url: null,
  })
  if (saved.error) throw new Error('Foto terunggah, tetapi path gagal disimpan: ' + saved.error.message)
  return { success: true, id: absensiId, storagePath: path }
}

async function getEvidenceSignedUrl(token: string, storagePath: string) {
  token = String(token || '').trim()
  storagePath = String(storagePath || '').trim()
  if (!token) throw new Error('Sesi tidak tersedia. Silakan login ulang.')
  if (!storagePath || storagePath.length > 500) throw new Error('Path foto tidak valid.')

  const auth = await supabase.rpc('authorize_evidence_access', {
    p_token: token,
    p_storage_path: storagePath,
  })
  if (auth.error) throw new Error('Akses foto ditolak: ' + auth.error.message)
  const authData = typeof auth.data === 'string' ? JSON.parse(auth.data) : auth.data
  if (!authData || authData.success !== true) throw new Error('Anda tidak berhak melihat foto bukti ini.')

  const { data, error } = await supabase.storage
    .from('evidence')
    .createSignedUrl(storagePath, 60 * 60)
  if (error) throw new Error('Gagal membuat tautan foto privat: ' + error.message)
  if (!data?.signedUrl) throw new Error('Tautan foto privat tidak tersedia.')
  return { success: true, signedUrl: data.signedUrl }
}


// ============================================
// PRIVATE REIMBURSEMENT ATTACHMENTS
// Legacy Storage bucket id: allowance-attachments (private), retained for existing evidence files. Session and request ownership are
// validated by SQL RPCs before the service-role client touches Storage.
// ============================================
async function uploadReimbursementAttachment(token: string, category: string, dataUrl: string) {
  token = String(token || '').trim()
  category = String(category || '').trim().toUpperCase()
  dataUrl = String(dataUrl || '')
  if (!token) throw new Error('Sesi tidak tersedia. Silakan login ulang.')
  if (!['ENTERTAIN', 'TRANSPORT'].includes(category)) throw new Error('Kategori reimbursement tidak valid.')

  const match = dataUrl.match(/^data:(image\/(?:jpeg|png|webp)|application\/pdf);base64,([A-Za-z0-9+/=]+)$/i)
  if (!match) throw new Error('Lampiran harus berupa JPG, PNG, WEBP, atau PDF yang valid.')
  const mime = match[1].toLowerCase()
  const binary = atob(match[2])
  if (binary.length < 100 || binary.length > 8 * 1024 * 1024) {
    throw new Error('Ukuran lampiran tidak valid atau melebihi 8 MB.')
  }

  const auth = await supabase.rpc('authorize_reimbursement_attachment_upload', {
    p_token: token,
    p_category: category,
  })
  if (auth.error) throw new Error('Validasi lampiran gagal: ' + auth.error.message)
  const authData = typeof auth.data === 'string' ? JSON.parse(auth.data) : auth.data
  if (!authData || authData.success !== true || !authData.storage_path) {
    throw new Error('Sesi atau hak upload lampiran tidak valid.')
  }

  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0))
  const storagePath = String(authData.storage_path)
  const { error: uploadError } = await supabase.storage
    .from('allowance-attachments')
    .upload(storagePath, bytes, { contentType: mime, upsert: false, cacheControl: '3600' })
  if (uploadError) throw new Error('Upload lampiran gagal: ' + uploadError.message)

  const saved = await supabase.rpc('confirm_reimbursement_attachment_upload', {
    p_token: token,
    p_storage_path: storagePath,
  })
  if (saved.error) throw new Error('Lampiran terunggah tetapi konfirmasi gagal: ' + saved.error.message)
  return { success: true, storagePath }
}

async function getReimbursementSignedUrl(token: string, storagePath: string) {
  token = String(token || '').trim()
  storagePath = String(storagePath || '').trim()
  if (!token) throw new Error('Sesi tidak tersedia. Silakan login ulang.')
  if (!storagePath || storagePath.length > 500) throw new Error('Path lampiran tidak valid.')

  const auth = await supabase.rpc('authorize_reimbursement_attachment_access', {
    p_token: token,
    p_storage_path: storagePath,
  })
  if (auth.error) throw new Error('Akses lampiran ditolak: ' + auth.error.message)
  const authData = typeof auth.data === 'string' ? JSON.parse(auth.data) : auth.data
  if (!authData || authData.success !== true) throw new Error('Anda tidak berhak melihat lampiran ini.')

  const { data, error } = await supabase.storage
    .from('allowance-attachments')
    .createSignedUrl(storagePath, 60 * 60)
  if (error) throw new Error('Gagal membuat tautan lampiran privat: ' + error.message)
  if (!data?.signedUrl) throw new Error('Tautan lampiran tidak tersedia.')
  return { success: true, signedUrl: data.signedUrl }
}


async function getReimbursementSignedUrls(token: string, storagePaths: string[]) {
  token = String(token || '').trim()
  const paths = Array.isArray(storagePaths) ? storagePaths.map((x) => String(x || '').trim()).filter(Boolean) : []
  if (!token) throw new Error('Sesi tidak tersedia. Silakan login ulang.')
  if (!paths.length || paths.length > 100 || paths.some((x) => x.length > 500)) {
    throw new Error('Daftar lampiran tidak valid (maksimal 100 file per permintaan).')
  }

  const auth = await supabase.rpc('authorize_reimbursement_attachment_access_batch', {
    p_token: token,
    p_storage_paths: paths,
  })
  if (auth.error) throw new Error('Akses lampiran ditolak: ' + auth.error.message)
  const authData = typeof auth.data === 'string' ? JSON.parse(auth.data) : auth.data
  if (!authData || authData.success !== true) throw new Error('Anda tidak berhak melihat semua lampiran yang diminta.')

  const { data, error } = await supabase.storage
    .from('allowance-attachments')
    .createSignedUrls(paths, 60 * 60)
  if (error) throw new Error('Gagal membuat tautan lampiran privat: ' + error.message)
  const signedUrls = (data || []).map((item: any) => ({ path: item.path, signedUrl: item.signedUrl }))
  return { success: true, signedUrls }
}


// Delete is authorized by the database RPC (SUPERADMIN-only). The returned
// private Storage path is removed only after the database transaction succeeds.
async function adminDeleteReimbursement(token: string, requestId: string) {
  token = String(token || '').trim()
  requestId = String(requestId || '').trim()
  if (!token) throw new Error('Sesi tidak tersedia. Silakan login ulang.')
  if (!requestId || requestId.length > 200) throw new Error('ID pengajuan Reimbursement tidak valid.')

  const { data, error } = await supabase.rpc('admin_delete_reimbursement', {
    p_token: token,
    p_request_id: requestId,
  })
  if (error) throw new Error('Penghapusan Reimbursement gagal: ' + error.message)
  const result = typeof data === 'string' ? JSON.parse(data) : data
  if (!result || result.success !== true) throw new Error((result && result.message) || 'Pengajuan Reimbursement tidak dapat dihapus.')

  const storagePaths = Array.from(new Set((Array.isArray(result.attachment_paths)
    ? result.attachment_paths
    : [result.attachment_path]).map((path: unknown) => String(path || '').trim()).filter(Boolean)))
  if (!storagePaths.length) return { ...result, attachmentCleanupOk: true }

  const { error: removeError } = await supabase.storage
    .from('allowance-attachments')
    .remove(storagePaths)
  if (removeError) {
    return { ...result, attachmentCleanupOk: false, attachmentCleanupMessage: removeError.message }
  }
  return { ...result, attachmentCleanupOk: true }
}

