#Requires -Version 5.1
<#
    影音下載器 GUI (PowerShell 5.1 + WinForms)
    --------------------------------------------------
    * 不依賴 Python，直接呼叫 bin\yt-dlp.exe（影片／音樂）與 bin\gallery-dl.exe（圖片）
    * 「MP4 影片」模式貼 IG / FB / X 貼文網址時，影片下載完會接著用圖片流程補抓同一則貼文的照片
    * 「MP3 音樂」模式一律在輸出資料夾底下的專用工作資料夾裡下載、成品再搬出來（絕不動到既有檔案）
    * 下載在背景行程執行，UI 由 WinForms Timer 輪詢暫存檔更新，不會凍結
    * 登入瀏覽器（tools\browser.ps1）一律以背景行程呼叫，結果同樣由 Timer 輪詢
    * 本檔案必須存成 UTF-8 with BOM
#>

$ErrorActionPreference = 'Stop'

# ============================================================ 路徑
if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot }
else { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$Root         = Split-Path -Parent $ScriptDir
$BinDir       = Join-Path $Root 'bin'
$ConfigDir    = Join-Path $Root 'config'
$YtDlpExe     = Join-Path $BinDir 'yt-dlp.exe'
$FFmpegExe    = Join-Path $BinDir 'ffmpeg.exe'
$SetupPs1     = Join-Path $ScriptDir 'setup.ps1'
$ProfilesPath = Join-Path $ConfigDir 'profiles.json'
$SettingsPath = Join-Path $ConfigDir 'gui_settings.json'
$DefaultOut   = Join-Path $Root 'downloads'
$GalleryDlExe = Join-Path $BinDir 'gallery-dl.exe'
$BrowserPs1   = Join-Path $ScriptDir 'browser.ps1'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $PowerShellExe)) { $PowerShellExe = 'powershell.exe' }

# 圖片模式：與 src\mdl.py download_images 相同的預設上限（防止誤貼帳號頁把整個帳號抓下來）
$ImgMaxFiles  = 100

# yt-dlp 輸出用 UTF-8，避免中文標題亂碼
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

# ============================================================ 組件 / DPI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    Add-Type -Namespace Win32Util -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
    [void][Win32Util.Dpi]::SetProcessDPIAware()
} catch { }

try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

# ============================================================ 設定檔
$FallbackProfiles = @'
{
  "common": ["--newline","--no-warnings","--ignore-config","--concurrent-fragments","4","--retries","10","--fragment-retries","10","--socket-timeout","20","--no-overwrites","--windows-filenames"],
  "video": {"format_best":"bv*+ba/b","format_capped":"bv*[height<={H}]+ba/b[height<={H}]/bv*+ba/b","sort":"ext:mp4:m4a","extra":["--merge-output-format","mp4","--embed-metadata"]},
  "audio": {"format":"ba/b","extra":["-x","--audio-format","mp3","--embed-metadata","--embed-thumbnail"]},
  "output_template": "%(title).120B [%(id)s].%(ext)s",
  "output_template_playlist": "%(playlist_title,playlist_id|)s/%(playlist_index|)s%(title).100B [%(id)s].%(ext)s",
  "quality_choices": ["best","2160","1440","1080","720","480","360"],
  "audio_quality_choices": ["0","320K","256K","192K","128K"]
}
'@

$script:ProfileWarn = $null
try {
    if (Test-Path -LiteralPath $ProfilesPath) {
        $Cfg = (Get-Content -LiteralPath $ProfilesPath -Raw -Encoding UTF8) | ConvertFrom-Json
    } else {
        $Cfg = $FallbackProfiles | ConvertFrom-Json
        $script:ProfileWarn = "找不到 config\profiles.json，改用內建預設參數。"
    }
} catch {
    $Cfg = $FallbackProfiles | ConvertFrom-Json
    $script:ProfileWarn = "config\profiles.json 讀取失敗（$($_.Exception.Message)），改用內建預設參數。"
}

function Get-CfgArray($value) {
    if ($null -eq $value) { return @() }
    return @($value)
}

# ============================================================ 使用者設定
function Read-GuiSettings {
    $d = [ordered]@{
        OutDir       = $DefaultOut
        Mode         = 'video'
        Quality      = 'best'
        AudioQuality = '0'
        Playlist     = $false
        Subs         = $false
        Cookies      = $false
        Browser      = 'chrome'
        LoginCookies = $false
        AutoPhotos   = $true
        BulkIG       = $false
    }
    try {
        if (Test-Path -LiteralPath $SettingsPath) {
            $s = (Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8) | ConvertFrom-Json
            foreach ($k in @($d.Keys)) {
                if ($null -ne $s.PSObject.Properties[$k] -and $null -ne $s.$k -and "$($s.$k)" -ne '') {
                    $d[$k] = $s.$k
                }
            }
        }
    } catch { }
    return $d
}

