# PLAN — Paket C: Pengajuan Reimbursement Desktop

## Tujuan
Menambahkan navigasi desktop **Reimbursement → Pengajuan Reimbursement** untuk pengguna dengan `job_code = HYBRID`.

## Cakupan
- Menambahkan grup menu dan halaman desktop.
- Memindahkan node `#reimbursementApp` yang sudah ada ke mount desktop; tidak membuat form/RPC duplikat.
- Mengembalikan node ke mount mobile saat desktop dinonaktifkan.
- Hanya Hybrid dapat memuat data. Role lain melihat placeholder aman dengan blur/overlay seperti pembatasan desktop lain.

## Batas keamanan
Pengecekan Hybrid tetap di frontend sebagai kontrol UX; RPC/backend existing tetap menjadi otoritas data dan validasi. Admin read-only tidak memperoleh akses pengajuan meskipun job code-nya Hybrid.
