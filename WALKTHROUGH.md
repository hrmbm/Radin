# WALKTHROUGH — HRIS Reimbursement Desktop UI v72

## Apa yang berubah

### Desktop lebar
- Ringkasan saldo dipindahkan menjadi satu baris yang mudah dibaca.
- Tab Entertain/Transport menggunakan tombol kategori yang menampilkan saldo tersedia masing-masing.
- Konten utama dibagi menjadi dua panel yang seimbang: **Pengajuan** di kiri dan **Riwayat Pengajuan** di kanan.
- Tanggal dan nominal sejajar dua kolom; catatan dan bukti transaksi menggunakan lebar penuh.
- Tombol Ajukan ditempatkan di footer form, terpisah dari instruksi dan batas lampiran.

### Desktop yang lebih sempit dan tablet
- Pada lebar 1024–1199 px, form dan riwayat tersusun vertikal untuk menjaga ukuran kontrol.
- Pada tablet 768 px, workspace tetap satu kolom.

### Mobile
- Tetap satu kolom dengan kontrol penuh lebar.
- Header Reimbursement pada layar mobile tetap berasal dari shell mobile yang sudah ada.
- Kategori, status, riwayat, bukti transaksi, dan tombol Ajukan tetap memakai ID dan fungsi pengajuan yang sama.

## Alur data dan pengajuan yang tidak diubah
1. `loadReimbursementPage()` mengambil saldo dan riwayat melalui RPC existing.
2. `paintReimbursementPage()` menampilkan saldo, kategori, form, dan riwayat.
3. `setReimbursementCategory()` mengganti kategori Entertain/Transport.
4. `updateReimbursementSubmitButton()` menghitung status Over Budget dari saldo kategori aktif.
5. `submitReimbursementRequest()` memvalidasi tanggal, nominal, catatan Over Budget, jenis/ukuran file, mengunggah bukti melalui `uploadReimbursementAttachment`, lalu mengirim `hr_submit_reimbursement_request`.
6. Sesudah sukses, halaman dimuat ulang memakai loader yang sama.

## Penggunaan preview
- `previews/reimbursement-desktop-1440.png`: layout desktop lebar dua kolom.
- `previews/reimbursement-desktop-1024.png`: desktop lebih sempit, panel ditumpuk.
- `previews/reimbursement-mobile-390.png`: tampilan mobile satu kolom.

## Cara menjalankan tes UI
`python tests/ui/test_reimbursement_ui.py`

Tes menggunakan fixture hasil ekstraksi stylesheet dan fungsi render/validasi aktual dari `index.html`. Endpoint upload dan RPC dimock agar tidak menulis data ke backend.