function Save-GuiSettings {
    try {
        if (-not (Test-Path -LiteralPath $ConfigDir)) {
            New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        }
        $o = [ordered]@{
            OutDir       = $txtOut.Text
            Mode         = (Get-ModeKey)
            Quality      = [string]$cboQuality.SelectedItem
            AudioQuality = (Get-AudioQualityValue)
            Playlist     = [bool]$chkPlaylist.Checked
            Subs         = [bool]$chkSubs.Checked
            Cookies      = [bool]$chkCookies.Checked
            Browser      = [string]$cboBrowser.SelectedItem
            LoginCookies = [bool]$chkUseLogin.Checked
            AutoPhotos   = [bool]$chkAutoPhotos.Checked
            BulkIG       = [bool]$chkBulk.Checked
        }
        $json = ($o | ConvertTo-Json -Depth 4)
        [System.IO.File]::WriteAllText($SettingsPath, $json, (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

$Settings = Read-GuiSettings

# ============================================================ 共用小工具
$script:AnsiRegex = New-Object System.Text.RegularExpressions.Regex (([string][char]27) + '\[[0-9;?]*[A-Za-z]')

function Format-Arg([string]$s) {
    if ($null -eq $s) { return '""' }
    if ($s -eq '') { return '""' }
    if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
    return $s
}

# 每個參數一律加引號：網址裡的 & 、格式字串裡的 < > 才不會被 cmd.exe 當成
# 指令分隔或重新導向；結尾反斜線要加倍，否則 \" 會被當成跳脫引號。
function ConvertTo-CmdArg([string]$s) {
    if ($null -eq $s) { $s = '' }
    $s = $s -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

function Build-CmdLine([string]$exe, [string[]]$argList, [string]$outFile, [string]$errFile) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((ConvertTo-CmdArg $exe))
    foreach ($a in $argList) { [void]$sb.Append(' '); [void]$sb.Append((ConvertTo-CmdArg $a)) }
    [void]$sb.Append(' >');  [void]$sb.Append((ConvertTo-CmdArg $outFile))
    [void]$sb.Append(' 2>'); [void]$sb.Append((ConvertTo-CmdArg $errFile))
    return $sb.ToString()
}

# 透過 cmd.exe 做檔案重新導向後再啟動。
# 之所以不用 Start-Process：它回傳的 Process 物件 ExitCode 永遠是 null，
# 無法判斷成功或失敗。直接用 System.Diagnostics.Process 才拿得到離開碼，
# 而 cmd.exe 會把子程式的離開碼原封不動往外傳。
function Start-Redirected([string]$exe, [string[]]$argList, [string]$outFile, [string]$errFile) {
    New-Item -ItemType File -Force -Path $outFile | Out-Null
    New-Item -ItemType File -Force -Path $errFile | Out-Null
    $inner = Build-CmdLine $exe $argList $outFile $errFile
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName         = $env:ComSpec
    $psi.Arguments        = '/d /s /c "' + $inner + '"'
    $psi.UseShellExecute  = $false
    $psi.CreateNoWindow   = $true
    $psi.WorkingDirectory = $Root
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    return $p
}

function New-TempFile([string]$tag) {
    $dir = Join-Path $env:TEMP 'mdl_gui'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir ("{0}_{1}.txt" -f $tag, [guid]::NewGuid().ToString('N').Substring(0, 8)))
}

function Remove-Quiet([string]$path) {
    try { if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } } catch { }
}

# ============================================================ 介面
$fontUI  = New-Object System.Drawing.Font('Microsoft JhengHei UI', 9.75)
$fontLog = New-Object System.Drawing.Font('Consolas', 9)

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = '影音下載器'
$form.Size            = New-Object System.Drawing.Size(720, 654)
$form.MinimumSize     = New-Object System.Drawing.Size(716, 576)
$form.StartPosition   = 'CenterScreen'
$form.Font            = $fontUI
# 版面座標一律以 96 DPI 為設計基準，實際縮放由 Update-Layout 自己算（見該函式說明）。
# 不用 AutoScaleMode=Dpi：實測 PS 5.1 裡 WinForms 只縮放了視窗本身、子控制項的
# 座標與大小原封不動，於是 120 DPI 下字型變大 25% 卻塞在原尺寸的框裡而被裁切。
$form.AutoScaleMode   = [System.Windows.Forms.AutoScaleMode]::None
$script:DesignClient  = New-Object System.Drawing.Size(704, 615)   # 96 DPI 下的 client 尺寸

$AnchorTLR = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$AnchorTR  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$AnchorAll = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom

# --- 網址
$lblUrl = New-Object System.Windows.Forms.Label
$lblUrl.Text = '影片網址（可一次貼多個，一行一個）'
$lblUrl.Location = New-Object System.Drawing.Point(12, 10)
$lblUrl.AutoSize = $true
$form.Controls.Add($lblUrl)

$txtUrls = New-Object System.Windows.Forms.TextBox
$txtUrls.Multiline = $true
$txtUrls.ScrollBars = 'Vertical'
$txtUrls.WordWrap = $false
$txtUrls.Location = New-Object System.Drawing.Point(12, 32)
$txtUrls.Size = New-Object System.Drawing.Size(682, 104)
$txtUrls.Anchor = $AnchorTLR
$form.Controls.Add($txtUrls)

# --- 模式 / 畫質 / 音質
# AutoSize = 讓 WinForms 自己量文字寬度，任何 DPI／字型都不會被裁切；
# 同一列後續控制項的 X 由 Update-Layout 依前一個控制項右緣重算。
$rbVideo = New-Object System.Windows.Forms.RadioButton
$rbVideo.Text = 'MP4 影片'
$rbVideo.AutoSize = $true
$rbVideo.Location = New-Object System.Drawing.Point(14, 149)
$form.Controls.Add($rbVideo)

$rbAudio = New-Object System.Windows.Forms.RadioButton
$rbAudio.Text = 'MP3 音樂'
$rbAudio.AutoSize = $true
$rbAudio.Location = New-Object System.Drawing.Point(118, 149)
$form.Controls.Add($rbAudio)

# 圖片：IG / FB / X 貼文的照片（整則貼文，輪播裡的影片也一起抓），引擎是 gallery-dl
$rbImage = New-Object System.Windows.Forms.RadioButton
$rbImage.Text = '圖片 (IG/FB/X)'
$rbImage.AutoSize = $true
$rbImage.Location = New-Object System.Drawing.Point(222, 149)
$form.Controls.Add($rbImage)

$lblQ = New-Object System.Windows.Forms.Label
$lblQ.Text = '畫質'
$lblQ.Location = New-Object System.Drawing.Point(232, 150)
$lblQ.AutoSize = $true
$form.Controls.Add($lblQ)

$cboQuality = New-Object System.Windows.Forms.ComboBox
$cboQuality.DropDownStyle = 'DropDownList'
$cboQuality.Location = New-Object System.Drawing.Point(272, 146)
$cboQuality.Size = New-Object System.Drawing.Size(92, 26)
foreach ($q in (Get-CfgArray $Cfg.quality_choices)) { [void]$cboQuality.Items.Add([string]$q) }
if ($cboQuality.Items.Count -eq 0) { foreach ($q in @('best', '2160', '1440', '1080', '720', '480', '360')) { [void]$cboQuality.Items.Add($q) } }
$form.Controls.Add($cboQuality)

$lblA = New-Object System.Windows.Forms.Label
$lblA.Text = '音質'
$lblA.Location = New-Object System.Drawing.Point(382, 150)
$lblA.AutoSize = $true
$form.Controls.Add($lblA)

$cboAudio = New-Object System.Windows.Forms.ComboBox
$cboAudio.DropDownStyle = 'DropDownList'
$cboAudio.Location = New-Object System.Drawing.Point(422, 146)
$cboAudio.Size = New-Object System.Drawing.Size(110, 26)
foreach ($q in (Get-CfgArray $Cfg.audio_quality_choices)) {
    $disp = if ("$q" -eq '0') { '0 (最佳)' } else { [string]$q }
    [void]$cboAudio.Items.Add($disp)
}
if ($cboAudio.Items.Count -eq 0) { foreach ($q in @('0 (最佳)', '320K', '256K', '192K', '128K')) { [void]$cboAudio.Items.Add($q) } }
$form.Controls.Add($cboAudio)

function Get-AudioQualityValue {
    $t = [string]$cboAudio.SelectedItem
    if (-not $t) { return '0' }
    return ($t -split '\s+')[0]
}

function Get-ModeKey {
    if ($rbImage.Checked) { return 'image' }
    if ($rbAudio.Checked) { return 'audio' }
    return 'video'
}

# 依模式與「是否正在下載」決定各控制項能不能按。
# 圖片模式用不到畫質／音質／字幕／播放清單；下載中不能換模式或 cookie 來源。
function Update-ModeUi {
    try {
        $running = [bool]$script:Job
        $mode = Get-ModeKey
        $cboQuality.Enabled  = ($mode -eq 'video')
        $cboAudio.Enabled    = ($mode -eq 'audio')
        $chkSubs.Enabled     = ($mode -eq 'video')
        $chkPlaylist.Enabled = ($mode -ne 'image')
        # 貼文照片一併下載只在「MP4 影片」模式有意義；工作開始時就定案，下載中不能改
        $chkAutoPhotos.Enabled = ($mode -eq 'video') -and (-not $running)
        # 整批下載只在「圖片」模式有意義；同樣工作開始時就定案，下載中不能改
        $chkBulk.Enabled = ($mode -eq 'image') -and (-not $running)
        foreach ($c in @($rbVideo, $rbAudio, $rbImage, $chkCookies, $chkUseLogin)) { $c.Enabled = -not $running }
        $cboBrowser.Enabled  = $chkCookies.Checked -and (-not $running)
        if ($mode -eq 'image') { $lblUrl.Text = '貼文網址（IG / FB / X 單篇貼文，可一次貼多個，一行一個）' }
        else { $lblUrl.Text = '影片網址（可一次貼多個，一行一個）' }
    } catch { }
}

# --- 輸出資料夾
$lblOut = New-Object System.Windows.Forms.Label
$lblOut.Text = '輸出資料夾'
$lblOut.Location = New-Object System.Drawing.Point(14, 186)
$lblOut.AutoSize = $true
$form.Controls.Add($lblOut)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(96, 182)
$txtOut.Size = New-Object System.Drawing.Size(518, 26)
$txtOut.Anchor = $AnchorTLR
$form.Controls.Add($txtOut)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '瀏覽'
$btnBrowse.Location = New-Object System.Drawing.Point(622, 181)
$btnBrowse.Size = New-Object System.Drawing.Size(72, 27)
$btnBrowse.Anchor = $AnchorTR
$form.Controls.Add($btnBrowse)

# --- 勾選項
$chkPlaylist = New-Object System.Windows.Forms.CheckBox
$chkPlaylist.Text = '下載整個播放清單'
$chkPlaylist.AutoSize = $true
$chkPlaylist.Location = New-Object System.Drawing.Point(14, 219)
$form.Controls.Add($chkPlaylist)

$chkSubs = New-Object System.Windows.Forms.CheckBox
$chkSubs.Text = '嵌入字幕(自動選中英)'
$chkSubs.AutoSize = $true
$chkSubs.Location = New-Object System.Drawing.Point(172, 219)
$form.Controls.Add($chkSubs)

# 「MP4 影片」模式貼 IG / FB / X 的貼文網址時，影片下載完接著補抓同一則貼文的照片（預設開啟）
$chkAutoPhotos = New-Object System.Windows.Forms.CheckBox
$chkAutoPhotos.Text = '貼文照片一併下載'
$chkAutoPhotos.AutoSize = $true
$chkAutoPhotos.Checked = $true
$chkAutoPhotos.Location = New-Object System.Drawing.Point(350, 219)
$form.Controls.Add($chkAutoPhotos)

# 「圖片」模式的整批下載：IG 帳號頁／自己的珍藏／珍藏分類抓全部（不設 100 個檔案上限、放子資料夾、檔案間隨機等待）
$chkBulk = New-Object System.Windows.Forms.CheckBox
$chkBulk.Text = '整個帳號／珍藏 (IG)'
$chkBulk.AutoSize = $true
$chkBulk.Checked = $false
$chkBulk.Enabled = $false
$chkBulk.Location = New-Object System.Drawing.Point(500, 219)
$form.Controls.Add($chkBulk)

# --- 舊的 cookie 來源（獨立一列，緊接在登入瀏覽器列上方）
$chkCookies = New-Object System.Windows.Forms.CheckBox
$chkCookies.Text = '用瀏覽器 Cookie'
$chkCookies.AutoSize = $true
$chkCookies.Location = New-Object System.Drawing.Point(14, 251)
$form.Controls.Add($chkCookies)

$cboBrowser = New-Object System.Windows.Forms.ComboBox
$cboBrowser.DropDownStyle = 'DropDownList'
$cboBrowser.Location = New-Object System.Drawing.Point(158, 247)
$cboBrowser.Size = New-Object System.Drawing.Size(110, 26)
foreach ($b in @('chrome', 'edge', 'firefox', 'brave')) { [void]$cboBrowser.Items.Add($b) }
$form.Controls.Add($cboBrowser)

# --- 登入瀏覽器列（tools\browser.ps1：專用設定檔的 Chrome/Edge，使用者平常的 Chrome 不受影響）
$btnLoginOpen = New-Object System.Windows.Forms.Button
$btnLoginOpen.Text = '開啟登入瀏覽器'
$btnLoginOpen.Location = New-Object System.Drawing.Point(14, 277)
$btnLoginOpen.Size = New-Object System.Drawing.Size(122, 28)
$form.Controls.Add($btnLoginOpen)

$btnLoginTabs = New-Object System.Windows.Forms.Button
$btnLoginTabs.Text = '抓目前分頁網址'
$btnLoginTabs.Location = New-Object System.Drawing.Point(144, 277)
$btnLoginTabs.Size = New-Object System.Drawing.Size(122, 28)
$form.Controls.Add($btnLoginTabs)

$chkUseLogin = New-Object System.Windows.Forms.CheckBox
$chkUseLogin.Text = '使用登入瀏覽器的 cookie'
$chkUseLogin.AutoSize = $true
$chkUseLogin.Location = New-Object System.Drawing.Point(280, 281)
$form.Controls.Add($chkUseLogin)

$lblLogin = New-Object System.Windows.Forms.Label
$lblLogin.Text = '登入狀態：讀取中…'
$lblLogin.AutoSize = $false
$lblLogin.AutoEllipsis = $true
$lblLogin.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblLogin.Cursor = [System.Windows.Forms.Cursors]::Hand
$lblLogin.Location = New-Object System.Drawing.Point(480, 280)
$lblLogin.Size = New-Object System.Drawing.Size(210, 22)
$lblLogin.Anchor = $AnchorTLR
$form.Controls.Add($lblLogin)

# --- 按鈕列
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '開始下載'
$btnStart.Location = New-Object System.Drawing.Point(14, 313)
$btnStart.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = '停止'
$btnStop.Location = New-Object System.Drawing.Point(132, 313)
$btnStop.Size = New-Object System.Drawing.Size(88, 32)
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = '開啟資料夾'
$btnOpen.Location = New-Object System.Drawing.Point(228, 313)
$btnOpen.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnOpen)

$btnUpdate = New-Object System.Windows.Forms.Button
$btnUpdate.Text = '更新 yt-dlp'
$btnUpdate.Location = New-Object System.Drawing.Point(346, 313)
$btnUpdate.Size = New-Object System.Drawing.Size(116, 32)
$form.Controls.Add($btnUpdate)

$btnSetup = New-Object System.Windows.Forms.Button
$btnSetup.Text = '現在設定'
$btnSetup.Location = New-Object System.Drawing.Point(470, 313)
$btnSetup.Size = New-Object System.Drawing.Size(104, 32)
$form.Controls.Add($btnSetup)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = '清除日誌'
$btnClear.Location = New-Object System.Drawing.Point(582, 313)
$btnClear.Size = New-Object System.Drawing.Size(104, 32)
$form.Controls.Add($btnClear)

# --- 說明提示
$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 15000
$tip.SetToolTip($rbImage, '下載 IG / FB / X 單篇貼文裡的所有照片（輪播裡的影片也一起抓），引擎是 gallery-dl。')
$tip.SetToolTip($chkAutoPhotos, '在「MP4 影片」模式貼上 IG / FB / X 的貼文網址時，影片下載完會自動把同一則貼文的照片也抓下來（不必切到圖片模式；只有照片的貼文也算成功）。YouTube 等影片網站不受影響。')
$tip.SetToolTip($chkBulk, '圖片模式專用。勾選後，貼上 IG 帳號頁網址（instagram.com/<帳號>/，或直接打 @帳號）、自己的珍藏（instagram.com/<你的帳號>/saved/）或某個珍藏分類（…/saved/<分類>/<數字ID>/）會下載「全部」貼文的照片與影片：不受每則 100 個檔案的上限、存到以帳號／分類命名的子資料夾、每個檔案之間隨機等待 0～4 秒（常態分佈，平均 2 秒）。必須同時勾選「使用登入瀏覽器的 cookie」。')
$tip.SetToolTip($chkCookies, '直接讀本機瀏覽器的 Cookie。Chrome/Edge 開著時通常會失敗（資料庫被鎖住）；建議改用下方的「登入瀏覽器」。')
$tip.SetToolTip($btnLoginOpen, '開一個專用的 Chrome/Edge 視窗（獨立設定檔），在裡面登入 IG / FB / X。你平常用的 Chrome 不受影響，可以照常開著。')
$tip.SetToolTip($btnLoginTabs, '把登入瀏覽器目前開著的網頁網址加進上方網址欄。')
$tip.SetToolTip($chkUseLogin, '每次下載前從登入瀏覽器匯出 cookie（存成暫存檔，用完即刪），不用關閉任何瀏覽器。')
$tip.SetToolTip($lblLogin, '登入瀏覽器裡 Instagram / Facebook / X 的登入狀態（✔ 已登入、✖ 未登入、? 未知）。點一下重新整理。')

# --- 進度
$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(14, 355)
$bar.Size = New-Object System.Drawing.Size(680, 18)
$bar.Minimum = 0
$bar.Maximum = 100
$bar.Anchor = $AnchorTLR
$form.Controls.Add($bar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '就緒'
$lblStatus.Location = New-Object System.Drawing.Point(14, 379)
$lblStatus.Size = New-Object System.Drawing.Size(680, 22)
$lblStatus.AutoEllipsis = $true
$lblStatus.Anchor = $AnchorTLR
$form.Controls.Add($lblStatus)

# --- 日誌
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Both'
$txtLog.WordWrap = $false
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$txtLog.Font = $fontLog
# 多了一列勾選項（+29）：往下推的高度剛好吃掉原本日誌下方沒用到的空白，視窗大小與日誌高度都不變
$txtLog.Location = New-Object System.Drawing.Point(12, 405)
$txtLog.Size = New-Object System.Drawing.Size(682, 200)
$txtLog.Anchor = $AnchorAll
$form.Controls.Add($txtLog)

# ============================================================ 版面重排（DPI 安全）
# 全部控制項的 Location/Size 都以 96 DPI 為設計值撰寫，這裡先把設計值記下來，
# 視窗建立後（Form.Load）再依實際 DPI 等比換算一次：
#   1. 固定尺寸控制項 → 座標與大小同乘縮放倍率
#   2. AutoSize 控制項（RadioButton/CheckBox/Label）→ 只縮放座標，寬度交給
#      WinForms 依實際字型量測，因此任何 DPI／字型替換都不會被裁切
#   3. 同一列 AutoSize 之後的控制項 → 依前一個控制項的實際右緣重排，避免重疊或大縫
# 這樣 100% / 125% / 150% / 200% 都是同一份邏輯，不是針對某個比例硬湊數字。
$script:DesignBounds = @{}
function Save-DesignBounds {
    foreach ($c in $form.Controls) { $script:DesignBounds[$c] = $c.Bounds }
}

function Get-DpiScale {
    try {
        $g = $form.CreateGraphics()
        $s = $g.DpiX / 96.0
        $g.Dispose()
        if ($s -le 0) { return 1.0 }
        return $s
    } catch { return 1.0 }
}

function Set-VCenter($ctrl, $ref) {
    try { $ctrl.Top = $ref.Top + [int][math]::Round(($ref.Height - $ctrl.Height) / 2.0) } catch { }
}

function Update-Layout {
    try {
        $form.SuspendLayout()
        $sc     = Get-DpiScale
        $gap    = [int][math]::Round(14 * $sc)   # 控制項之間的水平間距
        $margin = [int][math]::Round(14 * $sc)   # 視窗左右留白

        # --- 0. 視窗與所有控制項依 DPI 等比放大
        $form.ClientSize = New-Object System.Drawing.Size(
            [int][math]::Round($script:DesignClient.Width * $sc),
            [int][math]::Round($script:DesignClient.Height * $sc))
        foreach ($c in $form.Controls) {
            $b = $script:DesignBounds[$c]
            if ($null -eq $b) { continue }
            $x = [int][math]::Round($b.X * $sc)
            $y = [int][math]::Round($b.Y * $sc)
            # 注意：TextBox.AutoSize 預設就是 $true，不能只看這個屬性，
            # 否則文字框的高度永遠不會被縮放。只有文字標籤類才只縮放座標。
            $textOnly = $c.AutoSize -and (($c -is [System.Windows.Forms.Label]) -or
                                          ($c -is [System.Windows.Forms.CheckBox]) -or
                                          ($c -is [System.Windows.Forms.RadioButton]))
            if ($textOnly) {
                $c.Location = New-Object System.Drawing.Point($x, $y)
            } else {
                $c.SetBounds($x, $y, [int][math]::Round($b.Width * $sc), [int][math]::Round($b.Height * $sc))
            }
        }

        # --- 第一列：模式 / 畫質 / 音質
        $rbVideo.Left    = $margin
        $rbAudio.Left    = $rbVideo.Right + $gap
        $rbImage.Left    = $rbAudio.Right + $gap
        $lblQ.Left       = $rbImage.Right + $gap
        $cboQuality.Left = $lblQ.Right + [int][math]::Round(6 * $sc)
        $lblA.Left       = $cboQuality.Right + $gap
        $cboAudio.Left   = $lblA.Right + [int][math]::Round(6 * $sc)
        foreach ($c in @($rbVideo, $rbAudio, $rbImage, $lblQ, $lblA)) { Set-VCenter $c $cboQuality }
        $cboAudio.Top = $cboQuality.Top

        # --- 第二列：輸出資料夾（標籤不可壓到輸入框）
        $lblOut.Left = $margin
        $txtOut.Left = $lblOut.Right + [int][math]::Round(8 * $sc)
        $w = $btnBrowse.Left - $gap - $txtOut.Left
        if ($w -gt [int][math]::Round(80 * $sc)) { $txtOut.Width = $w }
        Set-VCenter $lblOut $txtOut

        # --- 第三列：下載選項（四個勾選項，Y 沿用設計值）
        $chkPlaylist.Left   = $margin
        $chkSubs.Left       = $chkPlaylist.Right + $gap
        $chkAutoPhotos.Left = $chkSubs.Right + $gap
        $chkBulk.Left       = $chkAutoPhotos.Right + $gap
        $chkSubs.Top        = $chkPlaylist.Top
        $chkAutoPhotos.Top  = $chkPlaylist.Top
        $chkBulk.Top        = $chkPlaylist.Top

        # --- 第三列之二：舊的「用瀏覽器 Cookie」+ 瀏覽器選單
        $chkCookies.Left  = $margin
        $cboBrowser.Left  = $chkCookies.Right + $gap
        Set-VCenter $chkCookies $cboBrowser

        # --- 第四列：登入瀏覽器（按鈕寬度不足就加寬；狀態標籤吃掉剩下的寬度）
        $btnGap = [int][math]::Round(8 * $sc)
        $pad    = [int][math]::Round(24 * $sc)
        $x      = $margin
        foreach ($b in @($btnLoginOpen, $btnLoginTabs)) {
            try {
                $need = [System.Windows.Forms.TextRenderer]::MeasureText($b.Text, $b.Font).Width + $pad
                if ($b.Width -lt $need) { $b.Width = $need }
            } catch { }
            $b.Left = $x
            $x = $b.Right + $btnGap
        }
        $btnLoginTabs.Top = $btnLoginOpen.Top
        $chkUseLogin.Left = $btnLoginTabs.Right + $gap
        Set-VCenter $chkUseLogin $btnLoginOpen
        $lblLogin.Left  = $chkUseLogin.Right + $gap
        $lblLogin.Width = [math]::Max([int][math]::Round(60 * $sc), $form.ClientSize.Width - $margin - $lblLogin.Left)
        Set-VCenter $lblLogin $btnLoginOpen

        # --- 第五列：按鈕（寬度不足就加寬，避免中文字被截斷）
        $x      = $margin
        foreach ($b in @($btnStart, $btnStop, $btnOpen, $btnUpdate, $btnSetup, $btnClear)) {
            try {
                $need = [System.Windows.Forms.TextRenderer]::MeasureText($b.Text, $b.Font).Width + $pad
                if ($b.Width -lt $need) { $b.Width = $need }
            } catch { }
            $b.Left = $x
            $x = $b.Right + $btnGap
        }

        # --- 依實際需要的寬度決定 MinimumSize，確保縮到最小時整列按鈕都看得見
        #     （登入狀態標籤至少要留得下「登入狀態：IG ✔ FB ✖ X ?」）
        $needLogin = $lblLogin.Left
        try { $needLogin += [System.Windows.Forms.TextRenderer]::MeasureText('登入狀態：IG ✔ FB ✖ X ?', $lblLogin.Font).Width + [int][math]::Round(4 * $sc) } catch { $needLogin += [int][math]::Round(170 * $sc) }
        $needClient = [math]::Max([math]::Max($btnClear.Right, $needLogin), $chkBulk.Right) + $margin
        $chrome     = $form.Width - $form.ClientSize.Width
        $minW       = $needClient + $chrome
        $minH       = $form.MinimumSize.Height
        if ($minH -lt [int][math]::Round(576 * $sc)) { $minH = [int][math]::Round(576 * $sc) }
        if ($form.MinimumSize.Width -lt $minW) {
            $form.MinimumSize = New-Object System.Drawing.Size($minW, $minH)
        } else {
            $form.MinimumSize = New-Object System.Drawing.Size($form.MinimumSize.Width, $minH)
        }
        if ($form.Width -lt $form.MinimumSize.Width) { $form.Width = $form.MinimumSize.Width }

        # --- 進度列 / 狀態列 / 日誌沿用 Anchor，只要跟著左右留白即可
        foreach ($c in @($bar, $lblStatus)) { $c.Left = $margin; $c.Width = $form.ClientSize.Width - ($margin * 2) }
        $txtUrls.Left = $margin - [int][math]::Round(2 * $sc)
        $txtLog.Left  = $txtUrls.Left
        $txtUrls.Width = $form.ClientSize.Width - ($txtUrls.Left * 2)
        $txtLog.Width  = $txtUrls.Width
    } catch {
    } finally {
        try { $form.ResumeLayout($true) } catch { }
    }
}

Save-DesignBounds

# ============================================================ 日誌
function Write-Log([string]$msg) {
    try {
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $txtLog.AppendText("[$stamp] $msg`r`n")
    } catch { }
}

function Write-Raw([string]$msg) {
    try { $txtLog.AppendText("$msg`r`n") } catch { }
}

# 後處理期間切成跑馬燈，讓使用者看得出來程式還活著
function Set-BarStyle([string]$style) {
    try {
        if ($style -eq 'Marquee') {
            if ($bar.Style -ne [System.Windows.Forms.ProgressBarStyle]::Marquee) {
                $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
                $bar.MarqueeAnimationSpeed = 30
            }
        } else {
            if ($bar.Style -ne [System.Windows.Forms.ProgressBarStyle]::Continuous) {
                $bar.MarqueeAnimationSpeed = 0
                $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            }
        }
    } catch { }
}

function Format-Size([double]$bytes) {
    if ($bytes -lt 1024) { return ("{0} B" -f [int]$bytes) }
    $u = @('KB', 'MB', 'GB', 'TB')
    $v = $bytes / 1024.0
    $i = 0
    while ($v -ge 1024 -and $i -lt ($u.Count - 1)) { $v = $v / 1024.0; $i++ }
    return ("{0:N1} {1}" -f $v, $u[$i])
}

# 停止後 yt-dlp 會保留中間檔供續傳（可能好幾百 MB）；不提示使用者會莫名其妙掉硬碟空間。
# 刻意不自動刪除：刪了就無法續傳，而且誤刪風險太高。
function Write-LeftoverNotice([string]$dir) {
    try {
        if (-not $dir) { return }
        if (-not (Test-Path -LiteralPath $dir)) { return }
        $items = @()
        foreach ($pat in @('*.part', '*.ytdl', '*.temp.*', '*.f*.mp4', '*.f*.m4a', '*.f*.webm', '*.f*.mkv', '*.f*.mp3', '*.f*.opus')) {
            $items += @(Get-ChildItem -LiteralPath $dir -Filter $pat -File -Recurse -Force -ErrorAction SilentlyContinue)
        }
        $items = @($items | Sort-Object -Property FullName -Unique)
        if ($items.Count -eq 0) { return }
        $sum = ($items | Measure-Object -Property Length -Sum).Sum
        Write-Log ("提醒：停止後保留了 {0} 個中間檔（合計約 {1}），位置：{2}" -f $items.Count, (Format-Size $sum), $dir)
        Write-Log '這些是 yt-dlp 的續傳暫存檔，下次下載同一部影片會自動接續；確定不再續傳可自行刪除以釋放空間。'
        foreach ($it in ($items | Select-Object -First 8)) {
            Write-Raw ("          " + $it.FullName + "  (" + (Format-Size $it.Length) + ")")
        }
        if ($items.Count -gt 8) { Write-Raw ("          ... 其餘 " + ($items.Count - 8) + " 個") }
    } catch { }
}

# ============================================================ 登入瀏覽器（tools\browser.ps1）
# 每個動作都是一個背景 powershell.exe 行程：stdout 只有一行 ASCII JSON、exit 0/1。
# 一律不用 Start-Process -Wait（-Action open 時它會等到使用者關掉瀏覽器才回來），
# 而是跟下載一樣用 Start-Redirected 啟動、由 Timer 輪詢 HasExited，完成後呼叫 OnDone。
$script:BgOps = New-Object System.Collections.ArrayList
$script:LastStatusAt = [datetime]::MinValue

function Start-BrowserOp {
    param([string]$Action, [string[]]$ExtraArgs, [scriptblock]$OnDone, $State)
    $op = @{
        Action = $Action; OnDone = $OnDone; State = $State; Proc = $null; Started = (Get-Date)
        OutFile = (New-TempFile ('br_' + $Action)); ErrFile = (New-TempFile ('br_' + $Action + '_err'))
    }
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $BrowserPs1, '-Action', $Action)
    if ($ExtraArgs) { $argList += $ExtraArgs }
    try {
        if (-not (Test-Path -LiteralPath $BrowserPs1)) { throw "找不到 $BrowserPs1" }
        $op.Proc = Start-Redirected $PowerShellExe $argList $op.OutFile $op.ErrFile
    } catch {
        $op.StartError = $_.Exception.Message
    }
    [void]$script:BgOps.Add($op)
    return $op
}

function Test-BrowserOpPending([string]$action) {
    foreach ($op in $script:BgOps) { if ($op.Action -eq $action) { return $true } }
    return $false
}

# 讀 browser.ps1 的結果；stdout 是空的（例如參數錯誤時 PowerShell 在進入腳本前就報錯）
# 或不是 JSON 時，組一個 ok=false 的物件，呼叫端不必另外處理。
function Read-BrowserResult($op) {
    $out = ''; $err = ''
    try { if (Test-Path -LiteralPath $op.OutFile) { $out = [System.IO.File]::ReadAllText($op.OutFile) } } catch { }
    # stderr 可能是 UTF-8（browser.ps1 自己的診斷）或主控台字碼頁（PowerShell 在進入腳本前的參數錯誤）
    try {
        if (Test-Path -LiteralPath $op.ErrFile) {
            $bytes = [System.IO.File]::ReadAllBytes($op.ErrFile)
            try { $err = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
            catch { $err = [System.Text.Encoding]::Default.GetString($bytes) }
        }
    } catch { }
    $r = $null
    $line = @($out -split "`r`n|`n" | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
    if ($line) { try { $r = $line | ConvertFrom-Json } catch { $r = $null } }
    if (-not $r) {
        # PowerShell 的錯誤格式：第一行是訊息，之後的 "At ..."／"+ ..." 是位置資訊
        $detail = (@($err -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and $_ -notmatch '^(\+|At |位於|所在位置)' }) | Select-Object -First 2) -join ' / '
        if ($op.StartError) { $detail = $op.StartError }
        if (-not $detail) { $detail = 'browser.ps1 沒有任何輸出' }
        $r = [pscustomobject]@{
            ok = $false; action = $op.Action; code = 'no_output'; error = $detail
            hint = '登入瀏覽器程式（tools\browser.ps1）沒有回傳結果，請確認檔案存在且未被防毒軟體擋住後再試'
        }
    }
    return $r
}

function Update-BgOps {
    if ($script:BgOps.Count -eq 0) { return }
    foreach ($op in @($script:BgOps.ToArray())) {
        if ($op.Proc -and -not $op.Proc.HasExited) { continue }
        # 先移出清單再呼叫 OnDone：OnDone 可能開對話框，對話框期間 Timer 會再次觸發
        $script:BgOps.Remove($op)
        $r = Read-BrowserResult $op
        Remove-Quiet $op.OutFile
        Remove-Quiet $op.ErrFile
        if ($op.OnDone) {
            try { & $op.OnDone $r $op.State }
            catch { Write-Log "內部錯誤（登入瀏覽器 $($op.Action)）：$($_.Exception.Message)" }
        }
    }
}

function Get-BrowserHint($r) {
    $h = [string]$r.hint
    if (-not $h) { $h = [string]$r.error }
    if (-not $h) { $h = '未知的錯誤' }
    return $h
}

# --- 登入狀態標籤
function Format-LoginMark($v) {
    if ($null -eq $v) { return '?' }
    # 用粗體的 ✔ / ✖：細的 ✓ / ✗ 在正黑體會退回成很小的 x，跟網站名稱「X」分不清（實測）
    if ([bool]$v) { return [string][char]0x2714 }   # ✔
    return [string][char]0x2716                     # ✖
}

function Set-LoginStatusText($logged, [string]$suffix, [string]$tipText) {
    $ig = $null; $fb = $null; $x = $null
    if ($logged) { $ig = $logged.instagram; $fb = $logged.facebook; $x = $logged.x }
    $t = '登入狀態：IG ' + (Format-LoginMark $ig) + ' FB ' + (Format-LoginMark $fb) + ' X ' + (Format-LoginMark $x)
    if ($suffix) { $t += $suffix }
    $lblLogin.Text = $t
    $base = '登入瀏覽器裡 Instagram / Facebook / X 的登入狀態（✔ 已登入、✖ 未登入、? 未知）。點一下重新整理。'
    if ($tipText) { $base = $tipText + "`r`n" + $base }
    try { $tip.SetToolTip($lblLogin, $base) } catch { }
}

function Set-LoginClosedText([string]$text, [string]$tipText) {
    $lblLogin.Text = $text
    try { $tip.SetToolTip($lblLogin, $tipText + "`r`n點一下重新整理。") } catch { }
}

function Request-LoginStatus([switch]$Force) {
    if (Test-BrowserOpPending 'status') { return }
    if (-not $Force -and ((Get-Date) - $script:LastStatusAt).TotalSeconds -lt 5) { return }
    $script:LastStatusAt = Get-Date
    [void](Start-BrowserOp 'status' @() {
        param($r, $st)
        $script:LastStatusAt = Get-Date
        if (-not $r.ok) {
            $lblLogin.Text = '登入狀態：無法使用'
            try { $tip.SetToolTip($lblLogin, (Get-BrowserHint $r)) } catch { }
            return
        }
        # 瀏覽器沒開時登入狀態未知（不做 -Probe，避免每次都在背景啟動瀏覽器），標籤直接說沒開
        if ($r.running) {
            Set-LoginStatusText $r.logged_in '' ('登入瀏覽器開著（port ' + $r.port + '）。')
        } elseif (-not $r.profile_exists) {
            Set-LoginClosedText '登入瀏覽器：尚未使用' '還沒有開過登入瀏覽器：按「開啟登入瀏覽器」並在裡面登入 IG / FB / X。'
        } else {
            Set-LoginClosedText '登入瀏覽器：未開啟' '登入瀏覽器沒開，IG / FB / X 的登入狀態未知；勾選「使用登入瀏覽器的 cookie」下載時仍會在背景讀取 cookie（約 2~5 秒）。'
        }
    } $null)
}

# --- 開啟登入瀏覽器
function Get-FirstUrlInBox {
    foreach ($ln in ($txtUrls.Text -split "`r`n|`n|`r")) {
        $s = $ln.Trim()
        if ($s -match '^https?://\S+$') { return $s }
    }
    return $null
}

function Invoke-LoginOpen([string]$url) {
    if (Test-BrowserOpPending 'open') { return }
    $btnLoginOpen.Enabled = $false
    $a = @()
    if ($url) { $a = @('-Url', $url) }
    if ($url) { Write-Log "開啟登入瀏覽器：$url" } else { Write-Log '開啟登入瀏覽器…' }
    [void](Start-BrowserOp 'open' $a {
        param($r, $st)
        $btnLoginOpen.Enabled = $true
        if (-not $r.ok) {
            Write-Log ('無法開啟登入瀏覽器：' + (Get-BrowserHint $r))
            if ($r.error -and $r.hint) { Write-Raw ('          （' + $r.error + '）') }
            Request-LoginStatus -Force
            return
        }
        switch ([string]$r.mode) {
            'launched' {
                Write-Log ('登入瀏覽器已開啟（' + $r.browser + ' ' + $r.version + '，獨立設定檔，你平常用的瀏覽器不受影響）。')
                Write-Log '請在這個視窗登入 Instagram / Facebook / X（只需登入一次），之後勾選「使用登入瀏覽器的 cookie」再下載。'
            }
            'new_tab'  { Write-Log ('登入瀏覽器已經開著，已在新分頁開啟：' + $r.url) }
            default    { Write-Log '登入瀏覽器已經開著，已切到前面。' }
        }
        Request-LoginStatus -Force
    } $null)
}

# --- 抓目前分頁網址
function Add-UrlToBox([string]$url) {
    $lines = @($txtUrls.Text -split "`r`n|`n|`r" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($lines -contains $url) { Write-Log "網址已經在清單裡：$url"; return }
    if ($lines.Count -eq 0) { $txtUrls.Text = $url }
    else {
        $t = $txtUrls.Text.TrimEnd("`r", "`n", ' ')
        $txtUrls.Text = $t + "`r`n" + $url
    }
    $txtUrls.SelectionStart = $txtUrls.Text.Length
    $txtUrls.ScrollToCaret()
    Write-Log "已加入網址：$url"
}

function Show-TabPicker($tabs) {
    $sc = Get-DpiScale
    $S = { param($v) [int][math]::Round($v * $sc) }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '選擇登入瀏覽器的分頁'
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.Font = $fontUI
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.MaximizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.ClientSize = New-Object System.Drawing.Size((& $S 640), (& $S 330))
    $dlg.MinimumSize = New-Object System.Drawing.Size((& $S 420), (& $S 240))

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.AutoSize = $true
    $lbl.Text = '登入瀏覽器開著的分頁（最近使用的在上面），可按 Ctrl 多選：'
    $lbl.Location = New-Object System.Drawing.Point((& $S 10), (& $S 10))
    $dlg.Controls.Add($lbl)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $true
    $lv.HideSelection = $false
    $lv.Location = New-Object System.Drawing.Point((& $S 10), (& $S 34))
    $lv.Size = New-Object System.Drawing.Size((& $S 620), (& $S 244))
    $lv.Anchor = $AnchorAll
    [void]$lv.Columns.Add('標題', (& $S 250))
    [void]$lv.Columns.Add('網址', (& $S 345))
    foreach ($t in $tabs) {
        $title = [string]$t.title
        if (-not $title) { $title = '(無標題)' }
        $it = New-Object System.Windows.Forms.ListViewItem($title)
        [void]$it.SubItems.Add([string]$t.url)
        $it.Tag = [string]$t.url
        [void]$lv.Items.Add($it)
    }
    if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true; $lv.Items[0].Focused = $true }
    $lv.Add_DoubleClick({ $this.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::OK })
    $dlg.Controls.Add($lv)

    $pad = & $S 24
    $bOk = New-Object System.Windows.Forms.Button
    $bOk.Text = '加入網址'
    $bOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $bCancel = New-Object System.Windows.Forms.Button
    $bCancel.Text = '取消'
    $bCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $bh = & $S 30
    $x = $dlg.ClientSize.Width - (& $S 10)
    foreach ($b in @($bCancel, $bOk)) {
        $w = [math]::Max((& $S 90), [System.Windows.Forms.TextRenderer]::MeasureText($b.Text, $fontUI).Width + $pad)
        $x -= $w
        $b.SetBounds($x, $dlg.ClientSize.Height - $bh - (& $S 10), $w, $bh)
        $b.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        $dlg.Controls.Add($b)
        $x -= (& $S 8)
    }
    $dlg.AcceptButton = $bOk
    $dlg.CancelButton = $bCancel
    $script:PickerForm = $dlg
    $res = $dlg.ShowDialog($form)
    $script:PickerForm = $null
    $urls = @()
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($it in $lv.SelectedItems) { $urls += [string]$it.Tag }
    }
    $dlg.Dispose()
    return , $urls
}

# 未登入時 IG 會把貼文頁導到 /accounts/login/?next=<原網址>（實測）；分頁網址就變成登入頁，
# 這裡還原成原本的貼文網址，免得使用者抓到一個登入頁。
function Resolve-TabUrl([string]$url) {
    if ($url -match '^https?://(?:www\.)?instagram\.com/accounts/login/?\?(?:.*&)?next=([^&#]+)') {
        try {
            $next = [Uri]::UnescapeDataString($Matches[1])
            if ($next.StartsWith('/')) { $next = 'https://www.instagram.com' + $next }
            $next = $next -replace '\?__coig_login=1$', '' -replace '&__coig_login=1', ''
            if ($next -match '^https?://(?:www\.)?instagram\.com/') { return $next }
        } catch { }
    }
    return $url
}

function Invoke-LoginTabs {
    if (Test-BrowserOpPending 'tabs') { return }
    $btnLoginTabs.Enabled = $false
    [void](Start-BrowserOp 'tabs' @() {
        param($r, $st)
        $btnLoginTabs.Enabled = $true
        if (-not $r.ok) { Write-Log ('無法讀取登入瀏覽器的分頁：' + (Get-BrowserHint $r)); return }
        if (-not $r.running) {
            Write-Log '登入瀏覽器沒有開啟，抓不到分頁網址。'
            Set-LoginClosedText '登入瀏覽器：未開啟' '登入瀏覽器沒開，IG / FB / X 的登入狀態未知。'
            $ans = [System.Windows.Forms.MessageBox]::Show('登入瀏覽器沒有開啟。要現在開啟嗎？', '影音下載器',
                [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) { Invoke-LoginOpen $null }
            return
        }
        # 只要一般網頁：chrome:// 、about: 、devtools:// 、擴充功能頁等一律略過
        $pages = @(@($r.tabs) | Where-Object { $_ -and ([string]$_.url) -match '^https?://' } |
            ForEach-Object { [pscustomobject]@{ title = [string]$_.title; url = (Resolve-TabUrl ([string]$_.url)) } })
        if ($pages.Count -eq 0) {
            Write-Log '登入瀏覽器裡沒有一般網頁分頁（chrome:// 、about: 之類的頁面已略過）。'
            return
        }
        if ($pages.Count -eq 1) { Add-UrlToBox ([string]$pages[0].url); return }
        $picked = Show-TabPicker $pages
        foreach ($u in $picked) { Add-UrlToBox $u }
    } $null)
}

# --- 下載前匯出 cookie
# 只匯出網址所屬網站的 cookie；認不得的網站（或網址解析不了）就全部匯出（寧可多給也不要漏掉）。
function Get-UrlHost([string]$url) {
    try { return ([Uri]$url).Host.ToLowerInvariant() } catch { return $null }
}

function Test-HostIn([string]$h, [string[]]$roots) {
    if (-not $h) { return $false }
    foreach ($r in $roots) { if ($h -eq $r -or $h.EndsWith('.' + $r)) { return $true } }
    return $false
}

# 回傳 instagram / facebook / x（登入提示用的鍵名，與 browser.ps1 的 logged_in 一致）或 $null
function Get-LoginSiteKey([string]$url) {
    $h = Get-UrlHost $url
    if (Test-HostIn $h @('instagram.com')) { return 'instagram' }
    if (Test-HostIn $h @('facebook.com', 'fb.com', 'fb.watch')) { return 'facebook' }
    if (Test-HostIn $h @('x.com', 'twitter.com')) { return 'x' }
    return $null
}

function Get-CookieDomains([string[]]$urls) {
    $set = New-Object System.Collections.Generic.List[string]
    foreach ($u in $urls) {
        $h = Get-UrlHost $u
        $d = $null
        if (Test-HostIn $h @('instagram.com')) { $d = @('instagram.com') }
        elseif (Test-HostIn $h @('facebook.com', 'fb.com', 'fb.watch')) { $d = @('facebook.com', 'fb.watch') }
        elseif (Test-HostIn $h @('x.com', 'twitter.com')) { $d = @('x.com', 'twitter.com') }
        elseif (Test-HostIn $h @('youtube.com', 'youtu.be', 'youtube-nocookie.com')) { $d = @('youtube.com', 'google.com') }
        if (-not $d) { return '' }   # 不確定 → 全部匯出
        foreach ($x in $d) { if (-not $set.Contains($x)) { $set.Add($x) } }
    }
    return ($set -join ',')
}

function Start-CookieExport {
    $job = $script:Job
    $job.CookieFile = New-TempFile 'cookies'
    $domains = Get-CookieDomains $job.Urls
    $a = @('-OutFile', $job.CookieFile)
    if ($domains) { $a += @('-Domains', $domains) }
    $what = if ($domains) { $domains } else { '全部網站' }
    Write-Log "從登入瀏覽器匯出 cookie（$what）…"
    $lblStatus.Text = '匯出登入瀏覽器的 cookie 中…（瀏覽器沒開時會在背景啟動，約需 2~5 秒）'
    Set-BarStyle 'Marquee'
    $job.ExportOp = Start-BrowserOp 'export' $a { param($r, $st) Complete-CookieExport $r $st } $job
}

function Complete-CookieExport($r, $expJob) {
    $job = $script:Job
    if (-not $job -or -not [object]::ReferenceEquals($job, $expJob)) {
        # 工作已經不在了（例如視窗關閉中）→ 只負責把 cookie 暫存檔刪掉
        if ($expJob) { Remove-Quiet $expJob.CookieFile }
        return
    }
    $job.ExportOp = $null
    if ($job.Stopping) {
        Write-Log '已停止（cookie 匯出結束後才中止，沒有開始下載）。'
        Finish-Job
        return
    }
    $fileOk = $false
    try { $fileOk = ($r.ok -and (Test-Path -LiteralPath $job.CookieFile)) } catch { }
    if (-not $fileOk) {
        $hint = Get-BrowserHint $r
        if ($r.ok) { $hint = '匯出的 cookie 檔不見了' }
        Write-Log "無法從登入瀏覽器匯出 cookie：$hint"
        if ($r.error -and $r.hint) { Write-Raw ('          （' + $r.error + '）') }
        Write-Log '已停止本次工作。可先按「開啟登入瀏覽器」確認能開，或取消勾選「使用登入瀏覽器的 cookie」以未登入狀態下載。'
        $job.Fail = $job.Urls.Count
        Finish-Job
        return
    }
    $how = if ([string]$r.mode -eq 'live') { '登入瀏覽器開著，直接讀取' } else { '登入瀏覽器沒開，以背景模式讀取' }
    Write-Log ("已匯出 {0} 個 cookie（{1}）。" -f $r.count, $how)
    foreach ($w in @($r.warnings)) { if ($w) { Write-Log "登入瀏覽器提示：$w" } }
    if ([int]$r.count -eq 0) {
        Write-Log '警告：匯出的 cookie 是 0 個，本次等同未登入。請先按「開啟登入瀏覽器」登入網站。'
    }
    if ($r.logged_in) {
        Set-LoginStatusText $r.logged_in '' ('上次匯出：' + (Get-Date).ToString('HH:mm:ss') + '。')
        $names = @{ instagram = 'Instagram'; facebook = 'Facebook'; x = 'X' }
        $warned = @{}
        foreach ($u in $job.Urls) {
            $k = Get-LoginSiteKey $u
            if (-not $k -or $warned.ContainsKey($k)) { continue }
            $warned[$k] = $true
            if ($r.logged_in.$k -eq $false) {
                Write-Log ("警告：登入瀏覽器沒有登入 {0}（找不到它的登入 cookie），本次等同未登入：公開內容照樣能下載，需要登入的內容請先按「開啟登入瀏覽器」登入 {0}。" -f $names[$k])
            }
        }
    }
    Start-CurrentItem
}

# ============================================================ 圖片模式（gallery-dl，IG 未登入時改用 yt-dlp 備援）
# 參數與流程對照 src\mdl.py download_images / _ig_fallback_ytdlp：
#   * gallery-dl 一律 --config-ignore、cache.file=null、cookies-update=false、path-extended=false，
#     X 被限流直接報錯（ratelimit=abort），--range 1-<上限> 防止誤抓整個帳號。
#   * 檔名：<帳號>_<貼文ID>_<序號>.<副檔名>（用 extractor.<站台>.filename，不能用 -f）。
#   * FB /<粉專>/photos/<ID>/ 會被當成整個粉專相片牆 → 改寫成單張照片網址。
#   * 結果一律以磁碟為準：檔案要存在、非空、而且不是 HTML 錯誤頁。
#   * IG 單篇貼文未登入時 gallery-dl 會撞登入牆 → yt-dlp -J 取得每一格，照片直接下載原圖網址，
#     影片那幾格交給 yt-dlp；檔名與 gallery-dl 相同，兩個引擎互相認得已下載的檔案。
Add-Type -AssemblyName System.Web.Extensions
$script:Jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:Jss.MaxJsonLength = [int]::MaxValue
$script:Jss.RecursionLimit = 512

$script:MetaSep    = '|@|'
$script:GdlMetaFmt = @('{_path}', '{category}', '{subcategory}', '{username|author[name]|user[name]}',
                       '{post_shortcode|tweet_id|post_id|id}', '{set_id}', '{extension}',
                       '{description|content|caption|title!j}') -join '|@|'
$script:IgPostRe       = '^https?://(?:www\.|m\.)?instagram\.com/(?:[^/?#]+/)?(?:p|reels?|tv)/([A-Za-z0-9_-]+)'
$script:XStatusRe      = '^https?://(?:(?:www|mobile)\.)?(?:x|twitter|fxtwitter|vxtwitter)\.com/[^/?#]+/status(?:es)?/(\d+)'
$script:FbPhotosPathRe = '^https?://(?:[a-z0-9-]+\.)?facebook\.com/[^/?#]+/photos/(?:[^/?#]+/)?(\d{6,})/?(?:[?#].*)?$'
$script:FbStoryPhpRe   = '^https?://(?:[a-z0-9-]+\.)?facebook\.com/story\.php/?\?(.+)$'
$script:FbSharePostRe  = '^https?://(?:[a-z0-9-]+\.)?facebook\.com/share/p/[A-Za-z0-9_-]+'
# gallery-dl 會當成「單篇貼文／單張照片」處理的 FB 網址（同 mdl.py _FB_SINGLE_POST_RE）。
# 影片模式的照片補抓只接受這些：相片牆、相簿清單、個人檔案一律不抓。
$script:FbSinglePostRe = '^https?://(?:[a-z0-9-]+\.)?facebook\.com/(?:photo(?:\.php)?/?\?(?:[^#]*&)?fbid=\d+|permalink\.php\?|(?:[^/?#]+/){1,3}(?:posts|permalink)/[^/?#]+)'
$script:GdlLoginKeys = @('redirect to login page', 'accounts/login', 'authrequired', 'authorizationerror',
    'login required', 'needed to access', 'login to view', 'log in to', 'sign in',
    'checkpoint required', 'private account', 'this account is private', 'protected tweets')
$script:ImageExts = @('jpg', 'jpeg', 'jfif', 'png', 'gif', 'webp', 'heic', 'heif', 'avif', 'bmp', 'tif', 'tiff')
$script:VideoExts = @('mp4', 'm4v', 'mov', 'webm', 'mkv', 'avi', 'flv', 'ts', '3gp')
$script:VideoSiteHosts = @('youtube.com', 'youtu.be', 'vimeo.com', 'bilibili.com', 'b23.tv', 'tiktok.com',
    'twitch.tv', 'dailymotion.com', 'nicovideo.jp')
$script:ListingSubcats = @('user', 'posts', 'reels', 'tagged', 'stories', 'highlights', 'saved', 'tag', 'collection',
    'timeline', 'media', 'tweets', 'replies', 'likes', 'bookmark', 'list', 'search', 'photos',
    'albums', 'followed', 'following', 'community')

# JavaScriptSerializer 回傳 Dictionary[string,object]：它的 IDictionary.Contains 是明確介面實作，
# PowerShell 叫不到，所以用 ContainsKey。
function Get-JVal($d, [string]$k) {
    if ($d -is [System.Collections.Generic.IDictionary[string, object]]) {
        if ($d.ContainsKey($k)) { return $d[$k] }
        return $null
    }
    if ($d -is [System.Collections.IDictionary] -and $d.Contains($k)) { return $d[$k] }
    return $null
}

function Get-ImgSite([string]$url) {
    $h = Get-UrlHost $url
    if (Test-HostIn $h @('instagram.com')) { return 'instagram' }
    if (Test-HostIn $h @('x.com', 'twitter.com')) { return 'twitter' }
    if (Test-HostIn $h @('facebook.com', 'fb.com', 'fb.watch')) { return 'facebook' }
    return $null
}

function Get-PostToken([string]$url) {
    if ($url -match $script:IgPostRe) { return $Matches[1] }
    if ($url -match $script:XStatusRe) { return $Matches[1] }
    if ($url -match '[?&]fbid=(\d{6,})') { return $Matches[1] }
    return $null
}

function Resolve-ImageUrl([string]$url) {
    $notes = New-Object System.Collections.ArrayList
    if ($url -match $script:FbPhotosPathRe) {
        $fixed = 'https://www.facebook.com/photo/?fbid=' + $Matches[1]
        [void]$notes.Add("已把 Facebook 照片網址改寫成 $fixed（原網址會被當成整個粉專的相片牆）。")
        $url = $fixed
    }
    # 實測（gallery-dl 1.32.14，同 mdl.py _normalize_image_url）：facebook.com/story.php?story_fbid=…&id=…
    # 會被當成名叫 "story.php" 的個人檔案（→ 整個相片牆），permalink.php 帶同樣的參數才是單篇貼文。
    if ($url -match $script:FbStoryPhpRe) {
        $storyId = $null; $ownerId = $null
        foreach ($kv in ((($Matches[1] -split '#', 2)[0]) -split '&')) {
            $pair = $kv -split '=', 2
            if ($pair.Count -lt 2) { continue }
            $val = $pair[1]
            try { $val = [Uri]::UnescapeDataString(($pair[1] -replace '\+', ' ')) } catch { }
            if ($pair[0] -eq 'story_fbid' -and -not $storyId) { $storyId = $val }
            elseif ($pair[0] -eq 'id' -and -not $ownerId) { $ownerId = $val }
        }
        if ($storyId -and $ownerId) {
            $fixed = 'https://www.facebook.com/permalink.php?story_fbid=' + [Uri]::EscapeDataString($storyId) + '&id=' + [Uri]::EscapeDataString($ownerId)
            [void]$notes.Add("已把 Facebook 貼文網址改寫成 $fixed（story.php 會被 gallery-dl 當成個人檔案）。")
            $url = $fixed
        }
    }
    if ($url -match '[?&]set=pcb\.(\d+)' -and $url -notmatch '/media/set') {
        [void]$notes.Add('這張 Facebook 照片屬於一則多圖貼文，本次只下載這一張；要整則貼文請改用 ' +
            "https://www.facebook.com/media/set/?set=pcb.$($Matches[1]) 或貼文本身的網址。")
    }
    return @{ Url = $url; Notes = $notes }
}

function Get-ImgNameBudget([string]$dir) {
    $budget = 260 - 10 - ($dir.Length + 1)
    $warn = $null
    if ($budget -lt 40) {
        $warn = "輸出資料夾路徑已經有 $($dir.Length) 個字元，逼近 Windows 的 260 字元上限：檔名只能留最短的長度，仍有可能下載失敗，建議改用較短的輸出資料夾（例如 D:\dl）。"
        $budget = 40
    }
    return @{ Budget = [math]::Min($budget, 150); Warn = $warn }
}

function Get-ImgFilenameArgs([int]$budget) {
    $userCap = [math]::Max(8, [math]::Min(40, $budget - 35))
    $genCap  = [math]::Max(16, [math]::Min(120, $budget - 30))
    return @(
        '-o', "extractor.instagram.filename={username[:$userCap]}_{post_shortcode|shortcode}_{num}.{extension}",
        # 限時動態／精選動態：post_shortcode 是帳號 ID 換算的（每個帳號固定，例如 natgeo 永遠是 DAK8）、num 是當下的
        # 排列位置，兩個都不能用——隔天的第一則會撞名而被當成「已存在」。改用每一則自己的日期與代碼（同 mdl.py）。
        '-o', "extractor.instagram.stories.filename={username[:$userCap]}_story_{date!s:.10}_{shortcode}.{extension}",
        '-o', "extractor.instagram.highlights.filename={username[:$userCap]}_story_{date!s:.10}_{shortcode}.{extension}",
        '-o', "extractor.instagram.stories-tray.filename={username[:$userCap]}_story_{date!s:.10}_{shortcode}.{extension}",
        '-o', "extractor.twitter.filename={author[name][:$userCap]}_{tweet_id}_{num}.{extension}",
        '-o', "extractor.facebook.filename={username[:$userCap]}_{id}_{num}.{extension}",
        '-o', "extractor.filename={category}_{filename[:$genCap]}.{extension}")
}

function ConvertTo-SafeComponent($text, [int]$limit) {
    $s = [regex]::Replace([string]$text, '[<>:"/\\|?*\x00-\x1f]', '_').Trim()
    if ($limit -lt 1) { $limit = 1 }
    if ($s.Length -gt $limit) { $s = $s.Substring(0, $limit) }
    $s = $s.TrimEnd(' ', '.')
    if (-not $s) { $s = '_' }
    return $s
}

function Test-BytesAt([byte[]]$b, [int]$off, [byte[]]$sig) {
    if ($b.Length -lt ($off + $sig.Length)) { return $false }
    for ($i = 0; $i -lt $sig.Length; $i++) { if ($b[$off + $i] -ne $sig[$i]) { return $false } }
    return $true
}

# 看檔頭判斷實際內容：image / video / html（錯誤頁）/ unknown
function Get-MediaSniff([string]$path) {
    $b = $null
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $buf = New-Object byte[] 64
            $n = $fs.Read($buf, 0, 64)
            $b = New-Object byte[] $n
            [Array]::Copy($buf, $b, $n)
        } finally { $fs.Close() }
    } catch { return 'unknown' }
    $A = { param([string]$s) [System.Text.Encoding]::ASCII.GetBytes($s) }
    if ((Test-BytesAt $b 0 ([byte[]](0xFF, 0xD8, 0xFF))) -or
        (Test-BytesAt $b 0 ([byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))) -or
        (Test-BytesAt $b 0 (& $A 'GIF87a')) -or (Test-BytesAt $b 0 (& $A 'GIF89a')) -or
        ((Test-BytesAt $b 0 (& $A 'RIFF')) -and (Test-BytesAt $b 8 (& $A 'WEBP'))) -or
        (Test-BytesAt $b 0 ([byte[]](0x49, 0x49, 0x2A, 0x00))) -or (Test-BytesAt $b 0 ([byte[]](0x4D, 0x4D, 0x00, 0x2A)))) {
        return 'image'
    }
    if (Test-BytesAt $b 4 (& $A 'ftyp')) {
        $brand = ''
        if ($b.Length -ge 12) { $brand = [System.Text.Encoding]::ASCII.GetString($b, 8, 4).ToLowerInvariant() }
        if (@('heic', 'heix', 'hevc', 'heim', 'heis', 'mif1', 'msf1', 'avif', 'avis') -contains $brand) { return 'image' }
        return 'video'
    }
    if ((Test-BytesAt $b 0 ([byte[]](0x1A, 0x45, 0xDF, 0xA3))) -or (Test-BytesAt $b 0 (& $A 'FLV')) -or
        ((Test-BytesAt $b 0 (& $A 'RIFF')) -and (Test-BytesAt $b 8 (& $A 'AVI')))) {
        return 'video'
    }
    $text = [System.Text.Encoding]::ASCII.GetString($b).TrimStart().ToLowerInvariant()
    foreach ($p in @('<!doctype', '<html', '<?xml', '<head', '{', '[')) { if ($text.StartsWith($p)) { return 'html' } }
    if ($text.Contains('<html')) { return 'html' }
    return 'unknown'
}

