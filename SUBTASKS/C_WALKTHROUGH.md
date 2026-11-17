# WALKTHROUGH — Paket C

1. Sidebar desktop menampilkan grup Reimbursement dan submenu Pengajuan Reimbursement.
2. Halaman desktop menempatkan mount `#rkDeskReimbursementMount`.
3. Renderer memindahkan node `#reimbursementApp` existing ke mount desktop dan memanggil loader existing, sehingga tidak ada duplikasi ID/form.
4. `loadReimbursementPage()` menolak non-Hybrid tanpa mengambil data; tampilan diburamkan dan overlay Limited Access ditampilkan.
5. Saat desktop dinonaktifkan, node dikembalikan ke parent mobile semula.
