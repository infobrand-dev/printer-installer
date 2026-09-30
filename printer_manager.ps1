# Printer Manager - Canon G1010 / G2020 via Wavlink print server (RAW 9100)
#
# Cara pakai:
#   - Lokal  : klik dua kali printer_manager.bat (driver diambil dari folder Canon_Driver).
#   - Client : buka PowerShell, jalankan:
#                irm https://infobrand.id/r/_printer | iex
#              (shortlink -> redirect ke file ini), driver diunduh otomatis dari $ServerUrl.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # download jauh lebih cepat di PowerShell 5.1
# GitHub hanya menerima TLS 1.2+, Windows 10 lama kadang default ke TLS 1.0
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------- Konfigurasi ----------------
$ScriptUrl   = 'https://infobrand.id/r/_printer'   # dipakai saat relaunch sebagai Administrator
$ServerUrl   = 'https://raw.githubusercontent.com/infobrand-dev/printer-installer/main'   # lokasi folder drivers/
$PrinterName = 'Printer Canon Wavlink'
$DefaultIP   = '192.168.1.55'
$RawPort     = 9100
# Folder = nama folder di Canon_Driver, Zip = nama file di $ServerUrl/drivers/
$Models = @(
    @{ Name = 'Canon G1010 series'; Folder = 'g10106.inf_amd64_4f0db5b99c6a3d48';  Zip = 'G1010.zip' },
    @{ Name = 'Canon G2020 series'; Folder = 'g2020p6.inf_amd64_b440bf34c56299f8'; Zip = 'G2020.zip' }
)
# ---------------------------------------------

# Dijalankan via "irm | iex" (tidak ada file lokal) atau dari file .ps1
$IsRemote = [string]::IsNullOrEmpty($PSCommandPath)