function Get-MediaKind([string]$path, [string]$sniffed) {
    if ($sniffed -eq 'image' -or $sniffed -eq 'video') { return $sniffed }
    $ext = [System.IO.Path]::GetExtension($path).TrimStart('.').ToLowerInvariant()
    if ($script:ImageExts -contains $ext) { return 'image' }
    if ($script:VideoExts -contains $ext) { return 'video' }
    return 'other'
}

function Read-GdlMeta([string]$path, [bool]$downloaded) {
    $rows = New-Object System.Collections.ArrayList
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return , $rows }
    $lines = @()
    try { $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8) } catch { return , $rows }
    foreach ($line in $lines) {
        if (-not $line.Trim()) { continue }
        $parts = @($line.Split([string[]]@($script:MetaSep), 8, [System.StringSplitOptions]::None))
        while ($parts.Count -lt 8) { $parts += 'None' }
        $v = @()
        foreach ($p in $parts) { $t = ([string]$p).Trim(); if ($t -eq '' -or $t -eq 'None') { $v += $null } else { $v += $t } }
        $desc = $v[7]
        if ($desc -and $desc.StartsWith('"')) { try { $desc = [string]$script:Jss.DeserializeObject($desc) } catch { } }
        [void]$rows.Add(@{ Path = ([string]$parts[0]).Trim(); Site = $v[1]; Subcategory = $v[2]; Uploader = $v[3]
                           PostId = $v[4]; SetId = $v[5]; Ext = $v[6]; Description = $desc; Downloaded = $downloaded })
    }
    return , $rows
}

# 以磁碟為準整理結果：必須存在、非空、不是 HTML 錯誤頁。本次新下載、內容卻是 HTML 的檔案會刪掉。
# candidates：每筆是 @{ P = 路徑; D = 是否本次新下載 }（用 hashtable 而不是二元素陣列：
# 只有一筆時陣列會被 PowerShell 管線攤平）
function Get-CollectedMedia($candidates, [string]$outDir) {
    $files = New-Object System.Collections.ArrayList
    $warns = New-Object System.Collections.ArrayList
    $seen = @{}
    $missing = 0; $empty = 0
    foreach ($c in $candidates) {
        $p = [string]$c.P; $downloaded = [bool]$c.D
        if (-not $p) { continue }
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $outDir $p }
        try { $p = [System.IO.Path]::GetFullPath($p) } catch { }
        $key = $p.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $size = -1
        try {
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $missing++; continue }
            $size = (Get-Item -LiteralPath $p -Force).Length
        } catch { $missing++; continue }
        if ($size -le 0) { $empty++; continue }
        $sniff = Get-MediaSniff $p
        $name = [System.IO.Path]::GetFileName($p)
        if ($sniff -eq 'html') {
            $note = "$name 的內容是網頁（HTML 錯誤頁）而不是照片或影片，已排除"
            if ($downloaded -and $p.StartsWith($outDir.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; $note += '並刪除' } catch { }
            }
            [void]$warns.Add($note + '。')
            continue
        }
        [void]$files.Add(@{ Path = $p; Name = $name; Size = $size; Kind = (Get-MediaKind $p $sniff); Existing = (-not $downloaded) })
    }
    if ($missing) { [void]$warns.Add("有 $missing 個回報的檔案實際上不存在，已從結果中排除。") }
    if ($empty) { [void]$warns.Add("有 $empty 個檔案是 0 位元組，已從結果中排除。") }
    return @{ Files = $files; Warnings = $warns }
}

function Get-PartFileNames([string]$dir) {
    $set = @{}
    try { foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.part' -File -Force -ErrorAction Stop)) { $set[$f.Name] = $true } } catch { }
    return $set
}

# 清掉本次 gallery-dl 失敗／中止留下的 .part。保守規則（同 mdl.py）：只看輸出資料夾這一層、
# 執行前不存在、執行期間才寫入、而且檔名含這則貼文的 ID（拿不到 ID 就完全不清）。
function Remove-ImagePartials($img) {
    $removed = 0
    if (-not $img -or -not $img.Token) { return 0 }
    try {
        foreach ($f in (Get-ChildItem -LiteralPath $img.OutDir -Filter '*.part' -File -Force -ErrorAction Stop)) {
            if ($img.PartsBefore.ContainsKey($f.Name)) { continue }
            if (-not $f.Name.Contains($img.Token)) { continue }
            if ($f.LastWriteTime -lt $img.RunStarted.AddSeconds(-2)) { continue }
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed++ } catch { }
        }
    } catch { }
    return $removed
}

function Get-GdlCookieIssue([string]$text) {
    foreach ($ln in ($text -split "`r`n|`n")) {
        if ($ln.Trim() -match '\[(?:warning|error)\]\s*cookies:\s*(.+)$') {
            $m = $Matches[1].Trim()
            if ($m.Length -gt 300) { $m = $m.Substring(0, 300) }
            return $m
        }
    }
    return $null
}

