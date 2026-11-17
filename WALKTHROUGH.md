# Walkthrough — Rekap Absensi Fix v73

## Penyebab
`SESSION_GEN` dideklarasikan dengan `var` di top-level `<script type="module">`. Sementara `fetchAttendanceMonitoring()` dan `showAttendanceMetricDetail()` berada di `<script>` klasik terpisah. Variabel top-level ES module tidak menjadi global `window`, sehingga akses langsung dari script klasik menghasilkan `ReferenceError` sebelum RPC `hr_get_attendance_monitoring` dikirim.

## Perbaikan
- Menambahkan `window.rhGetSessionGeneration()` di dalam module. Accessor membaca nilai SESSION_GEN terkini, bukan salinan awal.
- Menambahkan helper `attMonitorSessionGeneration()` di script desktop klasik.
- Mengganti dua referensi langsung SESSION_GEN pada key cache detail Rekap Absensi dengan helper tersebut.
- Tidak mengubah broker RPC, parameter `hr_get_attendance_monitoring`, SQL, atau otorisasi.
- Memperbarui marker HTML dan Service Worker ke v73 agar browser mengambil release baru.

## Dampak yang diharapkan
Klik Rekap Absensi tidak lagi berhenti pada ReferenceError; alur dapat melanjutkan hingga request RPC `hr_get_attendance_monitoring`. Jika backend masih memiliki error, error itu akan muncul pada lapisan RPC dan bisa didiagnosis terpisah.
