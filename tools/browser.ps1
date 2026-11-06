#Requires -Version 5.1
<#
.SYNOPSIS
  browser.ps1 - 專用「登入瀏覽器」+ 透過 CDP 匯出 cookies.txt

.DESCRIPTION
  為什麼需要這個：
    * yt-dlp --cookies-from-browser chrome 在使用者的 Chrome 開著時會失敗
      （Chrome 鎖住 cookie 資料庫："Could not copy Chrome cookie database"）。
    * Chrome 136+ 不允許對「預設設定檔」開 --remote-debugging-port。
    * Windows 版 Chrome 預設設定檔的 cookie 用 App-Bound (v20) 加密，外部程式解不開。
  做法：用已安裝的 Chrome（沒有就用 Edge）開一個「專用設定檔」
  %LOCALAPPDATA%\影音下載器\browser（--user-data-dir，可用 -ProfilePath 改），使用者在這個視窗登入 IG/FB/X；
  要下載時由瀏覽器自己透過 Chrome DevTools Protocol (Storage.getCookies)
  把 cookie 交出來（瀏覽器自己解密），寫成 yt-dlp / gallery-dl 都吃的
  Netscape cookies.txt。瀏覽器可以一直開著找網址，不用關。

  絕不碰使用者自己的 Chrome 設定檔，也絕不關閉／干擾使用者自己的 Chrome 行程：
  只會停止「本腳本啟動的 PID」或「命令列含本工具設定檔路徑（--user-data-dir）」的行程。

  安全性說明：
    debug port 讓「本機上的任何行程」都能操控這個登入瀏覽器的 session
    （讀 cookie、開分頁、執行 JS）。它只綁在 127.0.0.1（Chrome 預設，不對外），
    而且只在登入瀏覽器開著的期間存在；關掉視窗 port 就消失。無頭（headless）
    匯出用的是臨時挑的空閒 port，用完立即關閉。
    設定檔資料夾（預設 %LOCALAPPDATA%\影音下載器\browser）內含登入 session，不要分享或上傳。
    預設位置在專案資料夾之外，所以不會進版控、也不會被雲端同步；若用 -ProfilePath 指到
    專案內的 profile\，該資料夾也已列入 .gitignore。

.PARAMETER Action
  open    [-Url <http(s) url>] [-Port 9227]
          沒開 → 啟動可見的登入瀏覽器（固定 port，預設 9227）。
          已開 → 只用 CDP 開新分頁（PUT /json/new）並切到前面，不會開第二個瀏覽器。
          JSON：ok, action, mode("launched"|"new_tab"|"already_running"), port,
                url, pid/browser/version/exe/profile（launched 時）, target_id（new_tab 時）
  export  -OutFile <path> [-Domains "instagram.com,x.com"]
          登入瀏覽器開著 → 直接從它拿（mode "live"）；沒開 → 用同一個設定檔開無頭
          瀏覽器拿完就關（mode "headless"，約 2~5 秒）。
          JSON：ok, action, mode, count(寫入), total(瀏覽器回傳), skipped, file,
                domains, browser, logged_in{instagram,facebook,x}
  tabs    JSON：ok, action, running, port, count, tabs[{id,url,title}]（沒開時 running:false, tabs:[]）
  status  [-Probe]  JSON：ok, action, browser, exe, version, profile, profile_exists,
                sync_folder, running, port, default_port, profile_locked,
                logged_in(null=未知), hints_source("live"|"headless"|null), cookie_count
          沒開時預設不讀 cookie（快）；加 -Probe 才用無頭模式算登入狀態。
  close   JSON：ok, action, was_running, how("graceful"|"killed"|null)
  共通：-Browser auto|chrome|edge、-ProfilePath <dir>（或環境變數 MDL_BROWSER_PROFILE）、-TimeoutSec
  每個 JSON 都另有 warnings[]、elapsed_ms；失敗時 ok:false + error + hint（中文）+ code
  （bad_args / bad_url / no_browser / no_profile / profile_locked / port_in_use /
    launch_failed / launch_timeout / busy / error）。

.OUTPUTS
  stdout 永遠只有「一行 JSON 物件」（非 ASCII 字元一律以 \uXXXX 跳脫，
  所以不受任何主控台編碼影響）。成功 exit 0、失敗 exit 1。
  給人看的診斷訊息只寫到 stderr。任何地方都不會印出 cookie 的值。
  （唯一例外：參數名稱打錯時 PowerShell 在進入腳本前就報錯，stdout 會是空的。）