function Get-GdlCompactError([string]$err, [int]$rc) {
    $rows = @($err -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $errors = @($rows | Where-Object { $_.ToLowerInvariant().Contains('][error]') })
    if ($errors.Count -eq 0) { $errors = @($rows | Where-Object { $_.ToLowerInvariant().Contains('][warning]') }) }
    if ($errors.Count -eq 0) { return "gallery-dl 執行失敗（結束代碼 $rc），但沒有輸出錯誤訊息。" }
    $msg = [string]$errors[-1]
    $msg = [regex]::Replace($msg, '\.?\s*Please run gallery-dl again with the --verbose flag.*$', '', 'IgnoreCase')
    $msg = [regex]::Replace($msg, '\s+', ' ').Trim()
    if ($msg.Length -gt 500) { $msg = $msg.Substring(0, 500) }
    return $msg
}

# yt-dlp 的錯誤摘要：最後一行 ERROR:，沒有就最後一行
function Get-YtCompactError([string]$err) {
    $rows = @($err -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($rows.Count -eq 0) { return 'yt-dlp 沒有輸出錯誤訊息。' }
    $e = @($rows | Where-Object { $_ -match '^ERROR:' })
    $msg = if ($e.Count) { [string]$e[-1] } else { [string]$rows[-1] }
    $msg = [regex]::Replace(($msg -replace '^ERROR:\s*', ''), '\s+', ' ').Trim()
    if ($msg.Length -gt 500) { $msg = $msg.Substring(0, 500) }
    return $msg
}

$script:CookieDbRe = '(?i)could not copy .{0,40}cookie|cookies? database|failed to (decrypt|read) .{0,40}cookie|could not decrypt.{0,40}cookie|failed to decrypt with dpapi|failed to load cookies|cannot extract cookies from'
$script:PhotoOnlyRe = '(?i)there is no video in this post|no video could be found in this tweet'

function Test-PhotoOnlyError([string]$t) {
    if (-not $t) { return $false }
    if ($t -match $script:PhotoOnlyRe) { return $true }
    if ($t -match '(?i)no video formats found' -and $t -match '(?i)\[(instagram|twitter|facebook)[^\]]*\]') { return $true }
    return $false
}

# 「重試必然再失敗」的情況回傳說明（同 mdl.py _skip_retry_reason）：cookie 讀不到、貼文只有照片
function Get-SkipRetryReason([string]$t) {
    if (-not $t) { return $null }
    if ($t -match $script:CookieDbRe) { return 'cookie 來源本身就讀不到（失敗發生在連網之前），--impersonate 重試必然同樣失敗，已略過重試。' }
    if (Test-PhotoOnlyError $t) { return '這則貼文（或其中幾格）只有照片、沒有影片，--impersonate 重試也不會有影片，已略過重試。' }
    return $null
}

function Test-ImpersonateUnsupported([string]$t) {
    $low = ([string]$t).ToLowerInvariant()
    if (-not $low.Contains('impersonate')) { return $false }
    foreach ($p in @('no such option', 'unrecognized argument', 'unsupported impersonate target', 'impersonate target',
                     'not available', 'not supported', 'curl_cffi', 'invalid')) { if ($low.Contains($p)) { return $true } }
    return $false
}

# 圖片模式失敗時的建議（對照 mdl.py build_image_hint，改成 GUI 的操作用語）
function Get-ImageHint([string]$err, [string]$out, [bool]$hasCookies, [string]$url, [string]$cookieIssue) {
    $blob = "$err`n$out"
    $low = $blob.ToLowerInvariant()
    $site = Get-ImgSite $url
    $loginTip = '請按「開啟登入瀏覽器」登入該網站，再勾選「使用登入瀏覽器的 cookie」後重試'
    if ($cookieIssue) {
        return "cookie 沒有載入成功（$cookieIssue），所以本次其實是「未登入」：建議改用登入瀏覽器——$loginTip。"
    }
    if ($blob -match $script:CookieDbRe) {
        return '無法讀取瀏覽器的 Cookie（瀏覽器開著時會鎖住資料庫）：建議取消「用瀏覽器 Cookie」，改用登入瀏覽器——' + $loginTip + '（不必關閉你平常用的 Chrome）。'
    }
    if ($low.Contains('unsupported url')) {
        if ($url -notmatch '^https?://') { return '網址格式不正確：請貼完整的貼文網址（以 https:// 開頭）。' }
        $h = Get-UrlHost $url
        if (Test-HostIn $h $script:VideoSiteHosts) { return '這是影片網站的網址，圖片模式（gallery-dl）不處理：請改選「MP4 影片」或「MP3 音樂」。' }
        return 'gallery-dl 不支援這個網站或這種網址格式：請貼「單篇貼文」的網址——IG：instagram.com/p/<代碼>/；X：x.com/<帳號>/status/<數字>；FB：facebook.com/photo/?fbid=<數字> 或 facebook.com/<粉專>/posts/<ID>。要影片請改選「MP4 影片」。'
    }
    foreach ($k in @('unable to open for writing', 'no such file or directory', 'filename too long', 'file name too long',
                     'path too long', 'errno 2', 'errno 36', 'errno 28', 'no space left', 'winerror 206', 'winerror 183', 'winerror 3]')) {
        if ($low.Contains($k)) { return '輸出路徑可能過長（Windows 上限 260 字元）或磁碟空間不足：請改用較短的輸出資料夾（例如 D:\dl），或清出磁碟空間。' }
    }
    $rate = $low.Contains('429') -or $low.Contains('too many requests') -or $low.Contains('rate limit') -or $low.Contains('rate-limit')
    $wall = $low.Contains('empty media response')
    foreach ($k in $script:GdlLoginKeys) { if ($low.Contains($k)) { $wall = $true; break } }
    if ($site -eq 'instagram' -and ($wall -or $rate)) {
        $head = 'Instagram 不給這個連線看這則貼文（gallery-dl 與 yt-dlp 備援都失敗）。IG 對「需要登入」「貼文不存在／已刪除」「被限流」回的是同一種反應，原因可能是：私人帳號、限制級／地區限制內容、網址打錯或貼文已刪除，或短時間內抓太多被限流。'
        if ($hasCookies) { return $head + '本次已經帶了 cookie：請在登入瀏覽器實際打開這個網址確認看得到；看得到的話多半是登入過期，重新登入後再試，或等 10～30 分鐘。' }
        return $head + '請先在瀏覽器打開這個網址確認；若必須登入才看得到，' + $loginTip + '；若是被限流，等 10～30 分鐘再試。'
    }
    if ($rate) {
        if ($hasCookies) { return '被網站限流（HTTP 429）：請等 10～30 分鐘再試（已帶 cookie，換參數沒有用）。' }
        return '被網站限流（HTTP 429）：請等 10～30 分鐘再試，或使用登入瀏覽器的 cookie 以登入狀態下載。'
    }
    if ($wall) {
        if ($hasCookies) { return '本次已經帶了 cookie 卻仍被要求登入：登入可能已過期，或該帳號無權觀看這則貼文。請在登入瀏覽器實際打開這個網址確認看得到，必要時重新登入。' }
        return "這則貼文需要登入才能看：$loginTip。"
    }
    if ($site -eq 'twitter' -and ($low.Contains("keyerror - 'result'") -or $low.Contains("'unavailable'") -or $low.Contains('tweet unavailable') -or $low.Contains('nsfw'))) {
        if ($hasCookies) { return '推文不存在、已刪除，或這個帳號看不到（例如受保護帳號）：請確認網址能在瀏覽器打開。' }
        return "推文不存在、已刪除，或屬於受保護帳號／敏感內容而需要登入：請先確認網址在瀏覽器打得開；若要登入才看得到，$loginTip。"
    }
    if ($low.Contains('404') -or $low.Contains('not found') -or $low.Contains('notfounderror') -or $low.Contains('does not exist')) {
        return '網址無效、貼文已刪除或設為不公開：請確認網址是否正確、能不能在瀏覽器開啟。'
    }
    if ($low.Contains('403') -or $low.Contains('forbidden')) {
        if ($hasCookies) { return '被網站拒絕（HTTP 403）：請稍後再試；已帶 cookie 的話多半是登入過期，請在登入瀏覽器重新登入。' }
        return '被網站拒絕（HTTP 403）：請稍後再試，或使用登入瀏覽器的 cookie 以登入狀態下載。'
    }
    foreach ($k in @('timed out', 'timeout', 'connectionerror', 'connection aborted', 'connection reset', 'name resolution', 'getaddrinfo', 'ssl')) {
        if ($low.Contains($k)) { return '網路連線問題：請確認網路或代理設定後重試。' }
    }
    if ($low.Contains('unexpected error') -or $low.Contains('keyerror') -or $low.Contains('typeerror') -or $low.Contains('extractor')) {
        return 'gallery-dl 的抽取器可能已失效（網站改版）：請重跑「首次設定.bat」（或 mdl.bat update）更新 gallery-dl 再試。'
    }
    return '請確認網址是「單篇貼文」、能在瀏覽器打開；需要登入的內容請使用登入瀏覽器的 cookie。'
}

function Get-ExtFromUrl([string]$url, [string]$default = 'jpg') {
    $ext = ''
    try { $ext = [System.IO.Path]::GetExtension(([Uri]$url).AbsolutePath).TrimStart('.').ToLowerInvariant() } catch { }
    if ($ext -match '^[a-z0-9]{1,5}$') { return $ext }
    return $default
}

# 從 yt-dlp 的 thumbnails 挑原始尺寸那張：stp 參數沒有尺寸／裁切標記（_s1080x1080、_p640x640、
# c0.171.1440.1440a）的就是原圖，網址與 gallery-dl 登入後抓到的相同；yt-dlp 也把它排在最後。
function Get-BestIgImageUrl($entry) {
    $thumbs = @(@(Get-JVal $entry 'thumbnails') | Where-Object { $_ -is [System.Collections.IDictionary] -and (Get-JVal $_ 'url') })
    if ($thumbs.Count -eq 0) {
        $t = Get-JVal $entry 'thumbnail'
        if ($t) { return [string]$t }
        return $null
    }
    $orig = @($thumbs | Where-Object {
        $u = [string]$_['url']
        if ($u -cnotmatch '[?&]stp=([^&]+)') { $true }
        else { -not ([Uri]::UnescapeDataString($Matches[1]) -cmatch '(?:^|_)(?:[sp]\d+x\d+|c\d+\.\d+)') }
    })
    if ($orig.Count -gt 0) { return [string]$orig[-1]['url'] }
    return [string]$thumbs[-1]['url']
}

# ------------------------------------------------ 圖片：單筆開始（gallery-dl）
function Reset-JobStreams([string]$tag) {
    $job = $script:Job
    Close-Readers $job
    $job.ErrText = New-Object System.Text.StringBuilder
    $job.OutLeft = ''; $job.ErrLeft = ''
    $job.Percent = 0
    $job.SkipOut = $false
    $job.OutFile = New-TempFile ($tag + '_out')
    $job.ErrFile = New-TempFile ($tag + '_err')
}

# ============================================================ 圖片：整批下載（IG 帳號／珍藏）
# 對照 src\mdl.py 的 _ig_bulk_target / _bulk_sleep_cfg / _pace_args（images --all），兩邊行為要一致。
# instagram.com/<第一段> 不是帳號的那些路徑
$script:IgNotUser  = @('p', 'reel', 'reels', 'tv', 'explore', 'stories', 'accounts', 'direct', 'about',
                       'developer', 'legal', 'api', 'web', 'graphql', 'challenge', 'share', 's', 'ar')
$script:IgHandleRe = '^@?([A-Za-z0-9_.]{1,30})$'
$script:IgBulkRe   = '^https?://(?:www\.|m\.)?instagram\.com/([A-Za-z0-9_.]{1,30})(?:/(posts|reels|tagged|saved)(?:/([^/?#]+)(?:/([^/?#]+))?)?)?/?(?:[?#].*)?$'

# Windows 資料夾名稱不能有的字元換成底線、去頭尾空白、最長 80 字、結尾不能是空白或句點
function Get-SafeFolderName([string]$name) {
    $n = ([regex]::Replace($name, '[<>:"/\\|?*\x00-\x1f]', '_')).Trim()
    if ($n.Length -gt 80) { $n = $n.Substring(0, 80) }
    $n = $n.TrimEnd(' ', '.')
    if (-not $n) { $n = '_' }
    return $n
}

# 回傳 @{ Target = @{Url;Folder;Label} 或 $null; Error = 錯誤文字或 $null }；
# 不是 IG 帳號／珍藏網址時兩者都是 $null（照一般網址處理，只是不設檔案數上限）。
#   instagram.com/<帳號>/                     → 該帳號所有貼文       → 子資料夾 <帳號>
#   instagram.com/<帳號>/reels/、/tagged/     → Reels／被標註的貼文  → <帳號>、<帳號>_tagged
#   instagram.com/<自己>/saved/               → 自己的全部珍藏       → <自己>_saved
#   instagram.com/<自己>/saved/<分類>/<ID>/   → 某個珍藏分類         → <自己>_saved_<分類>
function Get-IgBulkTarget([string]$url) {
    $none = @{ Target = $null; Error = $null }
    $m = [regex]::Match([string]$url, $script:IgBulkRe, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success -or ($script:IgNotUser -contains $m.Groups[1].Value.ToLowerInvariant())) { return $none }
    $user = $m.Groups[1].Value
    $kind = 'posts'
    if ($m.Groups[2].Success) { $kind = $m.Groups[2].Value.ToLowerInvariant() }
    $name = ''; if ($m.Groups[3].Success) { $name = $m.Groups[3].Value }
    $cid  = ''; if ($m.Groups[4].Success) { $cid  = $m.Groups[4].Value }
    $base = "https://www.instagram.com/$user"
    if ($kind -ne 'saved') {
        $folder = $user; if ($kind -eq 'tagged') { $folder = "${user}_tagged" }
        $what = switch ($kind) { 'reels' { '所有 Reels' } 'tagged' { '被標註的貼文' } default { '所有貼文' } }
        return @{ Target = @{ Url = "$base/$kind/"; Folder = (Get-SafeFolderName $folder); Label = "@$user 的$what" }; Error = $null }
    }
    if (-not $name -or $name.ToLowerInvariant() -eq 'all-posts') {
        return @{ Target = @{ Url = "$base/saved/"; Folder = (Get-SafeFolderName "${user}_saved"); Label = "@$user 的全部珍藏" }; Error = $null }
    }
    if (-not $cid -or $cid -notmatch '^[0-9]+$') {
        return @{ Target = $null; Error = '珍藏分類的網址要包含分類的數字 ID，例如 https://www.instagram.com/<你的帳號>/saved/<分類名稱>/<一串數字>/。' }
    }
    $title = $name
    try { $title = [uri]::UnescapeDataString($name) } catch { }
    return @{ Target = @{ Url = "$base/saved/$name/$cid/"; Folder = (Get-SafeFolderName "${user}_saved_$title"); Label = "@$user 的珍藏分類「$title」" }; Error = $null }
}

# 每個檔案之間的等待秒數（config\profiles.json 的 bulk_sleep；缺少或壞值用預設 2.0 / 0.0 / 4.0）
function Get-BulkSleepCfg {
    # 注意：PowerShell 變數不分大小寫，區域變數不能叫 $cfg，否則會蓋掉全域的 $Cfg（profiles.json）
    $res = @{ mean = 2.0; min = 0.0; max = 4.0 }
    $user = $null
    try { if ($Cfg -and $null -ne $Cfg.PSObject.Properties['bulk_sleep']) { $user = $Cfg.bulk_sleep } } catch { }
    if ($user -is [System.Management.Automation.PSCustomObject]) {
        foreach ($k in @('mean', 'min', 'max')) {
            try {
                $p = $user.PSObject.Properties[$k]
                if ($null -eq $p -or $null -eq $p.Value) { continue }
                $res[$k] = [math]::Max(0.0, [System.Convert]::ToDouble($p.Value, [System.Globalization.CultureInfo]::InvariantCulture))
            } catch { }
        }
    }
    if (-not (($res.min -le $res.mean) -and ($res.mean -le $res.max))) { $res = @{ mean = 2.0; min = 0.0; max = 4.0 } }
    return $res
}

# 讓 gallery-dl 在「每個檔案下載完之後」隨機等待：常態分佈，平均 mean 秒，標準差 (max-min)/6，
# 超出 min～max 的夾回邊界。gallery-dl 內建的 --sleep 只有固定值或均勻分佈，所以改用 python 後處理器
# 在 after 事件（檔案下載完成）執行運算式；已存在而略過的檔案不會觸發，重跑時不會白等。
# 運算式刻意不含雙引號與 %：gallery-dl 是經由 cmd.exe 啟動的（ConvertTo-CmdArg）。
# 數字一律用 InvariantCulture，避免某些語系印成逗號小數點。
function Get-PaceArgs($sleepCfg) {
    if ($sleepCfg.max -le 0) { return @() }
    $ic = [System.Globalization.CultureInfo]::InvariantCulture
    $sigma = ($sleepCfg.max - $sleepCfg.min) / 6.0
    $sMax = $sleepCfg.max.ToString('F3', $ic); $sMin = $sleepCfg.min.ToString('F3', $ic)
    $sMean = $sleepCfg.mean.ToString('F3', $ic); $sSigma = $sigma.ToString('F3', $ic)
    $expr = "__import__('time').sleep(min($sMax,max($sMin,__import__('random').gauss($sMean,$sSigma))))"
    return @('-P', 'python', '-O', 'event=after', '-O', ('expression=' + $expr))
}

function Start-ImageItem {
    $job = $script:Job
    $url = [string]$job.CurrentUrl
    $n = $job.Index + 1
    $total = $job.Urls.Count
    # 影片模式的「貼文照片一併下載」也走這條流程（$job.Auto 有值）：只抓照片、訊息從簡，
    # 這一筆的成敗最後由 Complete-AutoItem 連同影片一起結算。
    $auto = $job.Auto
    if (-not $auto) { Write-Log "[$n/$total] 開始（圖片）：$url" }
    $img = @{
        ImagesOnly = [bool]$auto
        Url = $url; FetchUrl = $url; Warnings = (New-Object System.Collections.ArrayList)
        Files = (New-Object System.Collections.ArrayList); Engine = 'gallery-dl'; Meta = @{}; Rc = 0
        ErrorText = $null; HintErr = ''; HintOut = ''; OutText = (New-Object System.Text.StringBuilder)
        CookieIssue = $null; HasCookies = (Test-JobHasCookies); Fb = $null; Token = $null
        PartsBefore = @{}; RunStarted = (Get-Date); AfterFile = $null; SkipFile = $null; Shown = 0
    }
    $job.Img = $img

    # 整批下載（只限一般的圖片流程，不含影片模式的照片補抓）：只打帳號名稱（@natgeo）也收，補成帳號頁網址
    $bulk = [bool]($job.Bulk -and -not $auto)
    if ($bulk -and $url -match $script:IgHandleRe) {
        $url = 'https://www.instagram.com/' + $Matches[1] + '/'
        $img.Url = $url
    }

    if ($url -notmatch '^https?://') {
        if ($url -match '^(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+/\S*$') {
            $url = 'https://' + $url
            $img.Url = $url
            [void]$img.Warnings.Add('網址沒有 https://，已自動補上。')
        } else {
            $img.Rc = 1
            $img.ErrorText = "網址格式不正確：$url"
            $img.Hint = '請貼完整的貼文網址（以 https:// 開頭），例如 https://www.instagram.com/p/XXXXXXXXXXX/。'
            Complete-ImageItem
            return
        }
    }
    $fix = Resolve-ImageUrl $url
    $img.FetchUrl = $fix.Url
    foreach ($w in $fix.Notes) {
        # 補抓照片時「改寫網址」只是實作細節，不必提；「這張照片屬於一則多圖貼文」那種才留著
        if ($auto -and ([string]$w).StartsWith('已把 Facebook')) { continue }
        [void]$img.Warnings.Add($w)
        if (-not $auto) { Write-Raw ("          注意：" + $w) }
    }
    if ($img.ImagesOnly -and (Get-ImgSite $img.FetchUrl) -eq 'facebook' -and $img.FetchUrl -notmatch $script:FbSinglePostRe) {
        # 照片補抓是使用者沒有明講就自動跑的：不是單篇貼文／單張照片就完全不連線（同 mdl.py），
        # 絕不能因為網址長得像貼文就把整個粉專的相片牆抓下來。
        $img.Rc = 1
        if ($img.FetchUrl -match $script:FbSharePostRe) {
            $img.ErrorText = 'Facebook 的分享短網址（/share/p/…）yt-dlp 與 gallery-dl 都不認得，沒有補抓照片'
            $img.Hint = '請在瀏覽器打開這個連結，等它跳到貼文本身之後，複製網址列的網址再貼上來下載。'
        } else {
            $img.ErrorText = '這個 Facebook 網址不是單篇貼文或單張照片（可能是相片牆或相簿），不自動補抓照片'
            $img.Hint = '要抓整個相片牆或相簿請改選「圖片 (IG/FB/X)」模式（每則最多下載 ' + $ImgMaxFiles + ' 個檔案）。'
        }
        Complete-ImageItem
        return
    }

    # IG 帳號／珍藏的整批下載：改存到輸出資料夾底下以帳號／分類命名的子資料夾，並改抓正規化後的網址
    $bulkT = $null
    if ($bulk) {
        $bt = Get-IgBulkTarget $url
        if ($bt.Error) {
            $img.Rc = 1
            $img.ErrorText = $bt.Error
            $img.Hint = '請在登入瀏覽器打開那個珍藏分類，複製網址列的網址再貼上來（按「目前分頁」可以列出登入瀏覽器的分頁網址）。'
            Complete-ImageItem
            return
        }
        $bulkT = $bt.Target
        if ($bulkT -and -not (Test-JobHasCookies)) {
            # IG 不讓未登入者列舉帳號或珍藏，連線只會撞登入牆，直接說明比跑一輪失敗好
            $img.Rc = 1
            $img.ErrorText = "整批下載 $($bulkT.Label) 需要登入 Instagram（IG 不讓未登入者列舉帳號或珍藏）。"
            $img.Hint = '請先按「開啟登入瀏覽器」登入 IG，再勾選「使用登入瀏覽器的 cookie」後重新下載。'
            Complete-ImageItem
            return
        }
        if ($bulkT) { $img.FetchUrl = $bulkT.Url }
    }

    try {
        $outDir = [System.IO.Path]::GetFullPath($txtOut.Text.Trim()).TrimEnd('\')
        if ($outDir.Length -eq 2 -and $outDir.EndsWith(':')) { $outDir += '\' }
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
        if ($bulkT) {
            $outDir = Join-Path $outDir $bulkT.Folder
            if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
        }
    } catch {
        $img.Rc = 1
        $img.ErrorText = "無法建立輸出資料夾：$($_.Exception.Message)"
        $img.Hint = '請改選一個可寫入的輸出資料夾。'
        Complete-ImageItem
        return
    }
    $img.OutDir = $outDir
    if ($bulkT) {
        Write-Raw ("          整批下載：$($bulkT.Label) → $outDir（不設檔案數上限；每個檔案下載完隨機等待 0～4 秒，平均 2 秒；已下載過的會略過）")
    }
    $bud = Get-ImgNameBudget $outDir
    $img.Budget = $bud.Budget
    if ($bud.Warn) { [void]$img.Warnings.Add($bud.Warn); if (-not $auto) { Write-Raw ("          注意：" + $bud.Warn) } }
    $img.Token = Get-PostToken $img.FetchUrl
    $img.PartsBefore = Get-PartFileNames $outDir
    $img.RunStarted = Get-Date
    # 只抓照片 + IG 單篇貼文 + 沒有 cookie：gallery-dl 的 IG 單篇貼文介面未登入一定撞登入牆，
    # 直接走 yt-dlp 的公開介面，少打一次 IG（同 mdl.py；圖片模式維持原樣：先試 gallery-dl）。
    if ($img.ImagesOnly -and $img.FetchUrl -match $script:IgPostRe -and -not (Test-JobHasCookies)) {
        $img.SkipGdl = $true
        Set-BarStyle 'Marquee'
        Start-IgFallback
        return
    }
    $img.AfterFile = New-TempFile 'gdl_after'
    $img.SkipFile  = New-TempFile 'gdl_skip'

    $a = New-Object System.Collections.Generic.List[string]
    foreach ($x in @('--config-ignore', '--no-colors',
                     '-o', 'cache.file=null',
                     '-o', 'cookies-update=false',
                     '-o', 'output.stdout.encoding=utf-8',
                     '-o', 'output.stderr.encoding=utf-8',
                     '-o', 'extractor.twitter.ratelimit=abort',
                     '-o', 'path-extended=false',
                     '--http-timeout', '30', '-R', '4',
                     '-D', $outDir)) { $a.Add($x) }
    # 整批下載不設檔案數上限（--range 是防止誤貼帳號頁的保險）；其餘照舊每則最多 $ImgMaxFiles 個
    if (-not $bulk) { $a.Add('--range'); $a.Add("1-$ImgMaxFiles") }
    foreach ($x in (Get-ImgFilenameArgs $img.Budget)) { $a.Add($x) }
    foreach ($x in @('--Print-to-file', ('after:' + $script:GdlMetaFmt), $img.AfterFile,
                     '--Print-to-file', ('skip:' + $script:GdlMetaFmt), $img.SkipFile)) { $a.Add($x) }
    if ($bulk) {
        # 每個檔案下載完隨機等待（常態分佈，設定見 config\profiles.json 的 bulk_sleep）。
        # -O 只作用在「最近一個 -P」，所以 -P python 與它的 -O 必須連在一起、中間不能插別的參數。
        foreach ($x in @(Get-PaceArgs (Get-BulkSleepCfg))) { $a.Add([string]$x) }
    }
    if ($img.ImagesOnly) {
        # 只抓照片（參數與 mdl.py download_images(_images_only=True) 相同）：影片已經由 yt-dlp 下載過了。
        # IG / X 的影片網址與照片在同一個 API 回應裡，靠 --filter 在下載前濾掉（序號 {num} 不受影響，
        # 檔名與圖片模式相同）。不可以對 IG 加 extractor.instagram.videos=false：實測 gallery-dl 1.32.14
        # 的限時動態只要有影片就整個以 KeyError 'width' 失敗，連照片都拿不到。
        # FB 的影片要另外開影片頁才拿得到網址，直接在抽取器層級關掉省請求。
        foreach ($x in @('-o', 'extractor.facebook.videos=false',
                         '--filter', $script:GdlPhotoPassFilter)) { $a.Add($x) }
    }
    foreach ($x in (Get-JobCookieArgs)) { $a.Add($x) }
    $a.Add($img.FetchUrl)

    Reset-JobStreams 'gdl'
    $job.Phase = 'gdl'
    Set-BarStyle 'Marquee'
    if ($auto) { $lblStatus.Text = "第 $n/$total 筆 - 補抓貼文照片…" }
    else { $lblStatus.Text = "第 $n/$total 筆 - 下載貼文媒體中（gallery-dl）…" }
    try {
        $job.Proc = Start-Redirected $GalleryDlExe $a.ToArray() $job.OutFile $job.ErrFile
    } catch {
        $job.Proc = $null
        $img.Rc = 1
        $img.ErrorText = "無法啟動 gallery-dl：$($_.Exception.Message)"
        $img.Hint = '請重跑「首次設定.bat」重新下載 bin\gallery-dl.exe。'
        Remove-Quiet $img.AfterFile; Remove-Quiet $img.SkipFile
        Complete-ImageItem
    }
}

# gallery-dl 的 stdout：下載完成的檔案印路徑，已存在而略過的印 "# 路徑"；stderr 是 [站台][等級] 訊息
function Invoke-GdlLine([string]$line, [bool]$isErr) {
    $job = $script:Job
    $img = $job.Img
    $line = $script:AnsiRegex.Replace([string]$line, '').TrimEnd()
    if ($line -eq '') { return }
    if ($isErr) {
        [void]$job.ErrText.AppendLine($line)
        if ($line -match '\]\[debug\]') { return }
        # 補抓照片時 gallery-dl 的訊息（登入牆、沒有結果…）不顯示：需要時由結算訊息統一說明
        if ($img.ImagesOnly) { return }
        Write-Raw ("          " + $line)
        return
    }
    [void]$img.OutText.AppendLine($line)
    if ($line.StartsWith('# ')) {
        Write-Raw ("          （已存在）" + $line.Substring(2).Trim())
    } else {
        $img.Shown++
        Write-Raw ("          -> " + $line)
        $n = $job.Index + 1
        if ($img.ImagesOnly) { $lblStatus.Text = "第 $n/$($job.Urls.Count) 筆 - 補抓貼文照片…已下載 $($img.Shown) 張" }
        else { $lblStatus.Text = "第 $n/$($job.Urls.Count) 筆 - 已下載 $($img.Shown) 個檔案（gallery-dl）…" }
    }
}

function Complete-GdlPhase([int]$code) {
    $job = $script:Job
    $img = $job.Img
    $err = $job.ErrText.ToString()
    $out = $img.OutText.ToString()
    $rows = New-Object System.Collections.ArrayList
    foreach ($r in (Read-GdlMeta $img.AfterFile $true)) { [void]$rows.Add($r) }
    foreach ($r in (Read-GdlMeta $img.SkipFile $false)) { [void]$rows.Add($r) }
    Remove-Quiet $img.AfterFile; Remove-Quiet $img.SkipFile
    Remove-Quiet $job.OutFile; Remove-Quiet $job.ErrFile
    $img.Rc = $code

    $img.CookieIssue = Get-GdlCookieIssue $err
    if ($img.CookieIssue) { [void]$img.Warnings.Add("cookie 沒有載入成功，本次等於「未登入」：$($img.CookieIssue)") }
    $img.HasCookies = (Test-JobHasCookies) -and (-not $img.CookieIssue)

    $cands = New-Object System.Collections.ArrayList
    foreach ($r in $rows) { if ($r.Path) { [void]$cands.Add(@{ P = $r.Path; D = $r.Downloaded }) } }
    foreach ($ln in ($out -split "`r`n|`n")) {
        $s = $ln.Trim()
        $skipped = $s.StartsWith('# ')
        if ($skipped) { $s = $s.Substring(2).Trim() }
        if (-not $s -or -not [System.IO.Path]::IsPathRooted($s)) { continue }
        if ($s.StartsWith($img.OutDir.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$cands.Add(@{ P = $s; D = (-not $skipped) })
        }
    }
    $col = Get-CollectedMedia $cands $img.OutDir
    $img.Files = $col.Files
    foreach ($w in $col.Warnings) { [void]$img.Warnings.Add($w) }
    $first = $null
    foreach ($r in $rows) { if ($r.Path) { $first = $r; break } }
    if ($first) {
        $pid_ = if ($first.Subcategory -eq 'set') { $first.SetId } else { $first.PostId }
        $img.Meta = @{ Site = $first.Site; Uploader = $first.Uploader; PostId = $pid_; Description = $first.Description; Subcategory = $first.Subcategory }
    }
    $img.HintErr = $err
    $img.HintOut = $out
    $img.ErrorText = $null
    if ($code -ne 0) { $img.ErrorText = Get-GdlCompactError $err $code }

    if ($job.Stopping) { Complete-ImageStopped; return }

    # IG 單篇貼文被登入牆擋住 → yt-dlp 備援
    $lowAll = ($err + "`n" + $out).ToLowerInvariant()
    $wall = $false
    foreach ($k in $script:GdlLoginKeys) { if ($lowAll.Contains($k)) { $wall = $true; break } }
    if ($img.Files.Count -eq 0 -and $img.FetchUrl -match $script:IgPostRe -and $wall) {
        if (-not $img.ImagesOnly) { Write-Log '          gallery-dl 的 IG 單篇貼文介面需要登入，改用 yt-dlp 的公開介面…' }
        Start-IgFallback
        return
    }
    Complete-ImageItem
}

# ------------------------------------------------ 圖片：IG 備援（yt-dlp -J → 照片直接下載、影片交給 yt-dlp）
function Start-IgFallback {
    $job = $script:Job
    $img = $job.Img
    $img.Fb = @{
        Candidates = (New-Object System.Collections.ArrayList); Attempts = 0
        Warnings = (New-Object System.Collections.ArrayList); Error = $null; Stderr = ''; Meta = @{}
        Queue = (New-Object System.Collections.ArrayList); QueueTotal = 0; VideoItems = @()
        IsPlaylist = $false; Headers = @{}; First = $null; VideoRetried = $false; VideoFirstErr = $null
        JsonOk = $false; PhotoEntries = 0; SkippedVideos = 0
    }
    if (-not (Test-Path -LiteralPath $YtDlpExe)) {
        $img.Fb.Error = '找不到 yt-dlp，無法改用備援。'
        Complete-IgFallback
        return
    }
    Start-YtJson $false
}

function Start-YtJson([bool]$impersonate) {
    $job = $script:Job
    $fb = $job.Img.Fb
    $a = New-Object System.Collections.Generic.List[string]
    foreach ($x in (Get-CfgArray $Cfg.common)) { $a.Add([string]$x) }
    # yt-dlp 輸出被重新導向到檔案時會用系統編碼（cp950）寫出，中文路徑／標題在日誌裡變亂碼；強制 UTF-8
    $a.Add('--encoding'); $a.Add('utf-8')
    foreach ($x in @('-J', '--ignore-no-formats-error', '--yes-playlist')) { $a.Add($x) }
    foreach ($x in (Get-JobCookieArgs)) { $a.Add($x) }
    if ($impersonate) { $a.Add('--impersonate'); $a.Add('chrome') }
    $a.Add('--'); $a.Add([string]$job.Img.FetchUrl)
    Reset-JobStreams 'ytj'
    $job.SkipOut = $true      # stdout 是整份 JSON，不逐行顯示，結束後整份讀取
    $job.Phase = 'ytj'
    $fb.Attempts++
    $n = $job.Index + 1
    if ($job.Img.ImagesOnly) { $lblStatus.Text = "第 $n/$($job.Urls.Count) 筆 - 補抓貼文照片…（讀取貼文資訊）" }
    else { $lblStatus.Text = "第 $n/$($job.Urls.Count) 筆 - 讀取 IG 貼文資訊（yt-dlp）…" }
    try {
        $job.Proc = Start-Redirected $YtDlpExe $a.ToArray() $job.OutFile $job.ErrFile
    } catch {
        $job.Proc = $null
        $fb.Error = "無法啟動 yt-dlp：$($_.Exception.Message)"
        Complete-IgFallback
    }
}

function Invoke-YtjLine([string]$line, [bool]$isErr) {
    $job = $script:Job
    $line = $script:AnsiRegex.Replace([string]$line, '').TrimEnd()
    if ($line -eq '') { return }
    if ($isErr) {
        [void]$job.ErrText.AppendLine($line)
        if ($line -match '^(ERROR|WARNING)' -and -not $job.Img.ImagesOnly) { Write-Raw ("          " + $line) }
    }
}

function Complete-YtjPhase([int]$code) {
    $job = $script:Job
    $img = $job.Img
    $fb = $img.Fb
    $out = ''
    try { if (Test-Path -LiteralPath $job.OutFile) { $out = [System.IO.File]::ReadAllText($job.OutFile, [System.Text.Encoding]::UTF8) } } catch { }
    $err = $job.ErrText.ToString()
    Remove-Quiet $job.OutFile; Remove-Quiet $job.ErrFile
    $job.SkipOut = $false
    if ($job.Stopping) { Complete-ImageStopped; return }

    $rc = $code
    if ($fb.Attempts -eq 1) {
        if (($code -ne 0 -or -not $out.Trim()) -and -not (Get-SkipRetryReason ($err + "`n" + $out))) {
            $fb.First = @{ Code = $code; Out = $out; Err = $err }
            if (-not $img.ImagesOnly) { Write-Log '          yt-dlp 讀取失敗，改用 --impersonate chrome 重試…' }
            Start-YtJson $true
            return
        }
    } else {
        $first = $fb.First
        if ($code -eq 0 -and $out.Trim()) {
            # 重試成功
        } else {
            $rc = $first.Code
            $firstOut = $first.Out
            if (-not (Test-ImpersonateUnsupported $err)) { if (-not $err) { $err = $first.Err } } else { $err = $first.Err }
            $out = $firstOut
        }
    }
    $fb.Stderr = $err
    if ($rc -ne 0 -or -not $out.Trim()) {
        $fb.Error = Get-YtCompactError $err
        Complete-IgFallback
        return
    }
    try {
        $data = $script:Jss.DeserializeObject($out.Trim().TrimStart([char]0xFEFF))
    } catch {
        $fb.Error = "無法解析 yt-dlp 的 JSON 輸出：$($_.Exception.Message)"
        Complete-IgFallback
        return
    }

    $fb.JsonOk = $true
    $fb.IsPlaylist = ((Get-JVal $data '_type') -eq 'playlist')
    $entries = @()
    if ($fb.IsPlaylist) { $entries = @(@(Get-JVal $data 'entries') | Where-Object { $_ -is [System.Collections.IDictionary] }) }
    else { $entries = @($data) }
    $shortcode = Get-JVal $data 'id'
    if (-not $shortcode -and $img.FetchUrl -match $script:IgPostRe) { $shortcode = $Matches[1] }
    if (-not $shortcode) { $shortcode = 'post' }
    $user = Get-JVal $data 'channel'
    if (-not $user) { $user = Get-JVal $data 'uploader_id' }
    if (-not $user) { foreach ($e in $entries) { $c = Get-JVal $e 'channel'; if ($c) { $user = $c; break } } }
    if (-not $user) { $user = 'instagram' }
    $userS = ConvertTo-SafeComponent $user ([math]::Max(8, [math]::Min(40, $img.Budget - 35)))
    $codeS = ConvertTo-SafeComponent $shortcode 40
    $fb.UserS = $userS; $fb.CodeS = $codeS
    $fb.Meta = @{ Site = 'instagram'; Uploader = [string]$user; PostId = [string]$shortcode; Description = (Get-JVal $data 'description') }

    $headers = [ordered]@{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36' }
    $hh = Get-JVal $data 'http_headers'
    if ($hh -is [System.Collections.IDictionary]) { foreach ($k in $hh.Keys) { $headers[[string]$k] = [string]$hh[$k] } }
    $fb.Headers = $headers

    $videoItems = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($entry in $entries) {
        $n++
        if ($n -gt $ImgMaxFiles) {
            [void]$fb.Warnings.Add("已達上限 $ImgMaxFiles 個檔案，其餘 $($entries.Count - $ImgMaxFiles) 格未下載。")
            break
        }
        $fmts = @(Get-JVal $entry 'formats' | Where-Object { $_ })
        if ($fmts.Count -gt 0) {
            # 只抓照片（影片模式的補抓）：有影片格式的那幾格 yt-dlp 已經下載過，直接略過；序號照算
            if ($img.ImagesOnly) { $fb.SkippedVideos++; continue }
            $done = $null
            foreach ($ext in @('mp4', 'webm', 'mkv')) {
                $p = Join-Path $img.OutDir ("{0}_{1}_{2}.{3}" -f $userS, $codeS, $n, $ext)
                if ((Test-Path -LiteralPath $p -PathType Leaf) -and (Get-Item -LiteralPath $p -Force).Length -gt 0) { $done = $p; break }
            }
            if ($done) { [void]$fb.Candidates.Add(@{ P = $done; D = $false }); Write-Raw ("          （已存在）" + $done) }
            else { [void]$videoItems.Add($n) }
            continue
        }
        $fb.PhotoEntries++
        $imgUrl = Get-BestIgImageUrl $entry
        if (-not $imgUrl) { [void]$fb.Warnings.Add("第 $n 格找不到圖片網址，已略過。"); continue }
        $dest = Join-Path $img.OutDir ("{0}_{1}_{2}.{3}" -f $userS, $codeS, $n, (Get-ExtFromUrl $imgUrl))
        if ((Test-Path -LiteralPath $dest -PathType Leaf) -and (Get-Item -LiteralPath $dest -Force).Length -gt 0) {
            [void]$fb.Candidates.Add(@{ P = $dest; D = $false })
            Write-Raw ("          （已存在）" + $dest)
            continue
        }
        [void]$fb.Queue.Add(@{ N = $n; Url = $imgUrl; Dest = $dest })
    }
    $fb.VideoItems = @($videoItems)
    $fb.QueueTotal = $fb.Queue.Count
    $fb.QueueDone = 0
    Start-NextHttp
}

# 照片逐一下載：WebClient 的非同步 Task，由 Timer 輪詢 IsCompleted（UI 不凍結、不需外部程式）。
# 先寫 .part，完成才改名；4xx（429 除外）不重試，其餘最多 3 次（同 mdl.py _http_download）。
function Start-NextHttp {
    $job = $script:Job
    $fb = $job.Img.Fb
    $job.Http = $null
    if ($job.Stopping) { Complete-ImageStopped; return }
    if ($fb.Queue.Count -eq 0) { Start-FbVideos; return }
    $item = $fb.Queue[0]
    $fb.Queue.RemoveAt(0)
    Write-Raw ("          下載第 {0} 格照片 -> {1}" -f $item.N, [System.IO.Path]::GetFileName($item.Dest))
    Start-HttpAttempt $item 1
}

function Start-HttpAttempt($item, [int]$attempt) {
    $job = $script:Job
    $fb = $job.Img.Fb
    $job.Phase = 'http'
    $part = $item.Dest + '.part'
    Remove-Quiet $part
    $wc = New-Object System.Net.WebClient
    foreach ($k in $fb.Headers.Keys) { try { $wc.Headers.Set([string]$k, [string]$fb.Headers[$k]) } catch { } }
    $task = $null
    $startErr = $null
    try { $task = $wc.DownloadFileTaskAsync([Uri]$item.Url, $part) } catch { $startErr = $_.Exception.Message }
    $job.Http = @{ Item = $item; Attempt = $attempt; Wc = $wc; Task = $task; Part = $part; Started = (Get-Date); RetryAt = $null; StartErr = $startErr }
    $n = $job.Index + 1
    if ($job.Img.ImagesOnly) { $lblStatus.Text = "第 $n/$($job.Urls.Count) 筆 - 補抓貼文照片 $($fb.QueueDone + 1)/$($fb.QueueTotal)…" }
    else { $lblStatus.Text = "第 $n/$($job.Urls.Count) 筆 - 下載照片 $($fb.QueueDone + 1)/$($fb.QueueTotal)（yt-dlp 備援）…" }
    Set-BarStyle 'Continuous'
    try { $bar.Value = [int][math]::Min(100, [math]::Round(100.0 * $fb.QueueDone / [math]::Max(1, $fb.QueueTotal))) } catch { }
}

function Update-HttpDownload {
    $job = $script:Job
    $h = $job.Http
    if (-not $h) { return }
    $fb = $job.Img.Fb
    if ($h.RetryAt) {
        if ($job.Stopping) { $job.Http = $null; Complete-ImageStopped; return }
        if ((Get-Date) -ge $h.RetryAt) { Start-HttpAttempt $h.Item ($h.Attempt + 1) }
        return
    }
    if ($h.Task -and -not $h.Task.IsCompleted) {
        # 逾時（120 秒）或使用者按停止 → 取消，下一輪 Tick 會看到 Canceled
        if ($job.Stopping -or ((Get-Date) - $h.Started).TotalSeconds -gt 120) { try { $h.Wc.CancelAsync() } catch { } }
        return
    }
    try { $h.Wc.Dispose() } catch { }
    $item = $h.Item
    if ($h.Task -and $h.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
        try {
            if (Test-Path -LiteralPath $item.Dest) { Remove-Item -LiteralPath $item.Dest -Force }
            Move-Item -LiteralPath $h.Part -Destination $item.Dest -Force
            [void]$fb.Candidates.Add(@{ P = $item.Dest; D = $true })
        } catch {
            [void]$fb.Warnings.Add("第 $($item.N) 格照片存檔失敗：$($_.Exception.Message)")
            Remove-Quiet $h.Part
        }
        $fb.QueueDone++
        Start-NextHttp
        return
    }
    Remove-Quiet $h.Part
    if ($job.Stopping) { $job.Http = $null; Complete-ImageStopped; return }
    $msg = $h.StartErr
    $status = 0
    if (-not $msg) {
        if ($h.Task.Status -eq [System.Threading.Tasks.TaskStatus]::Canceled) { $msg = '逾時（120 秒）' }
        else {
            $ex = $h.Task.Exception
            if ($ex -and $ex.InnerException) { $ex = $ex.InnerException }
            $msg = if ($ex) { $ex.GetType().Name + ': ' + $ex.Message } else { '未知錯誤' }
            try { if ($ex.Response) { $status = [int]$ex.Response.StatusCode } } catch { }
        }
    }
    $noRetry = ($status -ge 400 -and $status -lt 500 -and $status -ne 429)
    if (-not $noRetry -and $h.Attempt -lt 3) {
        $h.RetryAt = (Get-Date).AddSeconds($h.Attempt)
        $h.Task = $null
        return
    }
    [void]$fb.Warnings.Add("第 $($item.N) 格照片下載失敗：$msg")
    if (-not $job.Img.ImagesOnly) { Write-Raw ("          第 $($item.N) 格照片下載失敗：$msg") }
    $fb.QueueDone++
    Start-NextHttp
}

# 輪播裡的影片那幾格：沿用 MP4 影片（best）的格式與合併設定，檔名 <帳號>_<代碼>_<序號>.<副檔名>
function Start-FbVideos([bool]$impersonate = $false) {
    $job = $script:Job
    $img = $job.Img
    $fb = $img.Fb
    if (@($fb.VideoItems).Count -eq 0) { Complete-IgFallback; return }
    $a = New-Object System.Collections.Generic.List[string]
    foreach ($x in (Get-CfgArray $Cfg.common)) { $a.Add([string]$x) }
    # yt-dlp 輸出被重新導向到檔案時會用系統編碼（cp950）寫出，中文路徑／標題在日誌裡變亂碼；強制 UTF-8
    $a.Add('--encoding'); $a.Add('utf-8')
    $a.Add('--progress')
    if (Test-Path -LiteralPath $FFmpegExe) { $a.Add('--ffmpeg-location'); $a.Add($BinDir) }
    # Windows 260 字元：--trim-filenames 是對整條路徑截斷（同 mdl.py _path_budget_args）
    $prefix = $img.OutDir.TrimEnd('\').Length + 1
    $vb = 260 - 50 - $prefix
    if ($vb -lt 40) { $vb = 40 }
    $a.Add('--trim-filenames'); $a.Add([string]($prefix + $vb))
    if ($fb.IsPlaylist) { $a.Add('--yes-playlist') } else { $a.Add('--no-playlist') }
    $a.Add('-o'); $a.Add((Join-Path $img.OutDir ($fb.UserS + '_' + $fb.CodeS + '_%(playlist_index|1)d.%(ext)s')))
    $fmt = [string]$Cfg.video.format_best
    if (-not $fmt) { $fmt = 'bv*+ba/b' }
    $a.Add('-f'); $a.Add($fmt)
    $sort = [string]$Cfg.video.sort
    if ($sort) { $a.Add('-S'); $a.Add($sort) }
    foreach ($x in (Get-CfgArray $Cfg.video.extra)) { $a.Add([string]$x) }
    foreach ($x in (Get-JobCookieArgs)) { $a.Add($x) }
    if ($fb.IsPlaylist) { $a.Add('--playlist-items'); $a.Add((@($fb.VideoItems) -join ',')) }
    $fb.PathFile = New-TempFile 'ytv_paths'
    $a.Add('--print-to-file'); $a.Add('after_move:filepath'); $a.Add($fb.PathFile)
    if ($impersonate) { $a.Add('--impersonate'); $a.Add('chrome') }
    $a.Add('--'); $a.Add([string]$img.FetchUrl)

    Reset-JobStreams 'ytv'
    $job.Phase = 'ytv'
    $job.StartedAt = Get-Date
    $n = $job.Index + 1
    $lblStatus.Text = "第 $n/$($job.Urls.Count) 筆 - 下載貼文裡的影片（yt-dlp）…"
    Write-Raw ("          下載第 " + (@($fb.VideoItems) -join '、') + " 格影片（yt-dlp）" + $(if ($impersonate) { '，--impersonate chrome 重試' } else { '' }))
    try {
        $job.Proc = Start-Redirected $YtDlpExe $a.ToArray() $job.OutFile $job.ErrFile
    } catch {
        $job.Proc = $null
        [void]$fb.Warnings.Add("影片那幾格無法下載：無法啟動 yt-dlp（$($_.Exception.Message)）")
        Remove-Quiet $fb.PathFile
        Complete-IgFallback
    }
}

function Complete-YtvPhase([int]$code) {
    $job = $script:Job
    $img = $job.Img
    $fb = $img.Fb
    $err = $job.ErrText.ToString()
    $reported = @()
    try { if (Test-Path -LiteralPath $fb.PathFile) { $reported = @(Get-Content -LiteralPath $fb.PathFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) } } catch { }
    Remove-Quiet $fb.PathFile; Remove-Quiet $job.OutFile; Remove-Quiet $job.ErrFile
    if ($job.Stopping) { Complete-ImageStopped; return }
    $got = @($reported | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($code -ne 0 -and $got.Count -lt @($fb.VideoItems).Count -and -not $fb.VideoRetried -and -not (Get-SkipRetryReason $err)) {
        $fb.VideoRetried = $true
        $fb.VideoFirstErr = $err
        foreach ($p in $got) { [void]$fb.Candidates.Add(@{ P = $p; D = $true }) }
        Start-FbVideos $true
        return
    }
    if ($fb.VideoRetried -and (Test-ImpersonateUnsupported $err) -and $fb.VideoFirstErr) { $err = $fb.VideoFirstErr }
    foreach ($p in $got) { [void]$fb.Candidates.Add(@{ P = $p; D = $true }) }
    $okCount = @($fb.Candidates | Where-Object { $_.D -and ([string]$_.P) -match '\.(mp4|webm|mkv|mov|m4v)$' } | ForEach-Object { ([string]$_.P).ToLowerInvariant() } | Select-Object -Unique).Count
    $want = @($fb.VideoItems).Count
    if ($okCount -lt $want) {
        [void]$fb.Warnings.Add("輪播中有 $($want - $okCount) 格影片下載失敗：$(Get-YtCompactError $err)")
        $fb.Stderr += "`n" + $err
    }
    Complete-IgFallback
}

function Complete-IgFallback {
    $job = $script:Job
    $img = $job.Img
    $fb = $img.Fb
    $job.Http = $null
    # 照片與影片分兩批下載，依檔名結尾的序號排回輪播順序
    $sorted = @($fb.Candidates | Sort-Object -Property @{ Expression = { if ([string]$_.P -match '_(\d+)\.[A-Za-z0-9]+$') { [int]$Matches[1] } else { 1000000 } } })
    $col = Get-CollectedMedia $sorted $img.OutDir
    if ($col.Files.Count -gt 0) {
        $img.Engine = 'yt-dlp'
        $why = if ($img.ErrorText) { $img.ErrorText } else { '登入牆' }
        if (-not $img.ImagesOnly) { [void]$img.Warnings.Add("gallery-dl 的 IG 單篇貼文介面需要登入（$why），已改用 yt-dlp 的公開介面抓取。") }
        $img.Files = $col.Files
        $img.Meta = $fb.Meta
        $img.Rc = 0
        $img.ErrorText = $null
    }
    foreach ($w in $fb.Warnings) { [void]$img.Warnings.Add($w) }
    foreach ($w in $col.Warnings) { [void]$img.Warnings.Add($w) }
    if ($col.Files.Count -eq 0) {
        $fbErr = $fb.Error
        if (-not $fbErr) { $fbErr = @($fb.Warnings | Where-Object { $_ -match '失敗' }) | Select-Object -First 1 }
        if (-not $fbErr) { $fbErr = 'yt-dlp 備援也沒有產出任何檔案。' }
        $fbErr = ([regex]::Split([string]$fbErr, '\s+(?:Check if this post|Otherwise, if)|;\s*please report', 'IgnoreCase')[0]).Trim()
        if ($fbErr.Length -gt 240) { $fbErr = $fbErr.Substring(0, 240) }
        if ($img.SkipGdl) {
            $img.ErrorText = [string]$fbErr       # 沒跑 gallery-dl（未登入的照片補抓直接走 yt-dlp）
        } else {
            $base = if ($img.ErrorText) { $img.ErrorText } else { 'gallery-dl 失敗' }
            $img.ErrorText = "$base；yt-dlp 備援：$fbErr"
        }
        $img.HintErr = $img.HintErr + "`n" + $fb.Stderr + "`n" + (@($fb.Warnings) -join "`n")
    }
    Complete-ImageItem
}

# ------------------------------------------------ 圖片：單筆結束
function Complete-ImageStopped {
    $job = $script:Job
    $img = $job.Img
    $job.Http = $null
    $removed = Remove-ImagePartials $img
    $n = $job.Index + 1
    if ($job.Auto) {
        # 影片模式補抓照片時按了停止：影片已經在磁碟上，這一筆仍算成功
        $videos = @($job.Auto.Videos.Values)
        if ($videos.Count -gt 0) {
            Write-Log "[$n/$($job.Urls.Count)] 已中止補抓照片（影片已下載完成）："
            foreach ($f in $videos) { Write-Raw ("          " + $f.Path) }
            $job.Success++
        } else {
            Write-Log "[$n/$($job.Urls.Count)] 已中止（補抓貼文照片時停止）"
        }
        $job.Auto = $null
    } else {
        Write-Log "[$n/$($job.Urls.Count)] 已中止"
    }
    if ($removed) { Write-Log "（已清除 $removed 個本次留下的 .part 暫存檔）" }
    if ($job.Bulk -and $img.OutDir) {
        Write-Log "整批下載已中止：本次已下載 $($img.Shown) 個檔案，留在 $($img.OutDir)；之後再貼同一個網址重新下載，已下載過的會略過，從中斷處接續。"
    }
    Finish-Job
}

function Complete-ImageItem {
    $job = $script:Job
    if ($job.Auto) { Complete-AutoItem; return }   # 影片模式的照片補抓：連同影片一起結算
    $img = $job.Img
    $job.Http = $null
    $job.Proc = $null
    Close-Readers $job
    $n = $job.Index + 1
    $total = $job.Urls.Count
    $files = @($img.Files)
    Set-BarStyle 'Continuous'

    if ($files.Count -gt 0) {
        $ci = 0; $cv = 0; $co = 0; $ce = 0
        foreach ($f in $files) {
            switch ($f.Kind) { 'image' { $ci++ } 'video' { $cv++ } default { $co++ } }
            if ($f.Existing) { $ce++ }
        }
        if ($img.Rc -ne 0 -and $img.ErrorText) { [void]$img.Warnings.Add("gallery-dl 回報有項目失敗（$($img.ErrorText)），其餘 $($files.Count) 個檔案已下載。") }
        if ($ce -eq $files.Count) { [void]$img.Warnings.Add("全部 $($files.Count) 個檔案先前已經下載過，這次沒有重新下載。") }
        elseif ($ce -gt 0) { [void]$img.Warnings.Add("其中 $ce 個檔案先前已經下載過，沿用既有檔案。") }
        if (-not $job.Bulk -and $files.Count -ge $ImgMaxFiles -and -not (@($img.Warnings) -match '上限')) {
            [void]$img.Warnings.Add("已達上限 $ImgMaxFiles 個檔案，可能還有更多檔案沒下載。")
        }
        if (-not $job.Bulk -and $img.Meta -and $img.Meta.Subcategory -and ($script:ListingSubcats -contains [string]$img.Meta.Subcategory)) {
            [void]$img.Warnings.Add("這個網址看起來是帳號頁／相簿清單（$($img.Meta.Subcategory)），不是單篇貼文；最多只下載前 $ImgMaxFiles 個檔案。")
        }
        $parts = @()
        if ($ci) { $parts += "圖片 $ci 張" }
        if ($cv) { $parts += "影片 $cv 支" }
        if ($co) { $parts += "其他 $co 個" }
        $who = ''
        if ($img.Meta -and $img.Meta.Uploader) { $who = "，@$($img.Meta.Uploader)" }
        Write-Log ("[$n/$total] 完成（{0}{1}）：{2}" -f $img.Engine, $who, ($parts -join '、'))
        if ($job.Bulk -and $files.Count -gt 30) {
            # 整批下載可能有上千個檔案：下載過程中已經逐個印過路徑，結算時不再重印一次
            Write-Raw ("          檔案在：" + $img.OutDir)
        } else {
            foreach ($f in $files) {
                $tag = switch ($f.Kind) { 'image' { '圖片' } 'video' { '影片' } default { '其他' } }
                if ($f.Existing) { $tag += '/已存在' }
                Write-Raw ("          [{0}] {1}  ({2})" -f $tag, $f.Path, (Format-Size $f.Size))
            }
        }
        foreach ($w in $img.Warnings) { Write-Log "注意：$w" }
        $job.Success++
    } else {
        $removed = Remove-ImagePartials $img
        if ($removed) { [void]$img.Warnings.Add("已清除 $removed 個本次留下的 .part 暫存檔。") }
        if ($img.Hint) {
            $msg = $img.ErrorText; $hint = $img.Hint
        } elseif ($img.Rc -eq 0 -and -not $img.ErrorText) {
            $msg = '這個網址沒有可下載的照片或影片（gallery-dl 執行成功，但沒有產出任何檔案）。'
            $hint = '可能是純文字貼文，或網址指向的不是貼文本身；請確認網址，要影片請改選「MP4 影片」。'
        } else {
            $msg = $img.ErrorText
            if (-not $msg) { $msg = Get-GdlCompactError $img.HintErr $img.Rc }
            $hint = Get-ImageHint $img.HintErr $img.HintOut ([bool]$img.HasCookies) $img.FetchUrl $img.CookieIssue
        }
        Write-Log "[$n/$total] 失敗：$msg"
        foreach ($w in $img.Warnings) { Write-Log "注意：$w" }
        if ($hint) { Write-Log "建議：$hint" }
        $job.Fail++
    }
    $job.Img = $null
    $job.Phase = $null
    $job.Index++
    Start-NextOrFinish
}

# ============================================================ 影片模式：貼文照片一併下載
# 「MP4 影片」模式貼 IG / FB / X 的「貼文」網址時：影片照舊交給 yt-dlp（畫質選項不變），結束後接著跑
# 上面的圖片流程，但只抓照片（影片 yt-dlp 已經抓過，不重複下載）。規則對照 src\mdl.py 的
# _photo_pass_site / _photo_post_kind / _merge_photo_pass，兩邊行為要一致。
# 這一筆的成敗以磁碟為準：影片或照片只要有一個檔案就算成功；照片階段不論結果如何，
# 都不會把已經成功的影片變成失敗。
#   * 適用網址（Get-AutoPhotoSite）：
#       IG  /p/<代碼>；/stories/…（限時動態只有帶 cookie 時才補抓）
#       X   /<帳號>/status/<ID>
#       FB  貼文／照片：/posts/、/permalink、story.php、/photo、/photos/、/share/p/
#     不適用：IG /reel/ /reels/ /tv/；FB /videos/ /watch /reel/ /share/v/ /share/r/、fb.watch；
#     以及其他所有網站（YouTube…）——這些網址的流程與沒有這個功能時完全相同，也不會啟動 gallery-dl。
#   * 只抓照片的做法：gallery-dl 加 --filter（副檔名是影片的在下載前就略過；帳號頁／相片牆類的
#     抽取器直接 abort()）；IG 未登入時不跑 gallery-dl（一定撞登入牆），直接用 yt-dlp -J 的公開介面，
#     並略過「有影片格式」的那幾格（Complete-YtjPhase）。
#   * 不補抓的情況（不多打網站）：影片失敗的原因是 cookie 來源讀不到；IG 未登入而且影片失敗的原因
#     不是「沒有影片」（照片與影片走 yt-dlp 同一個公開介面，它剛剛已經失敗）。
#   * FB 貼文第一次失敗是 404／Cannot parse data（純照片貼文實測就是這個反應）：先補抓照片，
#     有照片就不必再用 --impersonate 重試；沒有才照舊重試。
#   * 狀態：$job.Auto（每筆網址一份；$null = 這一筆不補抓，完全走舊流程）。
#     Start-CurrentItem 建立 → yt-dlp 結束時 Complete-CurrentItem 轉給 Complete-AutoVideoStep
#     → Start-ImageItem（$job.Img 有值的期間由圖片流程的各階段接手）→ Complete-AutoItem 結算。
$script:AutoIgPostRe    = '^(?:https?://)?(?:www\.|m\.)?instagram\.com/(?:[^/?#]+/)?p/[A-Za-z0-9_-]+'
$script:AutoIgStoryRe   = '^(?:https?://)?(?:www\.|m\.)?instagram\.com/stories/[^/?#]+'
$script:AutoXStatusRe   = '^(?:https?://)?(?:(?:www|mobile)\.)?(?:x|twitter|fxtwitter|vxtwitter)\.com/[^/?#]+/status(?:es)?/\d+'
# FB：先取出「路徑 + 查詢字串」，再比對下面兩條
$script:AutoFbRe        = '^(?:https?://)?(?:[a-z0-9-]+\.)?facebook\.com(/[^#]*)'
$script:AutoFbIncludeRe = '/(?:posts/|permalink(?:\.php|[/?]|$)|story\.php|photo(?:\.php)?(?:[/?]|$)|photos/|share/p/)'
$script:AutoFbExcludeRe = '/(?:videos/|watch(?:[/?]|$)|reel/|share/[vr]/)'
# 與 mdl.py 的 _PHOTO_PASS_FILTER 一字不差
$script:GdlPhotoPassFilter = "abort() if subcategory in ('albums', 'avatar', 'bookmark', 'collection', 'community', 'followed', 'following', 'info', 'likes', 'list', 'media', 'photos', 'posts', 'reels', 'replies', 'saved', 'search', 'stories-tray', 'tag', 'tagged', 'timeline', 'tweets', 'user') else (extension or '').lower() not in ('3gp', 'avi', 'f4v', 'flv', 'm3u8', 'm4s', 'm4v', 'mkv', 'mov', 'mp4', 'mpd', 'mpeg', 'mpg', 'ogv', 'ts', 'webm', 'wmv')"
$script:FbPhotoUrlErrRe = '(?i)facebook\.com/(?:photo(?:\.php)?/?\?|[^/\s]+/photos/|media/set/?\?|share/p/)'

# 回傳 instagram / instagram_stories / twitter / facebook，或 $null（這個網址不補抓照片）
function Get-AutoPhotoSite([string]$url, [bool]$hasCookies) {
    $t = ([string]$url).Trim()
    if (-not $t) { return $null }
    if ($t -match $script:AutoIgPostRe) { return 'instagram' }
    if ($t -match $script:AutoIgStoryRe) { if ($hasCookies) { return 'instagram_stories' } else { return $null } }
    if ($t -match $script:AutoXStatusRe) { return 'twitter' }
    if ($t -match $script:AutoFbRe) {
        $rest = [string]$Matches[1]
        if ($rest -notmatch $script:AutoFbExcludeRe -and $rest -match $script:AutoFbIncludeRe) { return 'facebook' }
    }
    return $null
}

function New-AutoPhotoState([string]$url) {
    $job = $script:Job
    if (-not $job -or $job.Kind -ne 'video' -or -not $job.AutoPhotos) { return $null }
    $site = Get-AutoPhotoSite $url (Test-JobHasCookies)
    if (-not $site) { return $null }
    return @{
        Url = $url; Site = $site; Videos = (New-Object System.Collections.Specialized.OrderedDictionary)
        ErrLines = (New-Object System.Collections.ArrayList)
        VideoExit = 0; VideoErr = ''; Kind = $null; SkipReason = $null; Retried = $false; SkippedExisting = $false
        RetryPending = $false; PhotoDone = $false; PhotoResult = $null; PhotoSkipped = $false
    }
}

# yt-dlp 的失敗是不是「這則貼文沒有影片」（同 mdl.py _photo_post_kind；實測訊息見該處）：
#   no_video      IG / X 的純照片貼文、輪播裡的照片格（確定沒有影片）
#   fb_photo_url  FB 照片／分享貼文網址，yt-dlp 沒有對應的抽取器（Unsupported URL）
#   fb_404        FB 貼文 HTTP 404
#   fb_no_data    FB 貼文 Cannot parse data（這兩種都是純照片貼文實測會出現的反應，但不保證）
function Get-PhotoPostKind([string]$t) {
    if (-not $t) { return $null }
    if (Test-PhotoOnlyError $t) { return 'no_video' }
    if ($t -match '(?i)unsupported url' -and $t -match $script:FbPhotoUrlErrRe) { return 'fb_photo_url' }
    if ($t -match '(?i)http error 404' -and $t -match '(?i)\[facebook[^\]]*\]') { return 'fb_404' }
    if ($t -match '(?i)cannot parse data' -and $t -match '(?i)\[facebook[^\]]*\]') { return 'fb_no_data' }
    return $null
}

# yt-dlp --print-to-file after_move:filepath 寫出的路徑，以磁碟為準（要存在、非 0 位元組）。
# 命中 "has already been downloaded" 時既有檔案的路徑也會被寫出來，所以用 mtime 分辨新舊
# （與 Complete-CurrentItem 相同的規則）。
function Get-PrintedFiles($job) {
    $rows = New-Object System.Collections.ArrayList
    try {
        if (-not $job.PrintFile -or -not (Test-Path -LiteralPath $job.PrintFile)) { return , $rows }
        $startedAt = $job.StartedAt
        if (-not $startedAt) { $startedAt = (Get-Date) }
        $cut = $startedAt.AddSeconds(-3)
        foreach ($f in @(Get-Content -LiteralPath $job.PrintFile -Encoding UTF8)) {
            $p = ([string]$f).Trim()
            if (-not $p) { continue }
            $it = $null
            try { if (Test-Path -LiteralPath $p -PathType Leaf) { $it = Get-Item -LiteralPath $p -Force } } catch { }
            if (-not $it -or $it.Length -le 0) { continue }
            $existing = $false
            if ($job.SkippedExisting) { $existing = ($it.LastWriteTime -lt $cut) }
            [void]$rows.Add(@{ Path = $it.FullName; Size = $it.Length; Existing = $existing; Kind = 'video' })
        }
    } catch { }
    return , $rows
}

function Write-AutoErrLines($auto) {
    foreach ($l in @($auto.ErrLines)) { Write-Raw ("          " + $l) }
    $auto.ErrLines.Clear()
}

# 影片步驟（yt-dlp）結束：記下產生的影片，必要時照舊用 --impersonate 重試，然後進入照片階段
function Complete-AutoVideoStep([int]$ExitCode, [string]$errText) {
    $job = $script:Job
    $auto = $job.Auto
    $n = $job.Index + 1
    $total = $job.Urls.Count

    foreach ($v in (Get-PrintedFiles $job)) {
        $key = ([string]$v.Path).ToLowerInvariant()
        if (-not $auto.Videos.Contains($key)) { $auto.Videos.Add($key, $v) }
    }
    if ($job.SkippedExisting) { $auto.SkippedExisting = $true }
    Remove-Quiet $job.OutFile
    Remove-Quiet $job.ErrFile
    Remove-Quiet $job.PrintFile

    if ($job.Stopping) {
        if ($ExitCode -ne 0) {
            Write-Log "[$n/$total] 已中止"
            $job.Auto = $null
            Finish-Job
            return
        }
        # 影片剛好下載完才按停止：不補抓照片，直接結算這一筆
        $auto.VideoExit = 0
        $auto.PhotoSkipped = $true
        $job.UseImpersonate = $false
        Complete-AutoItem
        return
    }

    $kind = $null
    if ($ExitCode -ne 0) { $kind = Get-PhotoPostKind $errText }
    $auto.VideoExit = $ExitCode
    $auto.VideoErr = $errText
    $auto.Kind = $kind

    if ($ExitCode -ne 0 -and -not $job.UseImpersonate) {
        # 重試必然再失敗的情況：cookie 讀不到、貼文只有照片（Get-SkipRetryReason）、FB 照片網址 yt-dlp 不支援
        $skip = Get-SkipRetryReason $errText
        if ($auto.Site -eq 'facebook' -and ($kind -eq 'fb_404' -or $kind -eq 'fb_no_data')) {
            # 純照片的 FB 貼文實測就是這個反應（但不保證）：先看貼文裡有沒有照片，
            # 有就不必再重試（省一次請求）；沒有的話 Complete-AutoItem 會回頭照舊用 --impersonate 重試。
            $auto.RetryPending = $true
            Start-ImageItem
            return
        }
        if (-not $skip -and $kind -ne 'fb_photo_url') {
            Write-AutoErrLines $auto
            Write-Log "[$n/$total] 失敗（代碼 $ExitCode），改用 --impersonate chrome 重試中..."
            $job.UseImpersonate = $true
            Start-CurrentItem
            return
        }
        $auto.SkipReason = $skip
    }
    $auto.Retried = [bool]$job.UseImpersonate
    $job.UseImpersonate = $false

    # FB：照片階段已經在重試之前跑過了，直接結算
    if ($auto.PhotoDone) { Complete-AutoItem; return }

    if ($ExitCode -ne 0 -and $auto.Videos.Count -eq 0) {
        # cookie 來源本身讀不到：照片階段用的是同一份 cookie，不必再試
        if ($errText -match $script:CookieDbRe) { Complete-AutoItem; return }
        # 未登入時 IG 的照片與影片走的是 yt-dlp 同一個公開介面；它剛剛才因為別的原因失敗
        # （需要登入、限流、貼文不存在…），再問一次只會多打幾次 IG
        if ($auto.Site -eq 'instagram' -and $kind -ne 'no_video' -and -not (Test-JobHasCookies)) { Complete-AutoItem; return }
    }
    Start-ImageItem
}

# 這一筆（影片 + 照片）的結算。$job.Img 是照片階段的結果；沒跑照片階段時是 $null。
# 判定規則同 mdl.py _merge_photo_pass。
function Complete-AutoItem {
    $job = $script:Job
    $auto = $job.Auto
    $img = $job.Img
    if (-not $img -and $auto.PhotoResult) { $img = $auto.PhotoResult }
    $job.Http = $null
    $job.Proc = $null
    Close-Readers $job
    Set-BarStyle 'Continuous'
    $n = $job.Index + 1
    $total = $job.Urls.Count

    $videos = @($auto.Videos.Values)
    $vNew = @($videos | Where-Object { -not $_.Existing })
    $vOld = @($videos | Where-Object { $_.Existing })
    $photos = @()
    if ($img) { $photos = @($img.Files) }

    if ($auto.RetryPending) {
        # FB 貼文第一次失敗（404／Cannot parse data）之後先跑的照片階段到此結束
        $auto.RetryPending = $false
        $auto.PhotoDone = $true
        if ($photos.Count -eq 0 -and -not $job.Stopping) {
            # 貼文裡沒有照片 → 影片照舊用 --impersonate 再試一次；結算時沿用這次照片階段的結果
            $auto.PhotoResult = $img
            $job.Img = $null
            $job.Phase = $null
            Write-AutoErrLines $auto
            Write-Log "[$n/$total] 失敗（代碼 $($auto.VideoExit)），改用 --impersonate chrome 重試中..."
            $job.UseImpersonate = $true
            Start-CurrentItem
            return
        }
    }

    $videoFailed = ($auto.VideoExit -ne 0)
    $kind = [string]$auto.Kind
    $noVideo = $videoFailed -and [bool]$kind

    # 照片階段是不是「乾淨地跑完、只是這則貼文沒有照片」
    $photoClean = $false
    $photoErr = $null
    $photoWarn = @()
    if ($img) {
        if ($img.Fb) { $photoClean = ([bool]$img.Fb.JsonOk -and $img.Fb.PhotoEntries -eq 0) }
        else { $photoClean = ($img.Rc -eq 0 -and -not $img.ErrorText) }
        $photoErr = [string]$img.ErrorText
        if (-not $photoErr -and -not $photoClean) { $photoErr = Get-GdlCompactError ([string]$img.HintErr) ([int]$img.Rc) }
        $photoWarn = @($img.Warnings | Where-Object { $_ -and ([string]$_) -notmatch '已改用 yt-dlp 的公開介面|網址沒有 https://' })
    }

    if ($photos.Count -gt 0) {
        # ---------- 有照片：成功
        $pOld = @($photos | Where-Object { $_.Existing }).Count
        $allImg = (@($photos | Where-Object { $_.Kind -ne 'image' }).Count -eq 0)
        $unit = if ($allImg) { '張照片' } else { '個檔案' }
        $oldNote = ''
        if ($pOld -gt 0 -and $pOld -lt $photos.Count) { $oldNote = "（其中 $pOld 張先前已下載過）" }
        elseif ($pOld -eq $photos.Count) { $oldNote = '（先前已下載過，沒有重新下載）' }
        $what = if ($allImg) { "照片 $($photos.Count) 張" } else { "其他檔案 $($photos.Count) 個" }
        if ($videos.Count -gt 0) {
            $head = "完成：影片 $($videos.Count) 支、$what$oldNote"
        } elseif ($noVideo) {
            if ($pOld -eq $photos.Count) { $head = "完成：這則貼文沒有影片，$($photos.Count) ${unit}先前已經下載過（沒有重新下載）" }
            else { $head = "完成：這則貼文沒有影片，已下載 $($photos.Count) $unit$oldNote" }
        } elseif ($videoFailed) {
            $head = "完成：沒有抓到影片；$what$oldNote"
        } else {
            $head = "完成：$what$oldNote"
        }
        Write-Log "[$n/$total] $head"
        foreach ($f in $videos) {
            $tag = if ($f.Existing) { '影片/已存在' } else { '影片' }
            Write-Raw ("          [{0}] {1}  ({2})" -f $tag, $f.Path, (Format-Size $f.Size))
        }
        foreach ($f in $photos) {
            $tag = switch ([string]$f.Kind) { 'image' { '照片' } 'video' { '影片' } default { '其他' } }
            if ($f.Existing) { $tag += '/已存在' }
            Write-Raw ("          [{0}] {1}  ({2})" -f $tag, $f.Path, (Format-Size $f.Size))
        }
        if ($videoFailed -and $kind -ne 'no_video') {
            # 「輪播裡的照片格沒有影片」不算失敗；其餘的影片錯誤降級成一行注意
            if ($videos.Count -gt 0) {
                Write-Log "注意：yt-dlp 回報有項目失敗（$(Get-YtCompactError $auto.VideoErr)），其餘影片已下載。"
            } elseif (-not $kind) {
                Write-Log "注意：影片沒有抓到（$(Get-YtCompactError $auto.VideoErr)），只下載到貼文裡的照片。這則貼文如果有影片，請依下面的建議處理後再試："
                Write-Advice $auto.VideoErr
            }
        }
        if ($img.Rc -ne 0 -and $img.ErrorText) { Write-Log "注意：gallery-dl 回報有項目失敗（$($img.ErrorText)），其餘 $($photos.Count) 個檔案已下載。" }
        foreach ($w in $photoWarn) { Write-Log "注意：$w" }
        if ($photos.Count -ge $ImgMaxFiles -and -not (@($photoWarn) -match '上限')) {
            Write-Log "注意：已達上限 $ImgMaxFiles 個檔案，可能還有更多照片沒下載。"
        }
        $job.Success++
    } elseif ($videos.Count -gt 0 -or -not $videoFailed) {
        # ---------- 只有影片：成功（訊息與沒有補抓功能時相同）。照片階段沒抓到東西不出聲，
        #            只有 yt-dlp 自己說「貼文裡有幾格是照片」（照片確實該有）時才補一行注意。
        if ($vNew.Count -gt 0) {
            Write-Log "[$n/$total] 完成，產生 $($vNew.Count) 個檔案："
            foreach ($f in $vNew) { Write-Raw ("          " + $f.Path) }
            if ($vOld.Count -gt 0) { Write-Log "（另有 $($vOld.Count) 個檔案已存在，略過未重新下載）" }
        } elseif ($vOld.Count -gt 0) {
            Write-Log "[$n/$total] 已存在，略過（沒有產生新檔案）："
            foreach ($f in $vOld) { Write-Raw ("          " + $f.Path) }
        } elseif ($auto.SkippedExisting) {
            Write-Log "[$n/$total] 已存在，略過（沒有產生新檔案）"
        } else {
            Write-Log "[$n/$total] 完成（沒有新檔案，可能已存在而略過）"
        }
        if ($videoFailed -and $kind -ne 'no_video') {
            Write-Log "注意：yt-dlp 回報有項目失敗（$(Get-YtCompactError $auto.VideoErr)），其餘影片已下載。"
        }
        if ($img) {
            $why = [regex]::Replace([string]$photoErr, '\s+', ' ').Trim()
            if ($why.Length -gt 160) { $why = $why.Substring(0, 160) + '…' }
            if ($videoFailed -and $kind -eq 'no_video' -and -not $photoClean) {
                if (-not $why) { $why = '沒有找到照片' }
                Write-Log "注意：這則貼文裡有幾格是照片，已自動嘗試下載但沒有成功：$why"
            } elseif ($photoClean) {
                Write-Raw '          （這則貼文沒有另外的照片）'
            } elseif ($why) {
                Write-Raw "          （沒有補抓到貼文照片：${why}；不影響已下載的影片）"
            } else {
                Write-Raw '          （沒有補抓到貼文照片；不影響已下載的影片）'
            }
        }
        $job.Success++
    } else {
        # ---------- 磁碟上什麼都沒有：失敗
        $removed = 0
        if ($img) { $removed = Remove-ImagePartials $img }
        if ($kind -and $img) {
            # 沒有影片、照片也沒抓到：說清楚「沒有影片，自動補抓照片也沒有結果」以及照片為什麼沒抓到
            $head = switch ($kind) {
                'no_video'     { '這則貼文沒有影片' }
                'fb_photo_url' { '這是 Facebook 的照片／貼文網址（yt-dlp 只支援影片）' }
                default        { 'yt-dlp 抓不到這則 Facebook 貼文的影片（純照片貼文實測就是這個反應）' }
            }
            if ($auto.Retried) { Write-AutoErrLines $auto }
            if ($photoClean) {
                Write-Log "[$n/$total] 失敗：$head，自動補抓照片也沒有找到任何照片。"
                $hint = '可能是純文字貼文，或網址指向的不是貼文本身；請確認網址能在瀏覽器打開。'
                if ($kind -eq 'fb_404' -or $kind -eq 'fb_no_data') { $hint += '若確定是影片貼文，可能是貼文不公開或需要登入：請按「開啟登入瀏覽器」登入 Facebook，再勾選「使用登入瀏覽器的 cookie」後重試。' }
            } else {
                Write-Log "[$n/$total] 失敗：$head，自動補抓照片也沒有成功（$photoErr）"
                $hint = [string]$img.Hint
                if (-not $hint) { $hint = Get-ImageHint ([string]$img.HintErr) ([string]$img.HintOut) ([bool]$img.HasCookies) ([string]$img.FetchUrl) $img.CookieIssue }
            }
            foreach ($w in $photoWarn) { Write-Log "注意：$w" }
            if ($removed) { Write-Log "注意：已清除 $removed 個本次留下的 .part 暫存檔。" }
            if ($hint) { Write-Log "建議：$hint" }
        } else {
            # 影片失敗的原因不是「沒有影片」、照片也沒有（或沒有補抓）：照舊回報影片的錯誤與建議
            Write-AutoErrLines $auto
            if ($auto.SkipReason) {
                Write-Log "[$n/$total] 失敗（代碼 $($auto.VideoExit)）：$($job.CurrentUrl)"
                Write-Log "（$($auto.SkipReason)）"
            } elseif ($auto.Retried) {
                Write-Log "[$n/$total] 失敗（重試後仍失敗，代碼 $($auto.VideoExit)）：$($job.CurrentUrl)"
            } else {
                Write-Log "[$n/$total] 失敗（代碼 $($auto.VideoExit)）：$($job.CurrentUrl)"
            }
            Write-Advice $auto.VideoErr
        }
        $job.Fail++
    }

    $job.Img = $null
    $job.Auto = $null
    $job.Phase = $null
    $job.UseImpersonate = $false
    $job.Index++
    Start-NextOrFinish
}

# ============================================================ 音樂：隔離下載
# 為什麼「MP3 音樂」不能直接下載到輸出資料夾（實測 yt-dlp 2026.08.19，同 mdl.py _isolated_run）：
#   -x 轉檔前的檔名是 <標題> [<ID>].<來源副檔名>。X 的 HLS 音訊、IG / FB 退回 b 格式時來源副檔名是 mp4，
#   正好等於先前用影片模式下載的同一支影片。yt-dlp 看到同名檔就當成「已經下載好的中間檔」，
#   拿它轉出 mp3 之後把「中間檔」刪掉——使用者的影片就不見了。同名的封面圖也會被拿去嵌入後刪除，
#   既有的 mp3 每跑一次都會被重寫一遍。（-P temp: 沒有用；-k 也不夠，見 mdl.py 的說明。）
# 做法：yt-dlp 只在輸出資料夾底下一個「這次才建立」的工作資料夾裡動作，碰不到任何既有檔案。
#   1. 探查（Stage = probe）：yt-dlp -j 取得每個項目的資訊與檔名 → 算出成品路徑；成品已經存在的項目
#      直接略過（不重新下載、也不動那個檔案），全部都在就到此為止，連工作資料夾都不建立。
#   2. 下載（Stage = dl）：把還沒有成品的項目的 JSON 交給 yt-dlp --load-info-json（不必再向網站要一次資訊），
#      輸出到工作資料夾。
#   3. 搬移：只把 yt-dlp 回報的成品（與同名的附屬檔）搬到輸出資料夾，目的地已經有檔案就不搬（絕不覆蓋）；
#      最後把工作資料夾整個刪掉（裡面只有這次產生的來源檔、封面圖、.part…），中止或失敗時也一樣。
$script:WorkDirPrefix = '.mdltmp-'
# 探查時每個項目印一行（與 mdl.py 的 _PROBE_TEMPLATE 相同；這裡只用到前兩欄：來源副檔名、檔名）
$script:AudProbeFmt = @('%(ext|)s', '%(filename|)s', '%(duration|)s', '%(extractor_key|)s', '%(webpage_url|)s',
                        '%(uploader,channel,uploader_id|)j', '%(title|)j') -join $script:MetaSep
# --audio-format → 成品副檔名；不在表裡（best、aac…）就不預先判斷成品檔名
$script:AudioExtByFormat = @{ 'mp3' = 'mp3'; 'm4a' = 'm4a'; 'opus' = 'opus'; 'flac' = 'flac'; 'wav' = 'wav'; 'vorbis' = 'ogg' }
# 搬附屬檔時要排除的暫存檔：.part / .ytdl / .part-FragN / .temp.<ext> / 分軌檔 .fNNN.<ext>
$script:WorkTempNameRe = '(?i)(?:\.part|\.ytdl|\.part-Frag\d+(?:\.part)?|\.temp\.[A-Za-z0-9]{1,5}|\.f[0-9A-Za-z][0-9A-Za-z_\-]*\.[A-Za-z0-9]{1,5})$'

function Get-OutDirFull {
    $t = $txtOut.Text.Trim()
    if (-not [System.IO.Path]::IsPathRooted($t)) { $t = Join-Path $Root $t }
    $d = [System.IO.Path]::GetFullPath($t).TrimEnd('\')
    if ($d.Length -eq 2 -and $d.EndsWith(':')) { $d += '\' }
    return $d
}

# 成品副檔名：@{ Known = 是否確定; Ext = 'mp3' 之類，'' 代表沒有 -x（成品就是下載到的檔案） }
function Get-AudioFinalExt([string[]]$argList) {
    $hasX = $false
    $fmt = ''
    for ($i = 0; $i -lt $argList.Count; $i++) {
        $a = [string]$argList[$i]
        if ($a -ceq '-x' -or $a -ceq '--extract-audio') { $hasX = $true }
        elseif ($a -ceq '--audio-format' -and ($i + 1) -lt $argList.Count) { $fmt = [string]$argList[$i + 1] }
        elseif ($a.StartsWith('--audio-format=')) { $fmt = $a.Substring(15) }
    }
    if (-not $hasX) { return @{ Known = $true; Ext = '' } }
    $k = $fmt.Trim().ToLowerInvariant()
    if ($k -and $script:AudioExtByFormat.ContainsKey($k)) { return @{ Known = $true; Ext = [string]$script:AudioExtByFormat[$k] } }
    return @{ Known = $false; Ext = '' }
}

# 轉檔後的檔名（同 yt-dlp replace_extension）：<檔名去掉來源副檔名>.<成品副檔名>
function Get-ExpectedOutput([string]$filename, [string]$srcExt, [string]$finalExt) {
    if (-not $filename) { return $null }
    if (-not $finalExt) { return $filename }
    $sep = [math]::Max($filename.LastIndexOf('\'), $filename.LastIndexOf('/'))
    $dot = $filename.LastIndexOf('.')
    $root = $filename
    $realExt = ''
    # 同 Python os.path.splitext：檔名開頭的點不算副檔名
    if ($dot -gt ($sep + 1) -and $filename.Substring($sep + 1, $dot - $sep - 1).Trim('.').Length -gt 0) {
        $root = $filename.Substring(0, $dot)
        $realExt = $filename.Substring($dot + 1)
    }
    if (-not $srcExt -or $realExt -ceq $srcExt) { return ($root + '.' + $finalExt) }
    return ($filename + '.' + $finalExt)
}

# path 在 base 資料夾底下就回傳相對路徑，否則 $null（兩邊都是絕對路徑，純字串比對）
function Get-RelInside([string]$path, [string]$base) {
    if (-not $path -or -not $base) { return $null }
    $p = $path.Replace('/', '\')
    $b = $base.Replace('/', '\').TrimEnd('\') + '\'
    if ($p.Length -gt $b.Length -and $p.StartsWith($b, [System.StringComparison]::OrdinalIgnoreCase)) { return $p.Substring($b.Length) }
    return $null
}

# 把 src 搬到 dst，目的地已經有東西就不搬。回傳 'moved' / 'exists' / 錯誤訊息
function Move-NoClobber([string]$src, [string]$dst) {
    $last = ''
    for ($i = 0; $i -lt 6; $i++) {
        try {
            $dir = [System.IO.Path]::GetDirectoryName($dst)
            if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
            if ([System.IO.File]::Exists($dst) -or [System.IO.Directory]::Exists($dst)) { return 'exists' }
            [System.IO.File]::Move($src, $dst)     # 目的地已存在會丟例外，不會覆蓋
            return 'moved'
        } catch {
            $last = [string]$_.Exception.Message
            try { if ([System.IO.File]::Exists($dst)) { return 'exists' } } catch { }
        }
        # 防毒／同步軟體短暫鎖檔：等一下再試
        Start-Sleep -Milliseconds (300 * ($i + 1))
    }
    if (-not $last) { $last = '搬移失敗' }
    return $last
}

# 中止時 taskkill /T 是「先列出行程樹、再逐一結束」：yt-dlp 剛好在那一瞬間啟動的 ffmpeg／ffprobe 會漏掉而變成
# 孤兒，繼續轉檔並佔住工作資料夾裡的檔案（實測：下載剛結束、正要轉檔時關閉視窗就會遇到）。
# 工作資料夾的名字是這次才產生的亂數，命令列裡帶有它的行程一定是這次下載留下的，可以放心結束。
function Stop-WorkDirProcs([string]$dir) {
    try {
        $leaf = [System.IO.Path]::GetFileName($dir)
        if (-not $leaf -or -not $leaf.StartsWith($script:WorkDirPrefix)) { return }
        $found = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe' OR Name='ffprobe.exe' OR Name='yt-dlp.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($leaf, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
        foreach ($p in $found) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    } catch { }
}

# 刪掉這次建立的工作資料夾（剛結束的行程可能還沒放開檔案，重試幾次）。回傳是否已經不存在
function Remove-WorkDir([string]$dir) {
    if (-not $dir) { return $true }
    if (-not ([System.IO.Path]::GetFileName($dir)).StartsWith($script:WorkDirPrefix)) { return $false }
    for ($i = 0; $i -lt 10; $i++) {
        if (-not [System.IO.Directory]::Exists($dir)) { return $true }
        try {
            [System.IO.Directory]::Delete($dir, $true)
        } catch {
            # 刪不掉：先確認不是還有這次下載的孤兒行程佔著檔案，再等一下重試
            if ($i -eq 0 -or $i -eq 4) { Stop-WorkDirProcs $dir }
            Start-Sleep -Milliseconds (200 * ($i + 1))
        }
    }
    return (-not [System.IO.Directory]::Exists($dir))
}

function New-AudioState {
    $outDir = Get-OutDirFull
    $work = $null
    for ($i = 0; $i -lt 50; $i++) {
        $work = Join-Path $outDir ($script:WorkDirPrefix + [guid]::NewGuid().ToString('N').Substring(0, 6))
        if (-not ([System.IO.Directory]::Exists($work) -or [System.IO.File]::Exists($work))) { break }
    }
    return @{
        Stage = 'probe'; OutDir = $outDir; WorkDir = $work; Created = $false
        JsonFile = $null; ProbeMeta = $null; ListFile = $null
        FinalExtKnown = $false; FinalExt = ''
        Already = (New-Object System.Collections.ArrayList); Reported = (New-Object System.Collections.ArrayList)
        ProbeExit = 0; ProbeErr = ''; SkipReason = $null; Tick = 0; Seen = 0
    }
}

# 工作資料夾一定要是「這次才建立」的（已存在就不用），結束時才能放心整個刪掉
function New-AudioWorkDir($aud) {
    if ([System.IO.Directory]::Exists($aud.WorkDir) -or [System.IO.File]::Exists($aud.WorkDir)) {
        throw "工作資料夾已經存在：$($aud.WorkDir)"
    }
    $di = [System.IO.Directory]::CreateDirectory($aud.WorkDir)
    $aud.Created = $true
    # 設成隱藏：下載期間不要在使用者的資料夾裡閃一個奇怪的資料夾
    try { $di.Attributes = $di.Attributes -bor [System.IO.FileAttributes]::Hidden } catch { }
}

function Read-TextLines([string]$path) {
    $rows = New-Object System.Collections.ArrayList
    try {
        if ($path -and (Test-Path -LiteralPath $path)) {
            foreach ($ln in @(Get-Content -LiteralPath $path -Encoding UTF8)) {
                $s = ([string]$ln).Trim()
                if ($s) { [void]$rows.Add($s) }
            }
        }
    } catch { }
    return , $rows
}

function Read-AudioProbe([string]$path) {
    $rows = New-Object System.Collections.ArrayList
    foreach ($s in (Read-TextLines $path)) {
        $p = @($s -split [regex]::Escape($script:MetaSep), 7)
        $fn = ''
        if ($p.Count -gt 1) { $fn = ([string]$p[1]).Trim() }
        [void]$rows.Add(@{ Ext = ([string]$p[0]).Trim(); Filename = $fn })
    }
    return , $rows
}

# 探查的 stdout：一行一個 JSON（一個項目一行）
function Get-JsonLineCount([string]$path) {
    $c = 0
    try {
        $sr = New-Object System.IO.StreamReader($path, (New-Object System.Text.UTF8Encoding($false)))
        try {
            while ($null -ne ($ln = $sr.ReadLine())) { if ($ln.TrimStart().StartsWith('{')) { $c++ } }
        } finally { $sr.Dispose() }
    } catch { }
    return $c
}

# 把要下載的項目寫成一個 JSON 陣列給 --load-info-json 用（$keep = $null 代表全部）。UTF-8 不能帶 BOM。
function Write-AudioInfoList([string]$jsonFile, [string]$listFile, $keep) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $sr = New-Object System.IO.StreamReader($jsonFile, $enc)
    $sw = New-Object System.IO.StreamWriter($listFile, $false, $enc)
    $written = 0
    $idx = -1
    try {
        $sw.Write('[')
        while ($null -ne ($ln = $sr.ReadLine())) {
            $t = $ln.Trim()
            if (-not $t.StartsWith('{')) { continue }
            $idx++
            if ($null -ne $keep -and -not $keep.Contains($idx)) { continue }
            if ($written -gt 0) { $sw.Write(",`n") }
            $sw.Write($t)
            $written++
        }
        $sw.Write(']')
    } finally {
        $sr.Dispose()
        $sw.Dispose()
    }
    return $written
}

# 把工作資料夾裡 yt-dlp 回報的成品搬到輸出資料夾（保留相對路徑，例如播放清單的子資料夾）
function Move-AudioOutputs($aud, $reported) {
    $new = New-Object System.Collections.ArrayList
    $collided = New-Object System.Collections.ArrayList
    $warn = New-Object System.Collections.ArrayList
    foreach ($raw in @($reported)) {
        $src = [string]$raw
        $rel = Get-RelInside $src $aud.WorkDir
        $isFile = $false
        try { $isFile = [System.IO.File]::Exists($src) } catch { }
        if (-not $rel) {
            # 不在工作資料夾裡（理論上不會發生）：照原樣回報，不搬
            if ($isFile) { [void]$new.Add($src) }
            continue
        }
        if (-not $isFile) { continue }
        $dst = Join-Path $aud.OutDir $rel
        $name = [System.IO.Path]::GetFileName($src)
        # 同名的附屬檔（例如另存的字幕 <檔名>.en.vtt）：只認「這個成品的檔名 + .」開頭、而且不是暫存檔的
        $prefix = [System.IO.Path]::GetFileNameWithoutExtension($name) + '.'
        $sibs = @()
        try {
            $sibs = @([System.IO.Directory]::GetFiles([System.IO.Path]::GetDirectoryName($src)) | Where-Object {
                $fn = [System.IO.Path]::GetFileName($_)
                ($fn -ne $name) -and $fn.StartsWith($prefix, [System.StringComparison]::Ordinal) -and ($fn -notmatch $script:WorkTempNameRe)
            })
        } catch { $sibs = @() }
        $r = Move-NoClobber $src $dst
        if ($r -eq 'moved') { [void]$new.Add($dst) }
        elseif ($r -eq 'exists') { [void]$collided.Add($dst) }
        else { [void]$warn.Add("下載完成，但無法把 $name 搬到輸出資料夾：$r") }
        foreach ($s in $sibs) {
            $srel = Get-RelInside ([string]$s) $aud.WorkDir
            if ($srel) { [void](Move-NoClobber ([string]$s) (Join-Path $aud.OutDir $srel)) }
        }
    }
    return @{ New = $new; Collided = $collided; Warn = $warn }
}

# 這一筆的暫存檔與工作資料夾全部清掉（成品要先搬走）。任何結束路徑（完成／失敗／中止／關閉視窗）都會走到這裡。
function Close-AudioItem {
    $job = $script:Job
    if (-not $job) { return }
    $aud = $job.Aud
    if (-not $aud) { return }
    Close-Readers $job
    foreach ($f in @($aud.JsonFile, $aud.ProbeMeta, $aud.ListFile, $job.OutFile, $job.ErrFile, $job.PrintFile)) { Remove-Quiet ([string]$f) }
    if ($aud.Created) {
        if (-not (Remove-WorkDir $aud.WorkDir)) {
            Write-Log "注意：工作資料夾 $($aud.WorkDir) 沒有刪乾淨（可能被防毒或同步軟體鎖住），裡面只有這次下載的暫存檔，可以手動刪除。"
        }
        $aud.Created = $false
    }
    $job.Aud = $null
    $job.SkipOut = $false
}

# ------------------------------------------------ 音樂：探查
function Start-AudioProbe {
    $job = $script:Job
    $aud = $job.Aud
    $url = [string]$job.CurrentUrl
    $n = $job.Index + 1
    $total = $job.Urls.Count
    Close-Readers $job
    $job.ErrText = New-Object System.Text.StringBuilder
    $job.OutLeft = ''
    $job.ErrLeft = ''
    $job.Percent = 0
    $job.SkippedExisting = $false
    $job.StartedAt = (Get-Date)
    $job.SkipOut = $true      # stdout 是一行一個 JSON（一支影片就幾百 KB），不逐行讀進日誌
    Remove-Quiet ([string]$aud.JsonFile)
    Remove-Quiet ([string]$aud.ProbeMeta)
    Remove-Quiet ([string]$job.ErrFile)
    $aud.JsonFile  = New-TempFile 'aud_json'
    $aud.ProbeMeta = New-TempFile 'aud_probe'
    $aud.Stage = 'probe'
    $aud.Tick = 0
    $aud.Seen = 0
    $job.OutFile   = $aud.JsonFile
    $job.ErrFile   = New-TempFile 'err'
    $job.PrintFile = $null

    $argList = Build-YtDlpArgs -Url $url -WorkDir $aud.WorkDir -ProbeFile $aud.ProbeMeta -Impersonate:([bool]$job.UseImpersonate)
    $fx = Get-AudioFinalExt $argList
    $aud.FinalExtKnown = [bool]$fx.Known
    $aud.FinalExt = [string]$fx.Ext

    if ($job.UseImpersonate) { Write-Log "重試中（--impersonate chrome）：$url" }
    else { Write-Log "[$n/$total] 開始：$url" }
    Set-BarStyle 'Marquee'
    $lblStatus.Text = "第 $n/$total 筆 - 取得資訊中…"
    try {
        $job.Proc = Start-Redirected $YtDlpExe $argList $job.OutFile $job.ErrFile
    } catch {
        Write-Log "無法啟動 yt-dlp：$($_.Exception.Message)"
        $job.Proc = $null
        $job.UseImpersonate = $true      # 啟動不了就不必再試一次
        Complete-CurrentItem -ExitCode 1
    }
}

# 探查期間（播放清單可能要好一陣子）在狀態列顯示已經取得幾個項目
function Update-AudioProbeStatus {
    $job = $script:Job
    $aud = $job.Aud
    $aud.Tick = [int]$aud.Tick + 1
    if (($aud.Tick % 5) -ne 0) { return }
    $c = 0
    try {
        if ($aud.ProbeMeta -and (Test-Path -LiteralPath $aud.ProbeMeta)) {
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $fs = New-Object System.IO.FileStream($aud.ProbeMeta, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            try {
                $sr = New-Object System.IO.StreamReader($fs)
                while ($null -ne $sr.ReadLine()) { $c++ }
            } finally { $fs.Dispose() }
        }
    } catch { }
    if ($c -gt 0 -and $c -ne $aud.Seen) {
        $aud.Seen = $c
        $lblStatus.Text = "第 $($job.Index + 1)/$($job.Urls.Count) 筆 - 取得資訊中…（已取得 $c 個項目）"
    }
}

# ------------------------------------------------ 音樂：下載到工作資料夾
function Start-AudioDownload {
    $job = $script:Job
    $aud = $job.Aud
    $n = $job.Index + 1
    $total = $job.Urls.Count
    Close-Readers $job
    $job.ErrText = New-Object System.Text.StringBuilder
    $job.OutLeft = ''
    $job.ErrLeft = ''
    $job.Percent = 0
    $job.SkippedExisting = $false
    $job.SkipOut = $false
    $job.StartedAt = (Get-Date)
    $job.OutFile   = New-TempFile 'out'
    $job.ErrFile   = New-TempFile 'err'
    $job.PrintFile = New-TempFile 'paths'
    $aud.Stage = 'dl'

    $argList = Build-YtDlpArgs -Url ([string]$job.CurrentUrl) -PrintFile $job.PrintFile -WorkDir $aud.WorkDir -InfoJson $aud.ListFile -Impersonate:([bool]$job.UseImpersonate)
    Set-BarStyle 'Continuous'
    $bar.Value = 0
    $lblStatus.Text = "第 $n/$total 筆 - 準備中..."
    try {
        $job.Proc = Start-Redirected $YtDlpExe $argList $job.OutFile $job.ErrFile
    } catch {
        Write-Log "無法啟動 yt-dlp：$($_.Exception.Message)"
        $job.Proc = $null
        $job.UseImpersonate = $true
        Complete-CurrentItem -ExitCode 1
    }
}

# ------------------------------------------------ 音樂：一個階段（yt-dlp 行程）結束
function Complete-AudioStage([int]$ExitCode, [string]$errText) {
    $job = $script:Job
    $aud = $job.Aud
    $n = $job.Index + 1
    $total = $job.Urls.Count

    if ($aud.Stage -eq 'probe') {
        $rows = Read-AudioProbe $aud.ProbeMeta
        $nJson = Get-JsonLineCount $aud.JsonFile
        if ($job.Stopping) { Complete-AudioItem 1 $errText; return }
        if ($nJson -eq 0 -and $ExitCode -ne 0) {
            # 重試必然再失敗的情況（cookie 讀不到、貼文只有照片）就不浪費時間重試
            $skip = $null
            if (-not $job.UseImpersonate) { $skip = Get-SkipRetryReason $errText }
            if (-not $job.UseImpersonate -and -not $skip) {
                Write-Log "[$n/$total] 失敗（代碼 $ExitCode），改用 --impersonate chrome 重試中..."
                $job.UseImpersonate = $true
                Start-AudioProbe
                return
            }
            $aud.SkipReason = $skip
            Complete-AudioItem $ExitCode $errText
            return
        }
        $aud.ProbeExit = $ExitCode
        $aud.ProbeErr = $errText

        # 哪些項目的成品已經存在（行數對不上或不確定成品副檔名時不判斷：全部下載，搬移時照樣不會覆蓋）
        $keep = $null
        if ($nJson -gt 0 -and $rows.Count -eq $nJson -and $aud.FinalExtKnown) {
            $keep = New-Object 'System.Collections.Generic.HashSet[int]'
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $dest = $null
                $done = $false
                $exp = Get-ExpectedOutput ([string]$rows[$i].Filename) ([string]$rows[$i].Ext) ([string]$aud.FinalExt)
                $rel = $null
                if ($exp) { $rel = Get-RelInside $exp $aud.WorkDir }
                if ($rel) {
                    $dest = Join-Path $aud.OutDir $rel
                    try {
                        $fi = New-Object System.IO.FileInfo($dest)
                        $done = ($fi.Exists -and $fi.Length -gt 0)
                    } catch { $done = $false }
                }
                if ($done) { [void]$aud.Already.Add($dest) } else { [void]$keep.Add($i) }
            }
        }
        if ($nJson -eq 0 -or ($null -ne $keep -and $keep.Count -eq 0)) {
            # 沒有項目，或成品全部都已經存在：不建立工作資料夾、不碰任何檔案
            Complete-AudioItem $ExitCode $errText
            return
        }
        if ($aud.Already.Count -gt 0) {
            Write-Raw "          （$($aud.Already.Count) 個項目先前已經下載過，略過；下載其餘 $($keep.Count) 個）"
        }
        try {
            $aud.ListFile = New-TempFile 'aud_infos'
            [void](Write-AudioInfoList $aud.JsonFile $aud.ListFile $keep)
            Remove-Quiet ([string]$aud.JsonFile)
            $aud.JsonFile = $null
            Remove-Quiet ([string]$job.ErrFile)
            New-AudioWorkDir $aud
        } catch {
            Write-Log "無法準備下載：$($_.Exception.Message)"
            $job.UseImpersonate = $false
            Complete-AudioItem 1 $errText
            return
        }
        Start-AudioDownload
        return
    }

    # ---------- 下載階段結束
    foreach ($p in (Read-TextLines $job.PrintFile)) {
        if (-not $aud.Reported.Contains($p)) { [void]$aud.Reported.Add($p) }
    }
    if ($ExitCode -ne 0 -and -not $job.Stopping -and -not $job.UseImpersonate) {
        $skip = Get-SkipRetryReason $errText
        if (-not $skip) {
            # 已經完成的項目還在工作資料夾裡，重試時 yt-dlp 會直接沿用，不會重新下載
            Write-Log "[$n/$total] 失敗（代碼 $ExitCode），改用 --impersonate chrome 重試中..."
            $job.UseImpersonate = $true
            Remove-Quiet ([string]$job.OutFile); Remove-Quiet ([string]$job.ErrFile); Remove-Quiet ([string]$job.PrintFile)
            Start-AudioDownload
            return
        }
        $aud.SkipReason = $skip
    }
    $code = $ExitCode
    $allErr = $errText
    if ($aud.ProbeExit -ne 0) {
        if ($code -eq 0) { $code = [int]$aud.ProbeExit }
        if ($aud.ProbeErr) { $allErr = [string]$aud.ProbeErr + "`n" + $errText }
    }
    Complete-AudioItem $code $allErr
}

# ------------------------------------------------ 音樂：這一筆結算（搬成品 → 清工作資料夾 → 回報）
function Complete-AudioItem([int]$Code, [string]$errText) {
    $job = $script:Job
    $aud = $job.Aud
    $n = $job.Index + 1
    $total = $job.Urls.Count
    Set-BarStyle 'Continuous'

    $new = @()
    $warn = @()
    if ($aud.Created) {
        $mv = Move-AudioOutputs $aud @($aud.Reported)
        $new = @($mv.New)
        $warn = @($mv.Warn)
        foreach ($c in @($mv.Collided)) { [void]$aud.Already.Add($c) }
    }
    $old = @($aud.Already)
    $skipReason = $aud.SkipReason
    $retried = [bool]$job.UseImpersonate
    Close-AudioItem
    foreach ($w in $warn) { Write-Log "注意：$w" }

    if ($job.Stopping -and $Code -ne 0) {
        Write-Log "[$n/$total] 已中止"
        if ($new.Count -gt 0) {
            Write-Log "（中止前已經完成 $($new.Count) 個檔案：）"
            foreach ($f in $new) { Write-Raw ("          " + $f) }
        }
        Finish-Job
        return
    }

    if ($Code -eq 0) {
        if ($new.Count -gt 0) {
            Write-Log "[$n/$total] 完成，產生 $($new.Count) 個檔案："
            foreach ($f in $new) { Write-Raw ("          " + $f) }
            if ($old.Count -gt 0) { Write-Log "（另有 $($old.Count) 個檔案已存在，略過未重新下載）" }
        } elseif ($old.Count -gt 0) {
            Write-Log "[$n/$total] 已存在，略過（沒有產生新檔案）："
            foreach ($f in $old) { Write-Raw ("          " + $f) }
        } else {
            Write-Log "[$n/$total] 完成（沒有新檔案）"
        }
        $job.Success++
    } else {
        if ($skipReason) {
            Write-Log "[$n/$total] 失敗（代碼 $Code）：$($job.CurrentUrl)"
            Write-Log "（$skipReason）"
        } elseif ($retried) {
            Write-Log "[$n/$total] 失敗（重試後仍失敗，代碼 $Code）：$($job.CurrentUrl)"
        } else {
            Write-Log "[$n/$total] 失敗（代碼 $Code）：$($job.CurrentUrl)"
        }
        if ($new.Count -gt 0) {
            Write-Log "（其中 $($new.Count) 個檔案已經下載完成：）"
            foreach ($f in $new) { Write-Raw ("          " + $f) }
        }
        if ($old.Count -gt 0) { Write-Log "（另有 $($old.Count) 個檔案已存在，略過未重新下載）" }
        Write-Advice $errText
        $job.Fail++
    }
    $job.UseImpersonate = $false
    $job.Index++
    Start-NextOrFinish
}

# ------------------------------------------------ 影片 + 字幕：字幕檔的專用暫存資料夾
# 實測（yt-dlp 2026.08.19）：「嵌入字幕」時 yt-dlp 把字幕檔寫在影片旁邊（<檔名>.<語言>.vtt → 轉成 .srt → 嵌入 → 刪除）。
# 輸出資料夾裡若已經有同名的字幕檔（例如先前用命令列 --subs 另存的、或自己放的），會被當成「已下載」
# 而在轉檔時被覆寫、嵌入後被刪除。把 temp 與 subtitle 兩種路徑都指到這個資料夾，yt-dlp 就只會看這裡。
# 名字固定（不是每次一個）：中止後留下的 .part 下次還能接續；工作結束時是空的就刪掉。
function Get-SubsTempDir {
    try {
        $d = Join-Path (Get-OutDirFull) ($script:WorkDirPrefix + 'subs')
        if ([System.IO.File]::Exists($d)) { return $null }
        if (-not [System.IO.Directory]::Exists($d)) {
            $di = [System.IO.Directory]::CreateDirectory($d)
            try { $di.Attributes = $di.Attributes -bor [System.IO.FileAttributes]::Hidden } catch { }
        }
        return $d
    } catch { return $null }
}

# 裡面已經沒有任何檔案才刪（有續傳用的 .part 就留著，Write-LeftoverNotice 會提醒）
function Remove-SubsTempDirIfEmpty {
    try {
        $d = Join-Path (Get-OutDirFull) ($script:WorkDirPrefix + 'subs')
        if (-not [System.IO.Directory]::Exists($d)) { return }
        if (@([System.IO.Directory]::GetFiles($d, '*', [System.IO.SearchOption]::AllDirectories)).Count -gt 0) { return }
        [System.IO.Directory]::Delete($d, $true)
    } catch { }
}

# ============================================================ 參數組裝
function Build-YtDlpArgs {
    param(
        [string]$Url,
        [string]$PrintFile,
        [switch]$Impersonate,
        [string]$WorkDir,      # 音樂的隔離下載：yt-dlp 的輸出資料夾改成這個工作資料夾
        [string]$ProbeFile,    # 音樂的探查階段：不下載，只把每個項目的資訊印出來（stdout 一行一個 JSON）
        [string]$InfoJson      # 音樂的下載階段：用探查到的資訊下載（--load-info-json），不再向網站要一次
    )

    $a = New-Object System.Collections.Generic.List[string]

    foreach ($x in (Get-CfgArray $Cfg.common)) { $a.Add([string]$x) }
    # yt-dlp 輸出被重新導向到檔案時會用系統編碼（cp950）寫出，中文路徑／標題在日誌裡變亂碼；強制 UTF-8
    $a.Add('--encoding'); $a.Add('utf-8')
    $a.Add('--progress')

    if (Test-Path -LiteralPath $FFmpegExe) { $a.Add('--ffmpeg-location'); $a.Add($BinDir) }

    $a.Add('-P')
    if ($WorkDir) { $a.Add($WorkDir) } else { $a.Add($txtOut.Text) }

    if ($chkPlaylist.Checked) {
        $a.Add('--yes-playlist')
        $tpl = [string]$Cfg.output_template_playlist
        if (-not $tpl) { $tpl = '%(playlist_title,playlist_id|)s/%(playlist_index|)s%(title).100B [%(id)s].%(ext)s' }
    } else {
        $a.Add('--no-playlist')
        $tpl = [string]$Cfg.output_template
        if (-not $tpl) { $tpl = '%(title).120B [%(id)s].%(ext)s' }
    }
    $a.Add('-o'); $a.Add($tpl)

    if ($PrintFile) { $a.Add('--print-to-file'); $a.Add('after_move:filepath'); $a.Add($PrintFile) }
    if ($ProbeFile) { $a.Add('-j'); $a.Add('--print-to-file'); $a.Add($script:AudProbeFmt); $a.Add($ProbeFile) }

    $kind = 'video'
    if ($script:Job -and $script:Job.Kind) { $kind = [string]$script:Job.Kind }
    elseif (-not $rbVideo.Checked) { $kind = 'audio' }

    if ($kind -eq 'video') {
        $q = [string]$cboQuality.SelectedItem
        if (-not $q) { $q = 'best' }
        if ($q -eq 'best') {
            $fmt = [string]$Cfg.video.format_best
            if (-not $fmt) { $fmt = 'bv*+ba/b' }
        } else {
            $fmt = [string]$Cfg.video.format_capped
            if (-not $fmt) { $fmt = 'bv*[height<={H}]+ba/b[height<={H}]/bv*+ba/b' }
            $fmt = $fmt -replace '\{H\}', $q
        }
        $a.Add('-f'); $a.Add($fmt)

        $sort = [string]$Cfg.video.sort
        if (-not $sort) { $sort = 'ext:mp4:m4a' }
        $a.Add('-S'); $a.Add($sort)

        foreach ($x in (Get-CfgArray $Cfg.video.extra)) { $a.Add([string]$x) }

        if ($chkSubs.Checked) {
            # 字幕檔寫到專用暫存資料夾，輸出資料夾裡同名的既有字幕檔才不會被覆寫／刪除（見 Get-SubsTempDir）
            $subTmp = Get-SubsTempDir
            if ($subTmp) {
                $a.Add('-P'); $a.Add('temp:' + $subTmp)
                $a.Add('-P'); $a.Add('subtitle:' + $subTmp)
            }
            $a.Add('--embed-subs')
            $a.Add('--write-auto-subs')
            $a.Add('--sub-langs'); $a.Add('zh-Hant,zh-TW,zh-Hans,zh,en,en-orig,-live_chat')
            $a.Add('--convert-subs'); $a.Add('srt')
        }
    } else {
        $fmt = [string]$Cfg.audio.format
        if (-not $fmt) { $fmt = 'ba/b' }
        $a.Add('-f'); $a.Add($fmt)
        foreach ($x in (Get-CfgArray $Cfg.audio.extra)) { $a.Add([string]$x) }
        $a.Add('--audio-quality'); $a.Add((Get-AudioQualityValue))
    }

    foreach ($x in (Get-JobCookieArgs)) { $a.Add($x) }

    if ($Impersonate) { $a.Add('--impersonate'); $a.Add('chrome') }

    if ($InfoJson) { $a.Add('--load-info-json'); $a.Add($InfoJson) }
    else { $a.Add('--'); $a.Add($Url) }
    return $a.ToArray()
}

# 本次工作的 cookie 來源（工作開始時就決定好，下載途中改勾選不影響進行中的工作）：
#   登入瀏覽器 → 匯出的暫存 cookies.txt（--cookies，yt-dlp 與 gallery-dl 都吃）
#   舊的「用瀏覽器 Cookie」→ --cookies-from-browser <瀏覽器>
function Get-JobCookieArgs {
    $job = $script:Job
    if (-not $job) { return @() }
    if ($job.CookieFile) { return @('--cookies', [string]$job.CookieFile) }
    if ($job.BrowserCookies) { return @('--cookies-from-browser', [string]$job.BrowserCookies) }
    return @()
}

function Test-JobHasCookies {
    $job = $script:Job
    return [bool]($job -and ($job.CookieFile -or $job.BrowserCookies))
}

# ============================================================ 行程管理
$script:Job = $null
$script:SetupProc = $null

function New-TailReader([string]$path) {
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    return (New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false))))
}

function Read-NewLines([hashtable]$job, [string]$which) {
    $rk = $which + 'Reader'
    $fk = $which + 'File'
    $lk = $which + 'Left'
    if (-not $job[$rk]) {
        if (-not $job[$fk]) { return @() }
        if (-not (Test-Path -LiteralPath $job[$fk])) { return @() }
        try { $job[$rk] = New-TailReader $job[$fk] } catch { return @() }
    }
    $chunk = ''
    try { $chunk = $job[$rk].ReadToEnd() } catch { return @() }
    if (-not $chunk) { return @() }
    $buf = [string]$job[$lk] + $chunk
    $parts = $buf -split "`r`n|`n|`r"
    $job[$lk] = $parts[$parts.Count - 1]
    if ($parts.Count -le 1) { return @() }
    return @($parts[0..($parts.Count - 2)])
}

function Close-Readers([hashtable]$job) {
    foreach ($which in @('Out', 'Err')) {
        $rk = $which + 'Reader'
        if ($job[$rk]) {
            try { $job[$rk].Dispose() } catch { }
            $job[$rk] = $null
        }
    }
}

function Stop-ProcTree($proc) {
    if (-not $proc) { return }
    try {
        if (-not $proc.HasExited) {
            Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', "$($proc.Id)", '/T', '/F') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        }
    } catch { }
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
}

function Set-Running([bool]$running) {
    $btnStart.Enabled   = (-not $running) -and (Test-Path -LiteralPath $YtDlpExe)
    $btnStop.Enabled    = $running
    $btnUpdate.Enabled  = -not $running
    $btnSetup.Enabled   = -not $running
    $btnBrowse.Enabled  = -not $running
    $txtUrls.ReadOnly   = $running
    Update-ModeUi
}

# ------------------------------------------------ 啟動單筆
function Start-CurrentItem {
    $job = $script:Job
    $url = $job.Urls[$job.Index]
    $job.CurrentUrl = $url
    if ($job.Kind -eq 'image') { Start-ImageItem; return }
    if ($job.Kind -eq 'audio') {
        # 音樂：隔離下載（探查 → 下載到工作資料夾 → 成品搬到輸出資料夾），見「音樂：隔離下載」
        $job.UseImpersonate = $false
        try {
            $job.Aud = New-AudioState
        } catch {
            Write-Log "[$($job.Index + 1)/$($job.Urls.Count)] 失敗：無法使用輸出資料夾（$($_.Exception.Message)）"
            $job.Aud = $null
            $job.Fail++
            $job.Index++
            Start-NextOrFinish
            return
        }
        Start-AudioProbe
        return
    }
    # 影片模式的貼文網址：影片步驟結束後接著補抓照片（--impersonate 重試時沿用同一份狀態）
    if (-not $job.UseImpersonate) { $job.Auto = New-AutoPhotoState ([string]$url) }
    $job.ErrText = New-Object System.Text.StringBuilder
    $job.OutLeft = ''
    $job.ErrLeft = ''
    $job.Percent = 0
    $job.SkippedExisting = $false
    $job.StartedAt = (Get-Date)

    $job.OutFile   = New-TempFile 'out'
    $job.ErrFile   = New-TempFile 'err'
    $job.PrintFile = New-TempFile 'paths'

    $argList = Build-YtDlpArgs -Url $url -PrintFile $job.PrintFile -Impersonate:([bool]$job.UseImpersonate)

    $n = $job.Index + 1
    $total = $job.Urls.Count
    if ($job.UseImpersonate) {
        Write-Log "重試中（--impersonate chrome）：$url"
    } else {
        Write-Log "[$n/$total] 開始：$url"
    }
    Set-BarStyle 'Continuous'
    $bar.Value = 0
    $lblStatus.Text = "第 $n/$total 筆 - 準備中..."

    try {
        $job.Proc = Start-Redirected $YtDlpExe $argList $job.OutFile $job.ErrFile
    } catch {
        Write-Log "無法啟動 yt-dlp：$($_.Exception.Message)"
        $job.Proc = $null
        Complete-CurrentItem -ExitCode 1
    }
}

# ------------------------------------------------ 處理一行輸出
function Invoke-OutputLine([string]$line, [bool]$isErr) {
    $job = $script:Job
    if ($null -eq $line) { return }
    $line = $script:AnsiRegex.Replace($line, '')
    $line = $line.TrimEnd()
    if ($line -eq '') { return }

    if ($isErr) { [void]$job.ErrText.AppendLine($line) }

    # 內部實作細節（暫存路徑清單），不該出現在使用者日誌
    if ($line -match "^\[info\]\s+Writing\s+'%\(") { return }

    # 進度列
    if ($line -match '^\[download\]\s+([\d.]+)%') {
        $pct = [double]$Matches[1]
        $speed = ''
        $eta = ''
        if ($line -match '\sat\s+(\S+)') { $speed = $Matches[1] }
        if ($line -match '\sETA\s+(\S+)') { $eta = $Matches[1] }
        # HLS 分段下載時 yt-dlp 會輸出 Unknown / NA，直接顯示很像壞掉
        if ($speed -match '^(?i)(unknown|na|n/a|-+)$') { $speed = '' }
        if ($eta   -match '^(?i)(unknown|na|n/a|-+|--:--)$') { $eta = '計算中' }
        Set-BarStyle 'Continuous'
        $v = [int][math]::Round($pct)
        if ($v -lt 0) { $v = 0 }
        if ($v -gt 100) { $v = 100 }
        try { $bar.Value = $v } catch { }
        $n = $job.Index + 1
        $total = $job.Urls.Count
        $txt = "第 $n/$total 筆 - $pct%"
        if ($speed) { $txt += "  速度 $speed" }
        if ($eta)   { $txt += "  剩餘 $eta" }
        $lblStatus.Text = $txt
        # 每 25% 記一次，避免洗版
        if ($pct -ge ($job.Percent + 25)) {
            $job.Percent = [math]::Floor($pct / 25) * 25
            Write-Raw ("          " + $line)
        }
        return
    }

    if ($line -match '^\[download\]\s+Destination:\s*(.+)$') {
        # 一個項目可能有多軌（視訊、音訊各一次）；不歸零的話節流門檻會停在 100，
        # 第二軌（音訊）的進度就一行都不會被記錄。
        $job.Percent = 0
        try { $bar.Value = 0 } catch { }
        Set-BarStyle 'Continuous'
        Write-Raw ("          -> " + $Matches[1])
        return
    }
    if ($line -match '^\[(Merger|ExtractAudio|EmbedSubtitle|Metadata|ThumbnailsConvertor|EmbedThumbnail|VideoConvertor)\]') {
        # 後處理（ffmpeg）期間沒有進度輸出，狀態列要換字，否則看起來像當掉
        $stage = $Matches[1]
        $desc = switch ($stage) {
            'Merger'              { '合併影音中…' }
            'ExtractAudio'        { '轉檔中（抽出音訊）…' }
            'EmbedSubtitle'       { '嵌入字幕中…' }
            'Metadata'            { '寫入標題資訊中…' }
            'ThumbnailsConvertor' { '處理封面圖中…' }
            'EmbedThumbnail'      { '嵌入封面中…' }
            'VideoConvertor'      { '影片轉檔中…' }
            default               { '後處理中…' }
        }
        $n = $job.Index + 1
        $total = $job.Urls.Count
        $lblStatus.Text = "第 $n/$total 筆 - $desc（檔案較大時可能需要數十秒，請稍候）"
        Set-BarStyle 'Marquee'
        Write-Raw ("          " + $line)
        return
    }
    if ($line -match '^\[download\]\s+(Downloading item|Downloading playlist|Finished downloading)') {
        Write-Raw ("          " + $line)
        return
    }
    if ($line -match '(?i)has already been downloaded') {
        # --print-to-file 仍會寫出既有路徑，不記住這件事就會謊報「產生 N 個檔案」
        $job.SkippedExisting = $true
        Write-Raw ("          " + $line)
        return
    }
    if ($line -match '^\[download\]') { return }
    if ($line -match '^\[(youtube|generic|info|Twitter|Instagram|Facebook|TikTok|Bilibili)') {
        # 抽取器雜訊，只記關鍵字樣
        if ($line -match 'Downloading webpage' -or $line -match 'Extracting') { return }
    }
    if ($line -match '^(ERROR|WARNING|error:)') {
        # 會接著補抓照片的貼文網址：「沒有影片」之類的錯誤先留著，等這一筆結算時才決定要不要顯示
        # （純照片貼文是正常情況，不該先跳一行 ERROR 嚇人）
        if ($job.Auto -and -not $job.Img -and $line -match '^ERROR') { [void]$job.Auto.ErrLines.Add($line); return }
        Write-Raw ("          " + $line)
        return
    }

    Write-Raw ("          " + $line)
}

# ------------------------------------------------ 建議訊息
function Write-Advice([string]$errText) {
    if (-not $errText) { return }
    $t = $errText
    $given = $false

    $job = $script:Job
    $usedLogin = [bool]($job -and $job.CookieFile)

    # 瀏覽器正在執行時 yt-dlp 無法複製 cookie 資料庫。這種情況叫使用者「去勾 Cookie」
    # 毫無幫助（他已經勾了），所以要先判斷、並抑制底下的登入建議。
    $cookieLocked = ($t -match $script:CookieDbRe)
    if ($cookieLocked) {
        Write-Log '建議：無法讀取瀏覽器 Cookie（Chrome/Edge 開著時會鎖住 cookie 資料庫，新版的加密也可能讓它解不開）。建議改用登入瀏覽器：按「開啟登入瀏覽器」登入網站，再勾選「使用登入瀏覽器的 cookie」——不必關閉你平常用的 Chrome。'
        $given = $true
    }

    # 只有照片、沒有影片的貼文（yt-dlp 只抓影片）→ 改用圖片模式
    $photoOnly = Test-PhotoOnlyError $t
    $fbPhotoUrl = ($t -match '(?i)Unsupported URL' -and $t -match '(?i)facebook\.com/(?:photo(?:\.php)?/?\?|[^/\s]+/photos/|media/set/?\?)')
    if ($photoOnly -or $fbPhotoUrl) {
        Write-Log '建議：這則貼文只有照片、沒有影片。在「MP4 影片」模式勾選「貼文照片一併下載」就會自動把照片也抓下來；或改選「圖片 (IG/FB/X)」模式，整則貼文的照片（以及輪播裡的影片）都會抓。'
        $given = $true
    }

    if ((-not $cookieLocked) -and (-not $photoOnly) -and $t -match '(?i)(sign in|log in|login required|members-only|private video|This video is available to this channel''s members|confirm your age|age-restricted|cookies)') {
        if ($usedLogin) {
            Write-Log '建議：本次已帶登入瀏覽器的 cookie 仍被要求登入：請在登入瀏覽器實際打開這個網址，確認已登入而且看得到；登入過期就重新登入後再試。'
        } else {
            Write-Log '建議：這個內容需要登入：請按「開啟登入瀏覽器」登入該網站，再勾選「使用登入瀏覽器的 cookie」後重試。'
        }
        $given = $true
    }
    if ($t -match '(?i)HTTP Error 429|Too Many Requests') {
        Write-Log '建議：伺服器限流（429），請等幾分鐘再試，或降低同時下載數量。'
        $given = $true
    }
    if ($t -match '(?i)HTTP Error 403|Forbidden') {
        Write-Log '建議：伺服器拒絕（403），可先按「更新 yt-dlp」，或勾選「使用登入瀏覽器的 cookie」後重試。'
        $given = $true
    }
    if ($t -match '(?i)Unsupported URL' -and -not $fbPhotoUrl) {
        Write-Log '建議：這個網站 yt-dlp 不支援，請確認網址是影片頁而非首頁/分享頁。'
        $given = $true
    }
    if ($t -match '(?i)ffmpeg (is )?not (found|installed)|ffmpeg not found') {
        Write-Log '建議：缺少 ffmpeg，請執行「首次設定.bat」把 ffmpeg.exe 放進 bin\。'
        $given = $true
    }
    # yt-dlp 實際輸出有 "Video unavailable" 與 "This video is unavailable" 兩種寫法
    if ($t -match '(?i)video (is )?unavailable|removed by the uploader|no longer available|has been removed|account associated with this video has been terminated') {
        Write-Log '建議：影片已被移除、或不在你所在地區開放；請確認網址是否正確。'
        $given = $true
    }
    if ($t -match '(?i)impersonate target|curl_cffi') {
        Write-Log '建議：這份 yt-dlp.exe 不支援 --impersonate，請按「更新 yt-dlp」取得完整版。'
        $given = $true
    }
    if (-not $given) {
        Write-Log '建議：可先按「更新 yt-dlp」再試；若是私人/需登入內容，請用登入瀏覽器登入後勾選「使用登入瀏覽器的 cookie」。'
    }
}

# ------------------------------------------------ 單筆結束
function Complete-CurrentItem {
    param([int]$ExitCode)

    $job = $script:Job
    Close-Readers $job

    $n = $job.Index + 1
    $total = $job.Urls.Count
    $errText = ''
    if ($job.ErrText) { $errText = $job.ErrText.ToString() }

    # 音樂（隔離下載）：探查／下載各是一個 yt-dlp 行程，階段的銜接與結算都在 Complete-AudioStage
    if ($job.Aud) { Complete-AudioStage $ExitCode $errText; return }

    # 貼文網址 + 「貼文照片一併下載」：影片步驟到此結束，接著補抓照片，成敗最後一起結算
    if ($job.Auto) { Complete-AutoVideoStep $ExitCode $errText; return }

    if ($ExitCode -eq 0) {
        # 列出實際產生的檔案。注意：命中 "has already been downloaded" 時
        # --print-to-file 仍會寫出既有檔案的路徑，所以要用 mtime 分辨新舊，
        # 否則一個新檔案都沒產生卻謊報「產生 1 個檔案」。
        try {
            if ($job.PrintFile -and (Test-Path -LiteralPath $job.PrintFile)) {
                $files = @(Get-Content -LiteralPath $job.PrintFile -Encoding UTF8 | Where-Object { $_ -and $_.Trim() -ne '' })
                $startedAt = $job.StartedAt
                if (-not $startedAt) { $startedAt = (Get-Date) }
                $cut = $startedAt.AddSeconds(-3)
                $newFiles = @()
                $oldFiles = @()
                foreach ($f in $files) {
                    $p = $f.Trim()
                    $isNew = $true
                    # 只有 yt-dlp 真的說了 "has already been downloaded" 才去比對 mtime，
                    # 避免把「保留原始時間戳」的新檔案誤判成舊檔。
                    if ($job.SkippedExisting) {
                        try {
                            if (Test-Path -LiteralPath $p) {
                                $isNew = ((Get-Item -LiteralPath $p -Force).LastWriteTime -ge $cut)
                            }
                        } catch { }
                    }
                    if ($isNew) { $newFiles += $p } else { $oldFiles += $p }
                }
                if ($newFiles.Count -gt 0) {
                    Write-Log "[$n/$total] 完成，產生 $($newFiles.Count) 個檔案："
                    foreach ($f in $newFiles) { Write-Raw ("          " + $f) }
                    if ($oldFiles.Count -gt 0) {
                        Write-Log "（另有 $($oldFiles.Count) 個檔案已存在，略過未重新下載）"
                    }
                } elseif ($oldFiles.Count -gt 0 -or $job.SkippedExisting) {
                    Write-Log "[$n/$total] 已存在，略過（沒有產生新檔案）："
                    foreach ($f in $oldFiles) { Write-Raw ("          " + $f) }
                } else {
                    Write-Log "[$n/$total] 完成（沒有新檔案，可能已存在而略過）"
                }
            } elseif ($job.SkippedExisting) {
                Write-Log "[$n/$total] 已存在，略過（沒有產生新檔案）"
            } else {
                Write-Log "[$n/$total] 完成"
            }
        } catch {
            Write-Log "[$n/$total] 完成"
        }
        $job.Success++
        Remove-Quiet $job.OutFile
        Remove-Quiet $job.ErrFile
        Remove-Quiet $job.PrintFile
        $job.UseImpersonate = $false
        $job.Index++
        Start-NextOrFinish
        return
    }

    # 失敗
    Remove-Quiet $job.OutFile
    Remove-Quiet $job.ErrFile
    Remove-Quiet $job.PrintFile

    if ($job.Stopping) {
        Write-Log "[$n/$total] 已中止"
        Finish-Job
        return
    }

    # 重試必然再失敗的情況（cookie 讀不到、貼文只有照片）就不浪費時間重試
    $skip = $null
    if (-not $job.UseImpersonate) { $skip = Get-SkipRetryReason $errText }
    if (-not $job.UseImpersonate -and -not $skip) {
        Write-Log "[$n/$total] 失敗（代碼 $ExitCode），改用 --impersonate chrome 重試中..."
        $job.UseImpersonate = $true
        Start-CurrentItem
        return
    }

    if ($skip) {
        Write-Log "[$n/$total] 失敗（代碼 $ExitCode）：$($job.CurrentUrl)"
        Write-Log "（$skip）"
    } else {
        Write-Log "[$n/$total] 失敗（重試後仍失敗，代碼 $ExitCode）：$($job.CurrentUrl)"
    }
    Write-Advice $errText
    $job.Fail++
    $job.UseImpersonate = $false
    $job.Index++
    Start-NextOrFinish
}

function Start-NextOrFinish {
    $job = $script:Job
    if ($job.Stopping -or $job.Index -ge $job.Urls.Count) {
        Finish-Job
    } else {
        Start-CurrentItem
    }
}

function Finish-Job {
    $job = $script:Job
    # 保險：音樂的工作資料夾與暫存檔正常情況下在 Complete-AudioItem 就清掉了
    if ($job -and $job.Aud) { try { Close-AudioItem } catch { } }
    # 影片 + 字幕用的暫存資料夾：空的就刪掉（有中止後留下的續傳檔就留著）
    if ($job -and $job.Mode -eq 'download' -and $job.Kind -eq 'video') { Remove-SubsTempDirIfEmpty }
    if ($job -and $job.Mode -eq 'download') {
        Set-BarStyle 'Continuous'
        $bar.Value = 0
        if ($job.Stopping) {
            $lblStatus.Text = "已停止 - 成功 $($job.Success) 筆／失敗 $($job.Fail) 筆"
            Write-Log "已停止。成功 $($job.Success) 筆／失敗 $($job.Fail) 筆"
            Write-LeftoverNotice $txtOut.Text
        } else {
            $lblStatus.Text = "全部結束 - 成功 $($job.Success) 筆／失敗 $($job.Fail) 筆"
            Write-Log "=== 全部結束：成功 $($job.Success) 筆／失敗 $($job.Fail) 筆 ==="
        }
    }
    # 登入瀏覽器匯出的 cookie 暫存檔（內含登入 session；yt-dlp 還會把 cookie 寫回去）用完立即刪除
    if ($job -and $job.CookieFile) {
        Remove-Quiet $job.CookieFile
        Remove-Quiet ([string]$job.CookieFile + '.tmp')
    }
    $script:Job = $null
    Set-Running $false
}

# ============================================================ 輪詢 Timer
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    try {
        # --- 首次設定行程
        if ($script:SetupProc) {
            if ($script:SetupProc.HasExited) {
                $script:SetupProc = $null
                Write-Log '設定程式已結束，重新檢查 bin\ ...'
                Test-Binaries
            }
        }

        $job = $script:Job
        if ($job -and $job.Proc) {
            if (-not $job.SkipOut) { foreach ($ln in (Read-NewLines $job 'Out')) { Invoke-JobLine $ln $false } }
            foreach ($ln in (Read-NewLines $job 'Err')) { Invoke-JobLine $ln $true }
            if ($job.Aud -and $job.Aud.Stage -eq 'probe') { Update-AudioProbeStatus }

            if ($job.Proc.HasExited) {
                # 再吸一次殘留輸出
                Start-Sleep -Milliseconds 60
                if (-not $job.SkipOut) { foreach ($ln in (Read-NewLines $job 'Out')) { Invoke-JobLine $ln $false } }
                foreach ($ln in (Read-NewLines $job 'Err')) { Invoke-JobLine $ln $true }
                # 最後一行可能沒有換行，也要處理
                if (-not $job.SkipOut -and $job.OutLeft) { $l = $job.OutLeft; $job.OutLeft = ''; Invoke-JobLine $l $false }
                if ($job.ErrLeft) { $l = $job.ErrLeft; $job.ErrLeft = ''; Invoke-JobLine $l $true }
                $code = 1
                try { $code = [int]$job.Proc.ExitCode } catch { $code = 1 }
                $job.Proc = $null
                Close-Readers $job

                if ($job.Mode -eq 'update') {
                    Remove-Quiet $job.OutFile
                    Remove-Quiet $job.ErrFile
                    if ($code -eq 0) { Write-Log 'yt-dlp 更新完成。' } else { Write-Log "yt-dlp 更新失敗（代碼 $code）。可改執行「首次設定.bat」重新下載。" }
                    $lblStatus.Text = '就緒'
                    $script:Job = $null
                    Set-Running $false
                } elseif ($job.Kind -eq 'image' -or $job.Img) {
                    # $job.Img 有值 = 圖片流程進行中（圖片模式，或影片模式的照片補抓）
                    switch ([string]$job.Phase) {
                        'gdl'   { Complete-GdlPhase $code }
                        'ytj'   { Complete-YtjPhase $code }
                        'ytv'   { Complete-YtvPhase $code }
                        default { Complete-ImageItem }
                    }
                } else {
                    Complete-CurrentItem -ExitCode $code
                }
            }
        } elseif ($job -and $job.Http) {
            Update-HttpDownload
        }
    } catch {
        try { Write-Log "內部錯誤：$($_.Exception.Message)（第 $($_.InvocationInfo.ScriptLineNumber) 行）" } catch { }
        # 出錯後若工作已經沒有任何行程／下載／匯出在跑，就不會再有人推進它 → 記為失敗並往下一筆走，
        # 不然按鈕會一直停在「下載中」。
        try {
            $j = $script:Job
            if ($j -and $j.Mode -eq 'download' -and -not $j.Proc -and -not $j.Http -and -not $j.ExportOp) {
                # 補抓照片途中出錯：影片已經下載好的話這一筆仍算成功
                if ($j.Auto -and $j.Auto.Videos -and $j.Auto.Videos.Count -gt 0) { $j.Success++ } else { $j.Fail++ }
                if ($j.Aud) { try { Close-AudioItem } catch { } }
                $j.Img = $null; $j.Auto = $null; $j.Aud = $null; $j.Phase = $null; $j.UseImpersonate = $false
                $j.Index++
                Start-NextOrFinish
            }
        } catch { try { $script:Job = $null; Set-Running $false } catch { } }
    }
    # 登入瀏覽器的背景動作放最後處理：它的 OnDone 可能開對話框（對話框期間 Timer 仍會觸發）
    try { Update-BgOps } catch { try { Write-Log "內部錯誤：$($_.Exception.Message)" } catch { } }
})

function Invoke-JobLine([string]$ln, [bool]$isErr) {
    $job = $script:Job
    if (-not $job) { return }
    if ($job.Mode -ne 'download') { Write-Raw ("          " + $ln); return }
    if ($job.Kind -eq 'image' -or $job.Img) {
        switch ([string]$job.Phase) {
            'gdl'   { Invoke-GdlLine $ln $isErr }
            'ytj'   { Invoke-YtjLine $ln $isErr }
            default { Invoke-OutputLine $ln $isErr }
        }
        return
    }
    Invoke-OutputLine $ln $isErr
}

# ============================================================ 環境檢查
function Test-Binaries {
    $ok = $true
    if (-not (Test-Path -LiteralPath $YtDlpExe)) {
        Write-Log '**********************************************************'
        Write-Log '*  找不到 bin\yt-dlp.exe                                  *'
        Write-Log '*  請先執行「首次設定.bat」，或按下方的「現在設定」按鈕    *'
        Write-Log '**********************************************************'
        $lblStatus.Text = '缺少 yt-dlp.exe - 請先執行 首次設定.bat'
        $ok = $false
    } else {
        Write-Log "yt-dlp: $YtDlpExe"
    }
    if (-not (Test-Path -LiteralPath $FFmpegExe)) {
        Write-Log '警告：找不到 bin\ffmpeg.exe，高畫質影音合併與 MP3 轉檔將無法使用（只能下載單一格式）。'
    } else {
        Write-Log "ffmpeg: $FFmpegExe"
    }
    if (-not (Test-Path -LiteralPath $GalleryDlExe)) {
        Write-Log '警告：找不到 bin\gallery-dl.exe，「圖片」模式無法使用（請重跑「首次設定.bat」）；影片／音樂不受影響。'
    } else {
        Write-Log "gallery-dl: $GalleryDlExe"
    }
    $btnStart.Enabled = $ok
    if ($ok) { $lblStatus.Text = '就緒' }
    return $ok
}

# ============================================================ 事件
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '選擇輸出資料夾'
    try { if (Test-Path -LiteralPath $txtOut.Text) { $dlg.SelectedPath = $txtOut.Text } } catch { }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtOut.Text = $dlg.SelectedPath
        Save-GuiSettings
    }
})

$btnOpen.Add_Click({
    $p = $txtOut.Text
    try {
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Format-Arg $p)
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("無法開啟資料夾：$($_.Exception.Message)", '影音下載器')
    }
})

$btnClear.Add_Click({ $txtLog.Clear() })

$rbVideo.Add_CheckedChanged({ Update-ModeUi })
$rbAudio.Add_CheckedChanged({ Update-ModeUi })
$rbImage.Add_CheckedChanged({ Update-ModeUi })

# 兩種 cookie 來源互斥：登入瀏覽器（建議）與舊的「直接讀本機瀏覽器 Cookie」
$chkCookies.Add_CheckedChanged({
    if ($chkCookies.Checked -and $chkUseLogin.Checked) { $chkUseLogin.Checked = $false }
    Update-ModeUi
})
$chkUseLogin.Add_CheckedChanged({
    if ($chkUseLogin.Checked -and $chkCookies.Checked) { $chkCookies.Checked = $false }
    Update-ModeUi
})

$btnLoginOpen.Add_Click({ Invoke-LoginOpen (Get-FirstUrlInBox) })
$btnLoginTabs.Add_Click({ Invoke-LoginTabs })
$lblLogin.Add_Click({ $lblLogin.Text = '登入狀態：讀取中…'; Request-LoginStatus -Force })

# 使用者在登入瀏覽器登入完、切回本視窗時順便更新登入狀態（最多每 5 秒一次）
$form.Add_Activated({ if ($script:StartupDone) { Request-LoginStatus } })

$btnSetup.Add_Click({
    if (-not (Test-Path -LiteralPath $SetupPs1)) {
        [void][System.Windows.Forms.MessageBox]::Show('找不到 tools\setup.ps1', '影音下載器')
        return
    }
    try {
        Write-Log '啟動首次設定（會開一個主控台視窗，請等它跑完）...'
        $script:SetupProc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Format-Arg $SetupPs1)) `
            -PassThru
    } catch {
        Write-Log "無法啟動設定程式：$($_.Exception.Message)"
    }
})

$btnUpdate.Add_Click({
    if (-not (Test-Path -LiteralPath $YtDlpExe)) {
        Write-Log '尚未安裝 yt-dlp.exe，請先執行「首次設定.bat」。'
        return
    }
    if ($script:Job) { return }
    Write-Log '正在更新 yt-dlp（bin\yt-dlp.exe -U）...'
    $lblStatus.Text = '更新 yt-dlp 中...'
    $job = @{
        Mode = 'update'; Urls = @(); Index = 0; Success = 0; Fail = 0
        OutFile = (New-TempFile 'upd_out'); ErrFile = (New-TempFile 'upd_err')
        OutLeft = ''; ErrLeft = ''; OutReader = $null; ErrReader = $null
        Proc = $null; Stopping = $false; UseImpersonate = $false
        ErrText = (New-Object System.Text.StringBuilder); Percent = 0; PrintFile = $null; CurrentUrl = ''
    }
    $script:Job = $job
    Set-Running $true
    try {
        $job.Proc = Start-Redirected $YtDlpExe @('-U') $job.OutFile $job.ErrFile
    } catch {
        Write-Log "更新啟動失敗：$($_.Exception.Message)"
        $script:Job = $null
        Set-Running $false
    }
})

$btnStop.Add_Click({
    $job = $script:Job
    if (-not $job) { return }
    $job.Stopping = $true
    if ($job.ExportOp) {
        # 不強制結束匯出：它可能正以背景模式開著登入瀏覽器的設定檔，砍掉會留下孤兒行程
        Write-Log '使用者要求停止，等 cookie 匯出結束後就中止（最多約 25 秒）...'
    } elseif ($job.Http) {
        Write-Log '使用者要求停止，正在取消下載...'
    } else {
        Write-Log '使用者要求停止，正在終止下載程式...'
    }
    $lblStatus.Text = '停止中...'
    if ($job.Proc) { Stop-ProcTree $job.Proc }
    elseif (-not $job.Http -and -not $job.ExportOp) {
        # 沒有任何東西在跑（理論上不會發生）→ 直接結束，免得按鈕卡住
        Write-Log '已停止。'
        Finish-Job
    }
})

$btnStart.Add_Click({
    if ($script:Job) { return }

    if (-not (Test-Path -LiteralPath $YtDlpExe)) {
        [void][System.Windows.Forms.MessageBox]::Show('找不到 bin\yt-dlp.exe，請先執行「首次設定.bat」。', '影音下載器')
        return
    }

    $urls = @($txtUrls.Text -split "`r`n|`n|`r" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })
    if ($urls.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('請先貼上至少一個網址（一行一個）。', '影音下載器')
        return
    }

    $out = $txtOut.Text.Trim()
    if (-not $out) { $out = $DefaultOut; $txtOut.Text = $out }
    try {
        if (-not (Test-Path -LiteralPath $out)) { New-Item -ItemType Directory -Force -Path $out | Out-Null }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("無法建立輸出資料夾：$($_.Exception.Message)", '影音下載器')
        return
    }

    $kind = Get-ModeKey
    if ($kind -eq 'image' -and -not (Test-Path -LiteralPath $GalleryDlExe)) {
        [void][System.Windows.Forms.MessageBox]::Show('找不到 bin\gallery-dl.exe，「圖片」模式無法使用。請重跑「首次設定.bat」下載它（影片／音樂不受影響）。', '影音下載器')
        return
    }

    Save-GuiSettings

    # 貼文照片一併下載：只在「MP4 影片」模式生效；沒有 gallery-dl 就照舊只抓影片
    $autoPhotos = ($kind -eq 'video') -and [bool]$chkAutoPhotos.Checked
    $autoNoGdl = $false
    if ($autoPhotos -and -not (Test-Path -LiteralPath $GalleryDlExe)) {
        $autoPhotos = $false
        $anyCookies = [bool]($chkUseLogin.Checked -or $chkCookies.Checked)
        foreach ($u in $urls) { if (Get-AutoPhotoSite $u $anyCookies) { $autoNoGdl = $true; break } }
    }

    # 整批下載：只在「圖片」模式生效，工作開始時定案
    $bulkOn = ($kind -eq 'image') -and [bool]$chkBulk.Checked

    $mode = switch ($kind) {
        'video' { "MP4 影片 / 畫質 $([string]$cboQuality.SelectedItem)" + $(if ($autoPhotos) { ' / 貼文照片一併下載' } else { '' }) }
        'audio' { "MP3 音樂 / 音質 $(Get-AudioQualityValue)" }
        default {
            if ($bulkOn) { '圖片（gallery-dl，整批下載：IG 帳號／珍藏不設檔案數上限）' }
            else { "圖片（gallery-dl，每則最多 $ImgMaxFiles 個檔案）" }
        }
    }
    $cookieDesc = '不帶 cookie（未登入）'
    $browserCookies = $null
    if ($chkUseLogin.Checked) { $cookieDesc = '登入瀏覽器的 cookie' }
    elseif ($chkCookies.Checked) {
        $browserCookies = [string]$cboBrowser.SelectedItem
        if (-not $browserCookies) { $browserCookies = 'chrome' }
        $cookieDesc = "直接讀取 $browserCookies 的 Cookie"
    }
    Write-Log "=== 開始工作：$($urls.Count) 筆，$mode，$cookieDesc ==="
    Write-Log "輸出：$out"
    if ($autoNoGdl) { Write-Log '注意：找不到 bin\gallery-dl.exe，本次不會補抓貼文照片（請重跑「首次設定.bat」下載它）；影片照常下載。' }

    $script:Job = @{
        Mode = 'download'; Kind = $kind; Urls = $urls; Index = 0; Success = 0; Fail = 0
        AutoPhotos = $autoPhotos; Bulk = $bulkOn; Auto = $null; Aud = $null
        OutFile = $null; ErrFile = $null; PrintFile = $null
        OutLeft = ''; ErrLeft = ''; OutReader = $null; ErrReader = $null
        Proc = $null; Stopping = $false; UseImpersonate = $false
        ErrText = (New-Object System.Text.StringBuilder); Percent = 0; CurrentUrl = ''
        CookieFile = $null; BrowserCookies = $browserCookies; ExportOp = $null
        Phase = $null; Img = $null; Http = $null; SkipOut = $false
    }
    Set-Running $true
    if ($chkUseLogin.Checked) { Start-CookieExport } else { Start-CurrentItem }
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:Job) {
        $r = [System.Windows.Forms.MessageBox]::Show('還有工作正在進行，確定要關閉並中止下載嗎？', '影音下載器',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
        try { $script:Job.Stopping = $true; Stop-ProcTree $script:Job.Proc; Close-Readers $script:Job } catch { }
        # 音樂的工作資料夾（裡面只有這次的中間檔）不留在使用者的資料夾裡
        try { if ($script:Job.Aud) { Close-AudioItem } } catch { }
        try { if ($script:Job.Http -and $script:Job.Http.Wc) { $script:Job.Http.Wc.CancelAsync() } } catch { }
    }
    try { $timer.Stop() } catch { }
    Save-GuiSettings
    # cookie 暫存檔不能留在磁碟上：匯出還在跑就等它結束（最多 30 秒）再刪
    try {
        $cf = @()
        if ($script:Job -and $script:Job.CookieFile) { $cf += [string]$script:Job.CookieFile }
        foreach ($op in @($script:BgOps.ToArray())) {
            if ($op.Action -eq 'export' -and $op.Proc -and -not $op.Proc.HasExited) { [void]$op.Proc.WaitForExit(30000) }
            if ($op.State -and $op.State.CookieFile) { $cf += [string]$op.State.CookieFile }
            Remove-Quiet $op.OutFile; Remove-Quiet $op.ErrFile
        }
        foreach ($f in $cf) { Remove-Quiet $f; Remove-Quiet ($f + '.tmp') }
    } catch { }
})

$form.Add_Load({
    # 在視窗真正顯示前就把版面依 DPI 換算好，避免使用者看到跳動
    Update-Layout
    try {
        $scr = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
        $form.Location = New-Object System.Drawing.Point(
            ($scr.X + [int](($scr.Width - $form.Width) / 2)),
            ($scr.Y + [int](($scr.Height - $form.Height) / 2)))
    } catch { }
})

$form.Add_Shown({
    $txtLog.Clear()
    Write-Log '影音下載器 已啟動'
    Write-Log "根目錄：$Root"
    if ($script:ProfileWarn) { Write-Log $script:ProfileWarn }
    [void](Test-Binaries)
    # 上次異常結束（例如被強制關閉）可能留下 cookie 暫存檔；超過 6 小時的一律清掉
    try {
        $tdir = Join-Path $env:TEMP 'mdl_gui'
        if (Test-Path -LiteralPath $tdir) {
            Get-ChildItem -LiteralPath $tdir -Filter 'cookies_*' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-6) } |
                ForEach-Object { Remove-Quiet $_.FullName }
        }
    } catch { }
    $timer.Start()
    $script:StartupDone = $true
    Request-LoginStatus -Force
    $txtUrls.Focus()
})

# ============================================================ 套用設定
$txtUrls.Text = ''
try {
    # 提示文字（PS 5.1 的 TextBox 不支援 PlaceholderText，用 Cue Banner 替代不支援多行，改放日誌）
    $txtUrls.Text = ''
} catch { }

$txtOut.Text = [string]$Settings.OutDir
if (-not $txtOut.Text) { $txtOut.Text = $DefaultOut }

switch ([string]$Settings.Mode) {
    'audio' { $rbAudio.Checked = $true }
    'image' { $rbImage.Checked = $true }
    default { $rbVideo.Checked = $true }
}

$qSel = [string]$Settings.Quality
if ($cboQuality.Items.Contains($qSel)) { $cboQuality.SelectedItem = $qSel }
elseif ($cboQuality.Items.Count -gt 0) { $cboQuality.SelectedIndex = 0 }

$aSel = [string]$Settings.AudioQuality
$aIdx = -1
for ($i = 0; $i -lt $cboAudio.Items.Count; $i++) {
    if ((([string]$cboAudio.Items[$i]) -split '\s+')[0] -eq $aSel) { $aIdx = $i; break }
}
if ($aIdx -ge 0) { $cboAudio.SelectedIndex = $aIdx } elseif ($cboAudio.Items.Count -gt 0) { $cboAudio.SelectedIndex = 0 }

$chkPlaylist.Checked = [bool]$Settings.Playlist
$chkSubs.Checked     = [bool]$Settings.Subs
# 預設開啟；只有設定檔明確存了 false 才關閉
$chkAutoPhotos.Checked = ([string]$Settings.AutoPhotos -ne 'False')
# 預設關閉；只有設定檔明確存了 true 才勾選
$chkBulk.Checked = ([string]$Settings.BulkIG -eq 'True')
# 兩種 cookie 來源互斥；設定檔兩個都是 true 時以登入瀏覽器（建議做法）為準
$chkUseLogin.Checked = ([string]$Settings.LoginCookies -eq 'True')
$chkCookies.Checked  = [bool]$Settings.Cookies -and -not $chkUseLogin.Checked

$bSel = [string]$Settings.Browser
if ($cboBrowser.Items.Contains($bSel)) { $cboBrowser.SelectedItem = $bSel } else { $cboBrowser.SelectedIndex = 0 }

Update-ModeUi

# ============================================================ 執行
try {
    [System.Windows.Forms.Application]::Run($form)
} catch {
    try {
        [void][System.Windows.Forms.MessageBox]::Show("影音下載器發生錯誤：`r`n$($_.Exception.Message)", '影音下載器',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch { }
} finally {
    try { if ($script:Job -and $script:Job.Proc) { Stop-ProcTree $script:Job.Proc } } catch { }
    try { if ($script:Job -and $script:Job.Aud) { Close-AudioItem } } catch { }
    try { $form.Dispose() } catch { }
}
