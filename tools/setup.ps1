# setup.ps1 - 下載可攜版 yt-dlp.exe / gallery-dl.exe / ffmpeg.exe / ffprobe.exe 到 bin\
# 不安裝任何東西到系統，全部放在本資料夾內。
[CmdletBinding()]
param(
    [switch]$Force,      # 已存在也重新下載
    [switch]$YtDlpOnly   # 只處理兩個小執行檔（yt-dlp / gallery-dl），略過體積大的 ffmpeg
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Split-Path -Parent $PSScriptRoot
$Bin  = Join-Path $Root 'bin'
$Tmp  = Join-Path $env:TEMP ("mdl_setup_" + [guid]::NewGuid().ToString('N').Substring(0,8))

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[X] $m" -ForegroundColor Red }

function Get-Redirected {
    param([string]$Url, [string]$OutFile)
    Info "下載 $Url"
    # curl.exe（Win10 1803+ 內建）支援斷點續傳與重試，大檔比 Invoke-WebRequest 穩
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -L --fail --retry 3 --retry-delay 2 -C - --connect-timeout 30 -o $OutFile $Url
        if ($LASTEXITCODE -ne 0) { throw "curl 下載失敗 (exit $LASTEXITCODE)" }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 900
    }
}

function Find-SevenZip {
    $c = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-LatestAsset {
    # ApiBase：GitHub 用 https://api.github.com；Codeberg（Forgejo）用 https://codeberg.org/api/v1，
    # 兩者的 releases API 路徑與欄位（tag_name / assets[].name / size / browser_download_url）相同。
    param([string]$Repo, [string]$Tag = 'latest', [string]$NamePattern,
          [string]$ApiBase = 'https://api.github.com')
    $api = if ($Tag -eq 'latest') { "$ApiBase/repos/$Repo/releases/latest" }
           else { "$ApiBase/repos/$Repo/releases/tags/$Tag" }
    $rel = Invoke-RestMethod -Uri $api -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'mdl-setup' }
    $asset = $rel.assets | Where-Object { $_.name -like $NamePattern } | Select-Object -First 1
    if (-not $asset) { throw "在 $Repo ($Tag) 找不到符合 $NamePattern 的檔案" }
    $sums = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
    [pscustomobject]@{
        Name = $asset.name; Url = $asset.browser_download_url; Size = $asset.size; Tag = $rel.tag_name
        SumsUrl = if ($sums) { $sums.browser_download_url } else { $null }
    }
}

function Get-ExpectedSha256 {
    # 從 release 附的 SHA256SUMS（格式：<hash>  <檔名>）取出指定檔案的雜湊；取不到回傳 $null
    param([string]$SumsUrl, [string]$FileName)
    if (-not $SumsUrl) { return $null }
    try {
        $text = (Invoke-WebRequest -Uri $SumsUrl -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'mdl-setup' }).Content
        if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
        foreach ($line in ($text -split "`r?`n")) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $FileName) { return $parts[0].ToLower() }
        }
    } catch {
        Warn "無法取得 SHA256SUMS：$($_.Exception.Message)"
    }
    return $null
}

New-Item -ItemType Directory -Force -Path $Bin, $Tmp | Out-Null

# ---------------------------------------------------------------- yt-dlp.exe
$ytdlp = Join-Path $Bin 'yt-dlp.exe'
if ((Test-Path $ytdlp) -and -not $Force) {
    Ok "yt-dlp.exe 已存在，跳過（要更新請跑：bin\yt-dlp.exe -U）"
} else {
    try {
        $a = Get-LatestAsset -Repo 'yt-dlp/yt-dlp' -NamePattern 'yt-dlp.exe'
        Info ("yt-dlp {0}  ({1:N1} MB)" -f $a.Tag, ($a.Size / 1MB))
        Get-Redirected -Url $a.Url -OutFile $ytdlp
        Ok "yt-dlp.exe 完成"
    } catch {
        Fail "yt-dlp 下載失敗：$($_.Exception.Message)"
        Warn "可手動下載 https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe 放到 $Bin"
    }
}