.NOTES
  實測 Chrome 154 的行為（2026-09）：
    * 固定 port 時不會寫 <profile>\DevToolsActivePort（只有 port=0 才寫）→ 身分判斷改用
      browser_state.json 記的 browser GUID，或 netstat 查監聽者 PID 的命令列。
    * 新版 headless 的 /json/version 也回報 "Chrome/154..."（不是 HeadlessChrome）。
    * 專用設定檔的 cookie 是 v10（DPAPI）加密；不論哪種都由瀏覽器自己解密，本腳本不碰。
    * YouTube 的 YSC / VISITOR_INFO1_LIVE 等是「第一方分割（CHIPS）」cookie → 照樣匯出。
    * Browser.close 後瀏覽器要 1~6 秒才真正結束（graceful）；逾時才強制結束我們自己的 PID 樹。
    * Windows 連一個沒人聽的 localhost port 會重試約 2 秒 → 一律先用 netstat 查有沒有人在聽。
  呼叫端注意：
    * 不要用 PS 5.1 的 Start-Process -Wait 呼叫 -Action open：它會等「所有子孫行程」，
      也就是等到使用者關掉登入瀏覽器。用 Process.WaitForExit / subprocess.run 即可
      （瀏覽器以 ShellExecute 啟動、不繼承 stdout pipe，呼叫端約 1 秒就拿到結果）。
    * yt-dlp 跑完會把 cookie jar 寫回 --cookies 指定的檔案 → 每次匯出到暫存檔、用完刪掉。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\browser.ps1 -Action open -Url https://www.instagram.com/
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\browser.ps1 -Action export -OutFile C:\tmp\cookies.txt -Domains instagram.com
#>
[CmdletBinding()]
param(
    [string]$Action = 'status',
    [string]$Url,
    [string]$OutFile,
    [string]$Domains,
    [int]$Port = 9227,
    [string]$Browser = 'auto',     # auto | chrome | edge
    [switch]$Probe,                # status：瀏覽器沒開時，用無頭模式實際讀 cookie 算登入狀態（約 1~3 秒）
    [string]$ProfilePath,          # 覆寫設定檔位置（也可用環境變數 MDL_BROWSER_PROFILE）；預設 %LOCALAPPDATA%\影音下載器\browser
    [int]$TimeoutSec = 25
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Sw = [Diagnostics.Stopwatch]::StartNew()
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$script:OrigOutEnc = $null
try {
    $script:OrigOutEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = $script:Utf8NoBom
} catch { }

# ============================================================ 路徑
$Root        = Split-Path -Parent $PSScriptRoot
if (-not $ProfilePath -and $env:MDL_BROWSER_PROFILE) { $ProfilePath = $env:MDL_BROWSER_PROFILE }
if ($ProfilePath) { $ProfileDir = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ProfilePath)).TrimEnd('\') }
else {
    # 預設放本機 %LOCALAPPDATA%，不放專案資料夾：專案在 Synology Drive 同步資料夾（E: 是 SMR 硬碟）時，
    # 實測偶發讀到 0 顆 cookie、headless 關閉卡 90 秒以上，而且登入 session 會被同步到 NAS。
    $ProfileDir = Join-Path (Join-Path $env:LOCALAPPDATA '影音下載器') 'browser'
}
$ProfileRoot = Split-Path -Parent $ProfileDir
$StateFile   = Join-Path $ProfileRoot ((Split-Path -Leaf $ProfileDir) + '_state.json')   # 預設 %LOCALAPPDATA%\影音下載器\browser_state.json（與設定檔資料夾同層）
$LockFile    = Join-Path $ProfileDir 'lockfile'

# 設定檔放在雲端同步資料夾裡（例如 Synology Drive 或 OneDrive 的同步資料夾）會有兩個問題：
#   1. 登入 session 被同步到 NAS / 其他電腦；2. 同步程式在上傳時開著 SQLite 檔，
#   Chrome 可能打不開 cookie 資料庫而改用「空的記憶體 cookie」（匯出 0 顆）。
# 這裡只偵測並警告；要搬走就用 -ProfilePath 或環境變數 MDL_BROWSER_PROFILE。
function Get-SyncFolderKind([string]$path) {
    $p = $path
    while ($p) {
        if (Test-Path -LiteralPath (Join-Path $p '.SynologyWorkingDirectory')) { return 'synology_drive' }
        if (Test-Path -LiteralPath (Join-Path $p '.dropbox')) { return 'dropbox' }
        $parent = Split-Path -Parent $p
        if ($parent -eq $p) { break }
        $p = $parent
    }
    foreach ($od in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        if ($od -and $path.StartsWith($od.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return 'onedrive' }
    }
    return $null
}
$script:SyncKind = Get-SyncFolderKind $ProfileDir
$script:Warnings = New-Object System.Collections.Generic.List[string]
if ($script:SyncKind) {
    $script:Warnings.Add("profile is inside a $($script:SyncKind) sync folder: login sessions get synced and the sync client may lock the cookie database (use -ProfilePath / MDL_BROWSER_PROFILE to move it)")
}

# ============================================================ 輸出
function Log([string]$m) {
    try { [Console]::Error.WriteLine("[browser +$($script:Sw.ElapsedMilliseconds)ms] $m") } catch { }
}

# ConvertTo-Json 後把所有非 ASCII 字元轉成 \uXXXX：stdout 因此是純 ASCII，
# 呼叫端（Python / PowerShell / cmd）用什麼編碼讀都不會壞。
function ConvertTo-AsciiJson($obj) {
    $json = ConvertTo-Json -InputObject $obj -Compress -Depth 8
    $sb = New-Object System.Text.StringBuilder ($json.Length + 16)
    foreach ($ch in $json.ToCharArray()) {
        $n = [int]$ch
        if ($n -gt 126) { [void]$sb.Append('\u').Append($n.ToString('x4')) } else { [void]$sb.Append($ch) }
    }
    $sb.ToString()
}

function Emit($obj, [int]$code) {
    if ($script:Warnings -and $script:Warnings.Count -gt 0) { $obj['warnings'] = $script:Warnings.ToArray() } else { $obj['warnings'] = @() }
    $obj['elapsed_ms'] = [int]$script:Sw.ElapsedMilliseconds
    $line = ConvertTo-AsciiJson $obj
    try { [Console]::Out.Write($line + "`n"); [Console]::Out.Flush() } catch { }
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { } }
    if ($script:OrigOutEnc) { try { [Console]::OutputEncoding = $script:OrigOutEnc } catch { } }
    exit $code
}

# 丟出帶「中文提示」與「機器可讀代碼」的例外，由最外層 catch 轉成 JSON。
function Stop-With([string]$err, [string]$hint, [string]$code = 'error') {
    $e = New-Object System.Exception $err
    $e.Data['hint'] = $hint
    $e.Data['code'] = $code
    throw $e
}

# ============================================================ JSON / HTTP
Add-Type -AssemblyName System.Web.Extensions
$script:Jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:Jss.MaxJsonLength = [int]::MaxValue
function ConvertFrom-JsonFast([string]$s) { $script:Jss.DeserializeObject($s) }

# 不用 Invoke-WebRequest：它在 PS 5.1 第一次呼叫很慢，而且會吃系統 proxy。
function Invoke-Http([string]$method, [string]$uri, [int]$timeoutMs = 2000) {
    $req = [System.Net.HttpWebRequest]::Create($uri)
    $req.Method = $method
    $req.Proxy = $null
    $req.Timeout = $timeoutMs
    $req.ReadWriteTimeout = $timeoutMs
    $req.KeepAlive = $false
    if ($method -eq 'PUT') { $req.ContentLength = 0 }
    $resp = $req.GetResponse()
    try {
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $sr.ReadToEnd()
    } finally { $resp.Close() }
}

function Get-VersionInfo([int]$p) {
    try { return ConvertFrom-JsonFast (Invoke-Http 'GET' "http://127.0.0.1:$p/json/version" 1500) } catch { return $null }
}

# ============================================================ CDP over WebSocket
# 連到 browser 層級的 websocket 送一個指令、等對應 id 的回應。
# 回應可能很大（幾百顆 cookie）→ 一定要把多個 frame 接起來直到 EndOfMessage。
function Invoke-Cdp([string]$wsUrl, [string]$method, [string]$paramsJson = '{}', [int]$timeoutSec = 15) {
    $ws  = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource ([TimeSpan]::FromSeconds($timeoutSec))
    try {
        try { $ws.Options.Proxy = $null } catch { }
        # 注意：PS 5.1 的 .GetResult() 會吐出 VoidTaskResult 物件污染回傳值 → 一定要 [void]
        [void]$ws.ConnectAsync([Uri]$wsUrl, $cts.Token).GetAwaiter().GetResult()
        $msg   = '{"id":1,"method":"' + $method + '","params":' + $paramsJson + '}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
        $seg   = New-Object 'System.ArraySegment[byte]' (, $bytes)
        [void]$ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
        $buf = New-Object byte[] 65536
        while ($true) {
            $ms = New-Object System.IO.MemoryStream
            do {
                $rseg = New-Object 'System.ArraySegment[byte]' (, $buf)
                $r = $ws.ReceiveAsync($rseg, $cts.Token).GetAwaiter().GetResult()
                if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    throw "CDP connection closed before reply to $method"
                }
                $ms.Write($buf, 0, $r.Count)
            } while (-not $r.EndOfMessage)
            $obj = ConvertFrom-JsonFast ([System.Text.Encoding]::UTF8.GetString($ms.ToArray()))
            if ($obj -is [System.Collections.IDictionary] -and $obj.ContainsKey('id') -and [int]$obj['id'] -eq 1) {
                if ($obj.ContainsKey('error')) { throw ("CDP $method error: " + $obj['error']['message']) }
                return , $obj['result']
            }
            # 其他訊息是事件，略過
        }
    } finally {
        try {
            if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                [void]$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', [Threading.CancellationToken]::None).Wait(1500)
            }
        } catch { }
        $ws.Dispose(); $cts.Dispose()
    }
}