# Minta hak Administrator jika belum
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Meminta akses Administrator...' -ForegroundColor Yellow
    if ($IsRemote) {
        $launch = "-NoProfile -ExecutionPolicy Bypass -Command `"irm '$ScriptUrl' | iex`""
    } else {
        $launch = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    }
    Start-Process powershell -Verb RunAs -ArgumentList $launch
    return
}

function Write-Ok($msg)   { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Confirm-YesNo($question) {
    $ans = Read-Host "$question (y/n)"
    return $ans -match '^(y|ya|yes)$'
}

function Test-TcpPort($ip, $port, $timeoutMs = 2000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($ip, $port)
        return ($task.Wait($timeoutMs) -and $client.Connected)
    } catch { return $false } finally { $client.Dispose() }
}

# Kembalikan folder driver untuk model: pakai folder lokal jika ada, jika tidak unduh dari server
function Get-DriverPath($entry) {
    if (-not $IsRemote) {
        $local = Join-Path $PSScriptRoot "Canon_Driver\$($entry.Folder)"
        if (Test-Path $local) { return $local }
    }

    $work = Join-Path $env:TEMP 'CanonPrinterDriver'
    $zip  = Join-Path $work $entry.Zip
    $dest = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($entry.Zip))
    New-Item -ItemType Directory -Force $work | Out-Null

    Write-Host "Mengunduh driver $($entry.Zip) dari $ServerUrl ..."
    Invoke-WebRequest -Uri "$ServerUrl/drivers/$($entry.Zip)" -OutFile $zip -UseBasicParsing
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    Remove-Item -Force $zip
    return $dest
}

function Show-Printers {
    $list = @(Get-Printer | Sort-Object Name)
    if ($list.Count -eq 0) { Write-Host '(Tidak ada printer terpasang)'; return @() }
    for ($i = 0; $i -lt $list.Count; $i++) {
        "{0,3}. {1}  [driver: {2}] [port: {3}]" -f ($i + 1), $list[$i].Name, $list[$i].DriverName, $list[$i].PortName | Write-Host
    }
    return $list
}

function Install-CanonPrinter {
    Write-Host ''
    Write-Host '=== INSTALL PRINTER ===' -ForegroundColor Cyan

    # 1. IP
    $ip = Read-Host "IP print server Wavlink [default $DefaultIP]"
    if ([string]::IsNullOrWhiteSpace($ip)) { $ip = $DefaultIP }
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$parsed)) { Write-Err "IP tidak valid: $ip"; return }

    if (Test-TcpPort $ip $RawPort) {
        Write-Ok "Print server $ip`:$RawPort bisa dihubungi."
    } else {
        Write-Warn "Tidak bisa terhubung ke $ip`:$RawPort (printer mati / beda jaringan / IP salah)."
        if (-not (Confirm-YesNo 'Tetap lanjut install?')) { return }
    }

    # 2. Model
    Write-Host 'Pilih model printer:'
    for ($i = 0; $i -lt $Models.Count; $i++) { Write-Host "  $($i + 1). $($Models[$i].Name)" }
    $sel = Read-Host 'Nomor model'
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $Models.Count) { Write-Err 'Pilihan tidak valid.'; return }
    $entry = $Models[[int]$sel - 1]
    $model = $entry.Name

    # 3. Driver ke Driver Store
    if (-not (Get-PrinterDriver -Name $model -ErrorAction SilentlyContinue)) {
        try { $driverDir = Get-DriverPath $entry }
        catch { Write-Err "Gagal mengambil driver: $($_.Exception.Message)"; return }

        Write-Host 'Menambahkan driver ke Windows (pnputil)...'
        & pnputil.exe /add-driver (Join-Path $driverDir '*.inf') /subdirs /install | Out-Null
    # 0 = sukses, 3010 = sukses perlu restart, 259 = tidak ada device yang di-update (tetap OK)
        if ($LASTEXITCODE -notin 0, 259, 3010) { Write-Warn "pnputil selesai dengan kode $LASTEXITCODE, mencoba lanjut..." }
    }

    try {
        if (-not (Get-PrinterDriver -Name $model -ErrorAction SilentlyContinue)) {
            Add-PrinterDriver -Name $model
        }
        Write-Ok "Driver '$model' terpasang."
    } catch {
        Write-Err "Gagal memasang driver '$model': $($_.Exception.Message)"
        return
    }

    # 4. Port TCP/IP RAW
    $portName = "IP_$ip"
    try {
        if (-not (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {
            Add-PrinterPort -Name $portName -PrinterHostAddress $ip -PortNumber $RawPort
        }
        Write-Ok "Port $portName siap."
    } catch {
        Write-Err "Gagal membuat port: $($_.Exception.Message)"
        return
    }

    # 5. Printer
    if (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue) {
        Write-Warn "Printer '$PrinterName' sudah ada."
        if (-not (Confirm-YesNo 'Ganti dengan yang baru?')) { return }
        Remove-PrinterSafe $PrinterName -KeepPort:$true
    }
    try {
        Add-Printer -Name $PrinterName -DriverName $model -PortName $portName
        Write-Ok "Printer '$PrinterName' ($model) berhasil terpasang di $ip."
    } catch {
        Write-Err "Gagal menambahkan printer: $($_.Exception.Message)"
        return
    }

    # 6. Default + test page
    try {
        Get-CimInstance Win32_Printer -Filter "Name='$PrinterName'" | Invoke-CimMethod -MethodName SetDefaultPrinter | Out-Null
        Write-Ok 'Dijadikan printer default.'
    } catch { Write-Warn "Gagal set default: $($_.Exception.Message)" }

    if (Confirm-YesNo 'Cetak test page sekarang?') {
        Get-CimInstance Win32_Printer -Filter "Name='$PrinterName'" | Invoke-CimMethod -MethodName PrintTestPage | Out-Null
        Write-Ok 'Test page dikirim.'
    }
}

function Remove-PrinterSafe {
    param([string]$Name, [switch]$KeepPort, [switch]$RemoveDriver)

    $p = Get-Printer -Name $Name -ErrorAction SilentlyContinue
    if (-not $p) { Write-Warn "Printer '$Name' tidak ditemukan."; return }
    $portName = $p.PortName
    $driverName = $p.DriverName

    Get-PrintJob -PrinterName $Name -ErrorAction SilentlyContinue | Remove-PrintJob -ErrorAction SilentlyContinue
    Remove-Printer -Name $Name
    Write-Ok "Printer '$Name' dihapus."

    # Hapus port TCP/IP hanya jika tidak dipakai printer lain
    if (-not $KeepPort) {
        $port = Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue
        $usedByOthers = Get-Printer | Where-Object { $_.PortName -eq $portName }
        if ($port -and $port.PrinterHostAddress -and -not $usedByOthers) {
            try {
                Remove-PrinterPort -Name $portName
                Write-Ok "Port '$portName' dihapus."
            } catch { Write-Warn "Port '$portName' belum bisa dihapus (coba lagi setelah restart): $($_.Exception.Message)" }
        }
    }

    # Hapus driver hanya jika tidak dipakai printer lain
    if ($RemoveDriver) {
        if (Get-Printer | Where-Object { $_.DriverName -eq $driverName }) {
            Write-Warn "Driver '$driverName' masih dipakai printer lain, tidak dihapus."
        } else {
            try {
                Remove-PrinterDriver -Name $driverName -RemoveFromDriverStore
                Write-Ok "Driver '$driverName' dihapus (termasuk dari Driver Store)."
            } catch {
                try {
                    Remove-PrinterDriver -Name $driverName
                    Write-Ok "Driver '$driverName' dihapus."
                } catch { Write-Warn "Driver belum bisa dihapus (coba restart Print Spooler): $($_.Exception.Message)" }
            }
        }
    }
}

function Uninstall-Printers {
    Write-Host ''
    Write-Host '=== HAPUS PRINTER ===' -ForegroundColor Cyan
    $list = @(Show-Printers)
    if ($list.Count -eq 0) { return }

    $sel = Read-Host 'Nomor printer yang dihapus (pisahkan koma, mis. 1,3; kosong = batal)'
    if ([string]::IsNullOrWhiteSpace($sel)) { return }

    $targets = @()
    foreach ($s in ($sel -split ',')) {
        $s = $s.Trim()
        if ($s -match '^\d+$' -and [int]$s -ge 1 -and [int]$s -le $list.Count) {
            $targets += $list[[int]$s - 1].Name
        } else { Write-Warn "Nomor '$s' diabaikan." }
    }
    if ($targets.Count -eq 0) { return }

    Write-Host 'Akan dihapus:'
    $targets | ForEach-Object { Write-Host "  - $_" }
    if (-not (Confirm-YesNo 'Yakin?')) { return }
    $removeDriver = Confirm-YesNo 'Hapus juga drivernya (jika tidak dipakai printer lain)?'

    foreach ($t in $targets) {
        try { Remove-PrinterSafe $t -RemoveDriver:$removeDriver }
        catch { Write-Err "Gagal menghapus '$t': $($_.Exception.Message)" }
    }
}

# ---------------- Menu ----------------
$running = $true
while ($running) {
    Write-Host ''
    Write-Host '===================================================' -ForegroundColor Cyan
    Write-Host '   PRINTER MANAGER - CANON via WAVLINK' -ForegroundColor Cyan
    Write-Host '===================================================' -ForegroundColor Cyan
    Write-Host '  1. Install printer'
    Write-Host '  2. Hapus printer yang sudah terpasang'
    Write-Host '  3. Lihat daftar printer'
    Write-Host '  0. Keluar'
    switch (Read-Host 'Pilih') {
        '1' { Install-CanonPrinter }
        '2' { Uninstall-Printers }
        '3' { Write-Host ''; Show-Printers | Out-Null }
        '0' { $running = $false }
        default { Write-Warn 'Pilihan tidak dikenal.' }
    }
}