# ---------------------------------------------------------------- gallery-dl.exe
# 下載 IG / FB / X 貼文照片用（yt-dlp 只抓影片，會略過照片）。
# gallery-dl 已把開發與發行搬到 Codeberg，GitHub 上較新的 release 不再附執行檔，所以 Codeberg 優先。
$gdl = Join-Path $Bin 'gallery-dl.exe'
if ((Test-Path $gdl) -and -not $Force) {
    Ok "gallery-dl.exe 已存在，跳過（要更新請跑：mdl.bat update，或 bin\gallery-dl.exe -U）"
} else {
    $gdlSources = @(
        @{ Repo = 'mikf/gallery-dl'; ApiBase = 'https://codeberg.org/api/v1'; Label = 'Codeberg' },
        @{ Repo = 'mikf/gallery-dl'; ApiBase = 'https://api.github.com';      Label = 'GitHub' }
    )
    $gdlOk = $false
    foreach ($src in $gdlSources) {
        try {
            $a = Get-LatestAsset -Repo $src.Repo -ApiBase $src.ApiBase -NamePattern 'gallery-dl.exe'
            Info ("gallery-dl {0}  ({1:N1} MB, {2})" -f $a.Tag, ($a.Size / 1MB), $src.Label)
            # 先下載到 .download（可續傳），驗證通過才換成正式檔名，避免 bin\ 裡留下半個 exe
            $partial = "$gdl.download"
            Get-Redirected -Url $a.Url -OutFile $partial
            $expected = Get-ExpectedSha256 -SumsUrl $a.SumsUrl -FileName $a.Name
            if ($expected) {
                $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLower()
                if ($actual -ne $expected) {
                    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                    throw "SHA256 不符（預期 $expected，實際 $actual），已刪除下載檔"
                }
                Ok "gallery-dl.exe SHA256 驗證通過"
            } else {
                Warn "這個 release 沒有 SHA256SUMS，略過雜湊驗證"
            }
            Move-Item -LiteralPath $partial -Destination $gdl -Force
            Ok "gallery-dl.exe 完成"
            $gdlOk = $true
            break
        } catch {
            Warn "gallery-dl 來源 $($src.Label) 失敗：$($_.Exception.Message)"
        }
    }
    if (-not $gdlOk) {
        Fail "gallery-dl 下載失敗：影片功能不受影響，但無法下載 IG / FB / X 貼文照片（images 指令）。"
        Warn "可手動下載 https://codeberg.org/mikf/gallery-dl/releases 的 gallery-dl.exe 放到 $Bin"
    }
}

if ($YtDlpOnly) { Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue; return }

# ---------------------------------------------------------------- ffmpeg
$ffmpeg  = Join-Path $Bin 'ffmpeg.exe'
$ffprobe = Join-Path $Bin 'ffprobe.exe'
if ((Test-Path $ffmpeg) -and (Test-Path $ffprobe) -and -not $Force) {
    Ok "ffmpeg.exe / ffprobe.exe 已存在，跳過"
} else {
    $archive = $null
    $got = $false

    # 有 7-Zip 就優先抓 .7z（約 33MB，zip 版要 106MB）
    $sevenZip = Find-SevenZip
    $sources = @()
    if ($sevenZip) {
        Info "偵測到 7-Zip，改抓體積較小的 .7z"
        $sources += @{ Repo = 'GyanD/codexffmpeg'; Pattern = '*essentials_build.7z'; Ext = '.7z' }
    }
    $sources += @{ Repo = 'GyanD/codexffmpeg'; Pattern = '*essentials_build.zip'; Ext = '.zip' }
    $sources += @{ Repo = 'BtbN/FFmpeg-Builds'; Tag = 'latest'; Pattern = 'ffmpeg-master-latest-win64-gpl.zip'; Ext = '.zip' }

    foreach ($src in $sources) {
        try {
            $tag = if ($src.Tag) { $src.Tag } else { 'latest' }
            $a = Get-LatestAsset -Repo $src.Repo -Tag $tag -NamePattern $src.Pattern
            $archive = Join-Path $Tmp ('ffmpeg' + $src.Ext)
            Info ("ffmpeg {0}  ({1:N1} MB) - 檔案較大請耐心等候" -f $a.Name, ($a.Size / 1MB))
            Get-Redirected -Url $a.Url -OutFile $archive
            $got = $true
            break
        } catch {
            Warn "來源 $($src.Repo) $($src.Ext) 失敗：$($_.Exception.Message)"
        }
    }

    if (-not $got) {
        Fail "ffmpeg 下載失敗。沒有 ffmpeg 仍可下載單一格式影片，但無法合併高畫質影音、也無法轉 mp3。"
    } else {
        Info "解壓縮中..."
        $ex = Join-Path $Tmp 'x'
        New-Item -ItemType Directory -Force -Path $ex | Out-Null
        if ($archive -like '*.7z') {
            & $sevenZip x $archive "-o$ex" -y | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "7-Zip 解壓縮失敗 (exit $LASTEXITCODE)" }
        } else {
            Expand-Archive -LiteralPath $archive -DestinationPath $ex -Force
        }
        foreach ($exe in @('ffmpeg.exe', 'ffprobe.exe')) {
            $found = Get-ChildItem -Path $ex -Filter $exe -Recurse -File | Select-Object -First 1
            if ($found) {
                Copy-Item $found.FullName (Join-Path $Bin $exe) -Force
                Ok "$exe 完成"
            } else {
                Fail "壓縮檔內找不到 $exe"
            }
        }
    }
}

Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 驗證
Write-Host ""
Info "驗證："
foreach ($exe in @('yt-dlp.exe', 'gallery-dl.exe', 'ffmpeg.exe', 'ffprobe.exe')) {
    $p = Join-Path $Bin $exe
    if (Test-Path $p) {
        Write-Host ("    {0,-14} {1,8:N1} MB" -f $exe, ((Get-Item $p).Length / 1MB)) -ForegroundColor Green
    } else {
        Write-Host ("    {0,-14} 缺少" -f $exe) -ForegroundColor Red
    }
}
Write-Host ""
Ok "設定完成，可以關掉這個視窗，改執行「影音下載器.bat」"