# ============================================================ 瀏覽器 / 設定檔偵測
function Read-State {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try { return ConvertFrom-JsonFast ([IO.File]::ReadAllText($StateFile)) } catch { return $null }
}
function Write-State($h) {
    try {
        if (-not (Test-Path -LiteralPath $ProfileRoot)) { [void](New-Item -ItemType Directory -Force -Path $ProfileRoot) }
        [IO.File]::WriteAllText($StateFile, (ConvertTo-AsciiJson $h), $script:Utf8NoBom)
    } catch { Log "cannot write state file: $($_.Exception.Message)" }
}

function Find-BrowserExe([string]$pref) {
    $pf64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $pf86 = ${env:ProgramFiles(x86)}
    $chrome = New-Object System.Collections.Generic.List[string]
    foreach ($p in @("$pf64\Google\Chrome\Application\chrome.exe", "$pf86\Google\Chrome\Application\chrome.exe",
                     "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) { $chrome.Add($p) }
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe')) {
        try { $v = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).'(default)'; if ($v) { $chrome.Add($v.Trim('"')) } } catch { }
    }
    $edge = @("$pf86\Microsoft\Edge\Application\msedge.exe", "$pf64\Microsoft\Edge\Application\msedge.exe")

    $order = switch ($pref) { 'chrome' { @('chrome') } 'edge' { @('edge') } default { @('chrome', 'edge') } }
    # auto：同一個設定檔不要在 Chrome / Edge 之間換來換去（設定檔格式不相容）
    if ($pref -eq 'auto') {
        $st = Read-State
        if ($st -and $st['browser'] -eq 'edge') { $order = @('edge', 'chrome') }
    }
    foreach ($name in $order) {
        $list = if ($name -eq 'chrome') { $chrome } else { $edge }
        foreach ($p in $list) {
            if ($p -and (Test-Path -LiteralPath $p)) {
                $ver = $null
                try { $ver = (Get-Item -LiteralPath $p).VersionInfo.ProductVersion } catch { }
                return @{ name = $name; exe = $p; version = $ver }
            }
        }
    }
    return $null
}

function Test-HasProfileArg([string]$cmdLine) {
    if (-not $cmdLine) { return $false }
    $needle = $ProfileDir.TrimEnd('\').ToLowerInvariant()
    $lc = $cmdLine.ToLowerInvariant()
    return ($lc.Contains("--user-data-dir=$needle") -or $lc.Contains("--user-data-dir=`"$needle"))
}

# 誰在 127.0.0.1 / 0.0.0.0 的哪個 port 監聽？netstat 約 40ms（Get-NetTCPConnection 要 800ms 以上）。
# 不比對 LISTENING 字樣（某些語系會翻譯），改看遠端位址 0.0.0.0:0。
# 為什麼要先查而不是直接連：Windows 上連一個「沒人聽的 localhost port」不會馬上被拒，
# TCP 會重試約 2 秒，每個動作都會白白慢 2 秒。
function Get-PortOwnerPid([int]$p) {
    try {
        foreach ($line in (& netstat.exe -ano -p TCP)) {
            if ($line -match "^\s*TCP\s+(127\.0\.0\.1|0\.0\.0\.0):$p\s+0\.0\.0\.0:0\s+\S+\s+(\d+)\s*$") { return [int]$Matches[2] }
        }
    } catch { }
    return $null
}

# 回傳該 PID 的命令列（僅當它是我們設定檔的行程），否則 $null
function Get-OurPidCmdLine([int]$procId) {
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -OperationTimeoutSec 5 -ErrorAction Stop
        if ($p -and (Test-HasProfileArg ([string]$p.CommandLine))) { return [string]$p.CommandLine }
    } catch { }
    return $null
}

# 「是不是我們的瀏覽器」的判準（Chrome 154 用固定 port 時不會寫 DevToolsActivePort，不能靠它）：
#   1. 快速路徑：port 回應的 webSocketDebuggerUrl（每次啟動才有的 browser GUID）
#      與我們啟動時記在 $StateFile（預設 %LOCALAPPDATA%\影音下載器\browser_state.json）的一致。
#   2. 後備：監聽該 port 的行程，其命令列含本工具設定檔的 --user-data-dir。
# 兩者都不成立 → 那個 port 上的東西不是我們的，一律不碰。
function Get-OurEndpoint {
    $st = Read-State
    $ports = New-Object System.Collections.Generic.List[int]
    if ($st -and $st['port']) { $ports.Add([int]$st['port']) }
    if (-not $ports.Contains($Port)) { $ports.Add($Port) }
    foreach ($p in $ports) {
        $owner = Get-PortOwnerPid $p
        if (-not $owner) { continue }
        $v = Get-VersionInfo $p
        if (-not $v) { continue }
        $ws = [string]$v['webSocketDebuggerUrl']
        if (-not $ws) { continue }
        $b = [string]$v['Browser']
        # 注意：Chrome 154 的新版 headless 在 /json/version 也回報 "Chrome/..."（不是 HeadlessChrome），
        # 所以是否 headless 只能看命令列。
        $ours = [bool]($st -and [string]$st['ws'] -eq $ws)
        $headless = $false
        if ($ours) { $headless = [bool]$st['headless'] }
        else {
            $cl = Get-OurPidCmdLine $owner
            if ($cl) {
                $ours = $true
                $headless = $cl -match '--headless'
                Write-State ([ordered]@{ pid = $owner; port = $p; ws = $ws; browser = $(if ($cl -match 'msedge\.exe') { 'edge' } else { 'chrome' });
                                         headless = $headless; started = $null })
            }
        }
        if ($ours) { return @{ port = $p; ws = $ws; browser = $b; headless = $headless; pid = $owner } }
    }
    return $null
}

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    try { return $l.LocalEndpoint.Port } finally { $l.Stop() }
}

# Chrome 在 Windows 上會以獨佔方式開著 <user-data-dir>\lockfile；打不開 = 有行程在用這個設定檔。
function Test-ProfileLocked {
    if (-not (Test-Path -LiteralPath $LockFile)) { return $false }
    try {
        $fs = [IO.File]::Open($LockFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $fs.Close()
        return $false
    } catch { return $true }
}

# 命令列含本工具設定檔路徑（$ProfileDir）的 chrome/msedge 行程（呼叫端再用 --type= 篩主行程）。
# 使用者自己的 Chrome 命令列不可能含這個路徑，所以不會誤殺。
# 注意：有 Chrome 行程卡在關閉中時，WMI 列舉可能一次卡 40 秒以上 → 一定要設逾時，
# 而且「我們手上已有 handle 的 PID」根本不走這裡（見 Stop-PidTree）。
function Get-OurBrowserProcesses {
    # 逐一輸出（呼叫端一律用 @() 包起來）；不要回傳 ,$array，否則接 | Where-Object 時整個陣列會被當成一筆
    $all = @()
    try { $all = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -OperationTimeoutSec 8 -ErrorAction Stop) }
    catch { Log "process query failed/timed out: $($_.Exception.Message)" }
    foreach ($p in $all) { if (Test-HasProfileArg ([string]$p.CommandLine)) { $p } }
}

# 強制結束一個 PID 及其子行程樹（taskkill /T 只往下殺，不會碰到使用者自己的 Chrome）。
# 呼叫端必須已確認這個 PID 是我們的：
#   * 我們自己啟動的（手上握有 Process handle，PID 不可能被重用），或
#   * 監聽「GUID 驗證過的我們的 debug port」的行程，或
#   * Get-OurBrowserProcesses 查到命令列含我們 profile 的行程。
function Stop-PidTree([int]$id) {
    if (-not $id) { return }
    Log "force-stopping our browser PID $id"
    # 原生程式寫 stderr 在 EAP=Stop 下會變成終止錯誤 → 這裡暫時放寬
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { foreach ($l in (& taskkill.exe /PID $id /T /F 2>&1)) { Log "taskkill: $l" } } catch { }
    finally { $ErrorActionPreference = $eap }
    try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { }
}

# 用命令列確認後才殺（沒有 handle 可依據時用這個）
function Stop-OurProcessTree([int[]]$pids) {
    $ours = @(Get-OurBrowserProcesses)
    foreach ($id in $pids) {
        if (-not $id) { continue }
        if (-not ($ours | Where-Object { $_.ProcessId -eq $id })) { Log "skip PID $id (not verified as our profile)"; continue }
        Stop-PidTree $id
    }
}

function Wait-Released([int]$timeoutSec, $proc) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $procDone = (-not $proc) -or $proc.HasExited
        if ($procDone -and -not (Test-ProfileLocked)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# $proc：我們握有 handle 的瀏覽器主行程（自己啟動的，或 $ep.pid 取得的）。
function Close-Endpoint($ep, $proc, [int]$graceSec = 8) {
    if (-not $proc -and $ep.pid) { try { $proc = Get-Process -Id ([int]$ep.pid) -ErrorAction Stop } catch { } }
    # Chrome 收到 Browser.close 常常直接斷線、不回覆 → 只等 1 秒，之後改看設定檔鎖是否釋放
    try { [void](Invoke-Cdp $ep.ws 'Browser.close' '{}' 1) } catch { Log "Browser.close: $($_.Exception.Message)" }
    Log 'Browser.close sent, waiting for exit'
    if (Wait-Released $graceSec $proc) { return 'graceful' }
    # 逾時：先殺手上有 handle 的主行程樹（不必查 WMI），通常這樣就釋放了
    if ($proc -and -not $proc.HasExited) { Stop-PidTree $proc.Id }
    if (Wait-Released 3 $null) { return 'killed' }
    # 還是鎖著：才用 WMI 找命令列含我們 profile 的其他主行程
    $pids = @(Get-OurBrowserProcesses | Where-Object { $_.CommandLine -notmatch '--type=' } | ForEach-Object { [int]$_.ProcessId })
    if ($pids.Count -gt 0) { Stop-OurProcessTree $pids; [void](Wait-Released 5 $null) }
    return 'killed'
}
function Quote-Arg([string]$s) { '"' + $s.Replace('"', '%22') + '"' }

function Normalize-Url([string]$u) {
    if (-not $u) { return $null }
    $u = $u.Trim()
    if ($u -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $u = 'https://' + $u }
    if ($u -notmatch '^https?://') {
        Stop-With "unsupported URL scheme: $u" '只接受 http:// 或 https:// 網址' 'bad_url'
    }
    return $u
}

# 啟動我們的瀏覽器。用 Start-Process（ShellExecute）而不是 Process.Start：
# ShellExecute 不繼承 handle，否則 Chrome 會繼承呼叫端（mdl.py / GUI）的 stdout pipe，
# 呼叫端就會一直等到 Chrome 關掉才讀到 EOF。
function Start-OurBrowser($exeInfo, [int]$p, [bool]$headless, [string]$url) {
    if (-not (Test-Path -LiteralPath $ProfileDir)) { [void](New-Item -ItemType Directory -Force -Path $ProfileDir) }
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add((Quote-Arg "--user-data-dir=$ProfileDir"))
    $a.Add("--remote-debugging-port=$p")
    $a.Add('--no-first-run')
    $a.Add('--no-default-browser-check')
    if ($headless) {
        $a.Add('--headless=new')
        $a.Add('--mute-audio')
        $a.Add('--disable-extensions')
        # 縮短無頭 session 的背景連線（元件更新、同步、網域可靠性回報…）
        $a.Add('--disable-background-networking'); $a.Add('--disable-component-update'); $a.Add('--disable-sync')
        $a.Add('about:blank')
    } else {
        $a.Add('--remote-allow-origins=*')
        if ($url) { $a.Add((Quote-Arg $url)) }
    }
    Log ("launch " + $exeInfo.name + ($(if ($headless) { ' (headless)' } else { '' })) + " port=$p")
    return Start-Process -FilePath $exeInfo.exe -ArgumentList ($a -join ' ') -PassThru
}

# 等剛啟動的瀏覽器在 $p 開好 debug port，並確認監聽者就是我們啟動的 PID。
function Wait-Endpoint($proc, [int]$p, [int]$timeoutSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $owner = Get-PortOwnerPid $p
        $v = if ($owner) { Get-VersionInfo $p } else { $null }
        if ($v -and $v['webSocketDebuggerUrl']) {
            if ($owner -ne $proc.Id) {
                Stop-With "port $p answered but is owned by PID $owner, not our browser (PID $($proc.Id))" `
                    "連接埠 $p 被別的程式搶先佔用，請改用 -Port 指定其他號碼" 'port_in_use'
            }
            $b = [string]$v['Browser']
            return @{ port = $p; ws = [string]$v['webSocketDebuggerUrl']; browser = $b; headless = $false; pid = $proc.Id }
        }
        if ($proc.HasExited) {
            # 行程立刻結束 = 通常是設定檔已被另一個（沒開 debug port 的）同設定檔視窗佔用、指令被轉交過去
            Stop-With "browser process exited immediately (exit code $($proc.ExitCode))" `
                "瀏覽器啟動後立刻結束：可能登入瀏覽器的設定檔（$($ProfileDir)）已被另一個沒有 debug port 的視窗佔用，請把登入瀏覽器的視窗全部關掉再試" 'launch_failed'
        }
        Start-Sleep -Milliseconds 100
    }
    Stop-With "debug port did not come up within $timeoutSec s" '瀏覽器已啟動但 debug port 沒有回應，請關掉登入瀏覽器後再試一次' 'launch_timeout'
}

function Assert-ProfileFree {
    if (-not (Test-ProfileLocked)) { return }
    # 上次無頭匯出異常中斷留下的孤兒（看不見、沒人在用）→ 直接收掉
    $mains = @(Get-OurBrowserProcesses | Where-Object { $_.CommandLine -notmatch '--type=' })
    if ($mains.Count -gt 0 -and -not ($mains | Where-Object { $_.CommandLine -notmatch '--headless' })) {
        Log 'cleaning up orphan headless instance'
        Stop-OurProcessTree @($mains | ForEach-Object { [int]$_.ProcessId })
        [void](Wait-Released 5 $null)
    }
    if (Test-ProfileLocked) {
        Stop-With 'login browser profile is in use by a browser window without our debug port' `
            ("登入瀏覽器的設定檔（$($ProfileDir)）正被一個「不是由本工具以 debug port 開啟」的瀏覽器視窗使用，無法匯出 cookie。" +
             '請關閉那個登入瀏覽器視窗（或執行 -Action close），再用「登入瀏覽器.bat」重新開啟') 'profile_locked'
    }
}

# ============================================================ cookies
function Get-Now { [double]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }

function Test-DomainIn([string]$cookieDomain, [string[]]$want) {
    $d = $cookieDomain.TrimStart('.').ToLowerInvariant()
    foreach ($w in $want) {
        # 子網域（www.instagram.com ⊂ instagram.com）或父網域 cookie（.instagram.com 用於 www.instagram.com）
        if ($d -eq $w -or $d.EndsWith('.' + $w) -or $w.EndsWith('.' + $d)) { return $true }
    }
    return $false
}

function Get-LoginHints($cookies) {
    $now = Get-Now
    $h = [ordered]@{ instagram = $false; facebook = $false; x = $false }
    foreach ($c in $cookies) {
        $exp = [double]$c['expires']
        if (-not $c['session'] -and $exp -gt 0 -and $exp -lt $now) { continue }
        $n = [string]$c['name']; $d = [string]$c['domain']
        if ([string]::IsNullOrEmpty($c['value'])) { continue }
        if ($n -eq 'sessionid' -and (Test-DomainIn $d @('instagram.com'))) { $h.instagram = $true }
        if ($n -eq 'c_user' -and (Test-DomainIn $d @('facebook.com'))) { $h.facebook = $true }
        if ($n -eq 'auth_token' -and ((Test-DomainIn $d @('x.com')) -or (Test-DomainIn $d @('twitter.com')))) { $h.x = $true }
    }
    return $h
}

function Get-CookiesFromEndpoint($ep) {
    Log 'Storage.getCookies ...'
    $res = Invoke-Cdp $ep.ws 'Storage.getCookies' '{}' 20
    Log ("Storage.getCookies -> " + @($res['cookies']).Count)
    $list = $res['cookies']
    # 逐一輸出、呼叫端用 @() 收；不要回傳 ,@()，否則 0 顆 cookie 會變成「1 個空陣列」
    if ($null -eq $list) { return }
    foreach ($c in $list) { $c }
}

# Netscape cookies.txt：yt-dlp 與 gallery-dl 都檢查第一行 "# Netscape HTTP Cookie File"，
# 所以檔案必須是「不含 BOM」的 UTF-8。
function Write-CookiesTxt($cookies, [string]$path, [string[]]$want) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Netscape HTTP Cookie File`n")
    [void]$sb.Append("# Exported by tools\browser.ps1 (login browser). Contains login sessions - do not share.`n`n")
    $written = 0; $skipped = 0
    # 同 (domain, path, name) 已有一般 cookie 時，分割版不要再寫一次（避免覆蓋）
    $plain = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($c in $cookies) { if (-not $c['partitionKey']) { [void]$plain.Add(([string]$c['domain'] + '|' + [string]$c['path'] + '|' + [string]$c['name'])) } }
    foreach ($c in $cookies) {
        $dom = [string]$c['domain']; $name = [string]$c['name']; $val = [string]$c['value']
        if (-not $dom) { $skipped++; continue }
        if ($want -and -not (Test-DomainIn $dom $want)) { continue }
        # CHIPS 分割 cookie（Chrome 154 的 YouTube YSC / VISITOR_INFO1_LIVE 就是）：
        # Netscape 格式無法表達分割鍵。「第一方」的（頂層網站 = cookie 自己的網站、沒有跨站祖先）
        # 在直接開該網站時本來就會送出 → 保留；第三方嵌入情境的分割 cookie → 略過。
        $pk = $c['partitionKey']
        if ($pk) {
            $top = ''; $cross = $true
            if ($pk -is [System.Collections.IDictionary]) { $top = [string]$pk['topLevelSite']; $cross = [bool]$pk['hasCrossSiteAncestor'] }
            else { $top = [string]$pk; $cross = $false }   # 舊版 CDP：partitionKey 是字串
            $topHost = ($top -replace '^[a-z]+://', '').TrimEnd('/').ToLowerInvariant()
            $firstParty = (-not $cross) -and $topHost -and (Test-DomainIn $dom @($topHost))
            if (-not $firstParty -or $plain.Contains($dom + '|' + [string]$c['path'] + '|' + $name)) { $skipped++; continue }
        }
        if (($name + $val + $dom) -match "[`t`r`n]") { $skipped++; continue }
        $path_ = [string]$c['path']; if (-not $path_) { $path_ = '/' }
        $exp = [double]$c['expires']
        $expiry = if ($c['session'] -or $exp -le 0) { '0' } else { ([long][math]::Floor($exp)).ToString() }
        $flag = if ($dom.StartsWith('.')) { 'TRUE' } else { 'FALSE' }
        $sec  = if ($c['secure']) { 'TRUE' } else { 'FALSE' }
        $domField = if ($c['httpOnly']) { '#HttpOnly_' + $dom } else { $dom }
        [void]$sb.Append($domField).Append("`t").Append($flag).Append("`t").Append($path_).Append("`t").Append($sec).Append("`t").Append($expiry).Append("`t").Append($name).Append("`t").Append($val).Append("`n")
        $written++
    }
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    # 先寫暫存檔再換名，避免呼叫端讀到寫一半的檔案
    $tmp = "$path.tmp$PID"
    [IO.File]::WriteAllText($tmp, $sb.ToString(), $script:Utf8NoBom)
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    Move-Item -LiteralPath $tmp -Destination $path
    return @{ written = $written; skipped = $skipped }
}

function Split-Domains([string]$s) {
    if (-not $s) { return $null }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($x in ($s -split '[,;\s]+')) {
        $x = $x.Trim().ToLowerInvariant()
        if (-not $x) { continue }
        $x = $x -replace '^[a-z][a-z0-9+.-]*://', ''
        $x = ($x -split '[/:?#]')[0].TrimStart('.')
        if ($x) { $out.Add($x) }
    }
    if ($out.Count -eq 0) { return $null }
    return , $out.ToArray()
}

# 無頭模式：用同一個設定檔在隨機 port 開一個看不見的瀏覽器，做完事立刻關掉。
function Invoke-Headless($exeInfo, [scriptblock]$work) {
    Assert-ProfileFree
    $hp = Get-FreePort
    $proc = Start-OurBrowser $exeInfo $hp $true $null
    $ep = $null
    try {
        $ep = Wait-Endpoint $proc $hp $TimeoutSec
        Log "headless endpoint ready (PID $($proc.Id))"
        return (& $work $ep)
    } finally {
        # 清理絕不能丟例外，否則會蓋掉真正的錯誤
        try {
            if ($ep) { $how = Close-Endpoint $ep $proc 8 }
            else { if ($proc -and -not $proc.HasExited) { Stop-PidTree $proc.Id }; $how = 'killed' }
            Log "headless browser closed ($how)"
        } catch { Log "headless cleanup error: $($_.Exception.Message)" }
    }
}

# 無頭模式讀 cookie：剛啟動時若拿到 0 顆，最多再等 3 秒（cookie 資料庫可能還在載入，
# 或暫時被別的程式鎖住）。還是 0 就照實回報並加警告，不要假裝成功。
function Get-CookiesHeadless($ep) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $c = @(Get-CookiesFromEndpoint $ep)
        if ($c.Count -gt 0 -or $sw.Elapsed.TotalSeconds -ge 3) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($c.Count -eq 0) {
        $script:Warnings.Add('browser returned 0 cookies: profile not logged in yet, or the cookie database could not be opened (locked by sync/antivirus software?)')
    }
    return $c
}

# ============================================================ actions
function Do-Open {
    $u = Normalize-Url $Url
    $ep = Get-OurEndpoint
    if ($ep -and $ep.headless) {
        # 上次無頭匯出沒收乾淨的孤兒 → 關掉它，改開可見視窗
        Log 'closing orphan headless instance'
        [void](Close-Endpoint $ep $null 8)
        $ep = $null
    }
    if ($ep) {
        # 已經開著：只開新分頁，不另起第二個瀏覽器
        if ($u) {
            $t = ConvertFrom-JsonFast (Invoke-Http 'PUT' ("http://127.0.0.1:$($ep.port)/json/new?" + [Uri]::EscapeDataString($u)) 5000)
            try { [void](Invoke-Http 'GET' "http://127.0.0.1:$($ep.port)/json/activate/$($t['id'])" 2000) } catch { }
            return [ordered]@{ ok = $true; action = 'open'; mode = 'new_tab'; port = $ep.port; url = $u; target_id = [string]$t['id'] }
        }
        # 沒給網址：把現有分頁叫到前面
        try {
            $tabs = ConvertFrom-JsonFast (Invoke-Http 'GET' "http://127.0.0.1:$($ep.port)/json/list" 2000)
            $pg = @($tabs | Where-Object { $_['type'] -eq 'page' }) | Select-Object -First 1
            if ($pg) { [void](Invoke-Http 'GET' "http://127.0.0.1:$($ep.port)/json/activate/$($pg['id'])" 2000) }
        } catch { }
        return [ordered]@{ ok = $true; action = 'open'; mode = 'already_running'; port = $ep.port; url = $null }
    }

    $exe = Find-BrowserExe $Browser
    if (-not $exe) { Stop-With 'Chrome / Edge not found' '找不到已安裝的 Google Chrome 或 Microsoft Edge' 'no_browser' }
    Assert-ProfileFree
    if (Get-PortOwnerPid $Port) {
        $v = Get-VersionInfo $Port
        $who = if ($v) { " (answers as " + [string]$v['Browser'] + ")" } else { '' }
        Stop-With "port $Port is already in use by another program$who" `
            "連接埠 $Port 被別的程式佔用（不是本工具的登入瀏覽器）。請改用 -Port 指定其他號碼，例如 -Port 9237" 'port_in_use'
    }
    $proc = Start-OurBrowser $exe $Port $false $u
    $ep = Wait-Endpoint $proc $Port $TimeoutSec
    Write-State ([ordered]@{ pid = $proc.Id; port = $ep.port; ws = $ep.ws; browser = $exe.name; headless = $false; started = (Get-Date).ToString('s') })
    return [ordered]@{ ok = $true; action = 'open'; mode = 'launched'; pid = $proc.Id; port = $ep.port; browser = $exe.name;
                       version = $exe.version; exe = $exe.exe; profile = $ProfileDir; url = $u }
}

function Do-Export {
    if (-not $OutFile) { Stop-With 'missing -OutFile' '請用 -OutFile 指定 cookies.txt 的輸出路徑' 'bad_args' }
    $out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    $want = Split-Domains $Domains
    $ep = Get-OurEndpoint
    $exe = $null
    if ($ep) {
        $mode = if ($ep.headless) { 'headless_orphan' } else { 'live' }
        $cookies = @(Get-CookiesFromEndpoint $ep)
        if ($ep.headless) { [void](Close-Endpoint $ep $null 8) }
    } else {
        if (-not (Test-Path -LiteralPath (Join-Path $ProfileDir 'Local State'))) {
            Stop-With 'login browser profile does not exist yet' '還沒有登入瀏覽器的設定檔：請先執行「登入瀏覽器.bat」並登入需要的網站' 'no_profile'
        }
        $exe = Find-BrowserExe $Browser
        if (-not $exe) { Stop-With 'Chrome / Edge not found' '找不到已安裝的 Google Chrome 或 Microsoft Edge' 'no_browser' }
        $mode = 'headless'
        $cookies = @(Invoke-Headless $exe { param($e) Get-CookiesHeadless $e })
    }
    $r = Write-CookiesTxt $cookies $out $want
    $bname = if ($exe) { $exe.name } elseif ($ep -and $ep.browser -like '*Edg*') { 'edge' } else { 'chrome' }
    return [ordered]@{ ok = $true; action = 'export'; mode = $mode; count = $r.written; total = $cookies.Count; skipped = $r.skipped;
                       file = $out; domains = $want; browser = $bname; logged_in = (Get-LoginHints $cookies) }
}

function Do-Tabs {
    $ep = Get-OurEndpoint
    if (-not $ep -or $ep.headless) { return [ordered]@{ ok = $true; action = 'tabs'; running = $false; tabs = @() } }
    $raw = ConvertFrom-JsonFast (Invoke-Http 'GET' "http://127.0.0.1:$($ep.port)/json/list" 3000)
    $tabs = New-Object System.Collections.Generic.List[object]
    foreach ($t in $raw) {
        if ($t['type'] -ne 'page') { continue }
        $tabs.Add([ordered]@{ id = [string]$t['id']; url = [string]$t['url']; title = [string]$t['title'] })
    }
    return [ordered]@{ ok = $true; action = 'tabs'; running = $true; port = $ep.port; count = $tabs.Count; tabs = $tabs.ToArray() }
}

function Do-Status {
    $exe = Find-BrowserExe $Browser
    $ep = Get-OurEndpoint
    $running = [bool]($ep -and -not $ep.headless)
    $o = [ordered]@{
        ok = $true; action = 'status'
        browser = $(if ($exe) { $exe.name } else { $null }); exe = $(if ($exe) { $exe.exe } else { $null })
        version = $(if ($exe) { $exe.version } else { $null })
        profile = $ProfileDir; profile_exists = (Test-Path -LiteralPath (Join-Path $ProfileDir 'Local State')); sync_folder = $script:SyncKind
        running = $running; port = $(if ($running) { $ep.port } else { $null }); default_port = $Port
        profile_locked = (Test-ProfileLocked); logged_in = $null; hints_source = $null; cookie_count = $null
    }
    if ($ep) {
        $c = @(Get-CookiesFromEndpoint $ep)
        $o.logged_in = Get-LoginHints $c; $o.cookie_count = $c.Count; $o.hints_source = 'live'
        if ($ep.headless) { [void](Close-Endpoint $ep $null 8) }
    } else {
        if ($Probe -and $exe -and $o.profile_exists -and -not $o.profile_locked) {
            $c = @(Invoke-Headless $exe { param($e) Get-CookiesHeadless $e })
            $o.logged_in = Get-LoginHints $c; $o.cookie_count = $c.Count; $o.hints_source = 'headless'
        }
    }
    if (-not $exe) { $o.ok = $false; $o['error'] = 'Chrome / Edge not found'; $o['hint'] = '找不到已安裝的 Google Chrome 或 Microsoft Edge'; $o['code'] = 'no_browser' }
    return $o
}

function Do-Close {
    $ep = Get-OurEndpoint
    if ($ep) {
        $proc = $null
        if ($ep.pid) { try { $proc = Get-Process -Id ([int]$ep.pid) -ErrorAction Stop } catch { } }
        $how = Close-Endpoint $ep $proc 10
        return [ordered]@{ ok = $true; action = 'close'; was_running = $true; how = $how }
    }
    if (Test-ProfileLocked) {
        # 設定檔被沒開 debug port 的同設定檔視窗佔用：先請它正常關閉，不行再強制結束（只限我們的設定檔）
        $mains = @(Get-OurBrowserProcesses | Where-Object { $_.CommandLine -notmatch '--type=' })
        foreach ($m in $mains) { try { [void](Get-Process -Id $m.ProcessId -ErrorAction Stop).CloseMainWindow() } catch { } }
        if (Wait-Released 8 $null) { return [ordered]@{ ok = $true; action = 'close'; was_running = $true; how = 'graceful' } }
        Stop-OurProcessTree @($mains | ForEach-Object { [int]$_.ProcessId })
        $freed = Wait-Released 5 $null
        return [ordered]@{ ok = $freed; action = 'close'; was_running = $true; how = 'killed' }
    }
    return [ordered]@{ ok = $true; action = 'close'; was_running = $false; how = $null }
}

# ============================================================ main
try {
    $act = $Action.Trim().ToLowerInvariant()
    if ($act -notin @('open', 'export', 'tabs', 'status', 'close')) {
        Stop-With "unknown action: $Action" '可用的 -Action：open / export / tabs / status / close' 'bad_args'
    }
    if ($Browser -notin @('auto', 'chrome', 'edge')) {
        Stop-With "unknown browser: $Browser" '-Browser 只能是 auto / chrome / edge' 'bad_args'
    }
    # 同一個設定檔同時只能有一個動作在「啟動／關閉」瀏覽器（例如批次下載連續呼叫 export）
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProfileDir.ToLowerInvariant()))).Replace('-', '').Substring(0, 16)
    $script:Mutex = New-Object System.Threading.Mutex($false, "Local\mdl_login_browser_$hash")
    try { $got = $script:Mutex.WaitOne([TimeSpan]::FromSeconds(60)) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { $script:Mutex = $null; Stop-With 'another browser.ps1 action is still running' '另一個登入瀏覽器動作還在進行中，請稍後再試' 'busy' }

    $result = switch ($act) {
        'open'   { Do-Open }
        'export' { Do-Export }
        'tabs'   { Do-Tabs }
        'status' { Do-Status }
        'close'  { Do-Close }
    }
    Emit $result $(if ($result['ok']) { 0 } else { 1 })
} catch {
    $ex = $_.Exception
    $hint = $null; $code = 'error'
    $e = $ex
    while ($e) {
        if ($e.Data -and $e.Data.Contains('hint')) { $hint = $e.Data['hint']; $code = $e.Data['code']; $ex = $e; break }
        $e = $e.InnerException
    }
    $msg = $ex.Message
    if (-not $hint) {
        $hint = '登入瀏覽器操作失敗；請確認 Chrome/Edge 已安裝，並試著關閉登入瀏覽器後重試'
        Log ("unexpected error at line " + $_.InvocationInfo.ScriptLineNumber + ": " + $msg)
    }
    Log "ERROR: $msg"
    Log "提示: $hint"
    Emit ([ordered]@{ ok = $false; action = $Action; error = $msg; hint = $hint; code = $code }) 1
}
