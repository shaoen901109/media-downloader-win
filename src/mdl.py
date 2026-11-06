# -*- coding: utf-8 -*-
"""
mdl.py — 免安裝影音下載器核心引擎（yt-dlp.exe 的包裝層）

設計原則：
  * 只使用 Python 標準函式庫（不得 import 第三方套件），目標 Python 3.10+。
  * 同時服務三種呼叫者：
      1. 人類（CLI 子指令，進度即時輸出）
      2. PowerShell GUI（--json，stdout 只會有一份 JSON）
      3. LLM agent / MCP server（import 本模組，使用 TOOL_SCHEMAS 與 call_tool）
  * 所有 yt-dlp 參數都從 config/profiles.json 讀取，不寫死（讀不到才用內建預設值）。

檔案分區：
  1. 常數與設定載入
  2. 執行檔尋找（yt-dlp / gallery-dl / ffmpeg）
  3. 子行程執行與錯誤判讀
  4. 參數組裝
  5. 核心動作（info / formats / download / images / batch / doctor / update）
  6. Agent 介面（TOOL_SCHEMAS / call_tool）
  7. CLI
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

__all__ = [
    "TOOL_SCHEMAS",
    "call_tool",
    "download",
    "download_images",
    "get_info",
    "list_formats",
    "batch_download",
    "doctor",
    "login_browser",
]

# ==========================================================================
# 1. 常數與設定載入
# ==========================================================================

# <root> = 本檔案上一層的上一層，例如 E:\...\影音下載器
ROOT = Path(__file__).resolve().parents[1]
BIN_DIR = ROOT / "bin"
CONFIG_PATH = ROOT / "config" / "profiles.json"
DEFAULT_OUT_DIR = ROOT / "downloads"

SETUP_HINT = "請先執行「首次設定.bat」下載 yt-dlp.exe / ffmpeg.exe 到 bin 資料夾。"

# 讀不到 config\profiles.json 時使用的內建預設值（與該檔內容一致）
DEFAULT_PROFILES: dict = {
    "common": [
        "--newline", "--no-warnings", "--ignore-config",
        "--concurrent-fragments", "4",
        "--retries", "10", "--fragment-retries", "10",
        "--socket-timeout", "20",
        "--no-overwrites", "--windows-filenames",
    ],
    "video": {
        "format_best": "bv*+ba/b",
        "format_capped": "bv*[height<={H}]+ba/b[height<={H}]/bv*+ba/b",
        "sort": "ext:mp4:m4a",
        "extra": ["--merge-output-format", "mp4", "--embed-metadata"],
    },
    "audio": {
        "format": "ba/b",
        "extra": ["-x", "--audio-format", "mp3", "--embed-metadata", "--embed-thumbnail"],
    },
    "output_template": "%(title).120B [%(id)s].%(ext)s",
    "output_template_playlist":
        "%(playlist_title,playlist_id|)s/%(playlist_index|)s%(title).100B [%(id)s].%(ext)s",
    "quality_choices": ["best", "2160", "1440", "1080", "720", "480", "360"],
    "audio_quality_choices": ["0", "320K", "256K", "192K", "128K"],
    "bulk_sleep": {"mean": 2.0, "min": 0.0, "max": 4.0},
}

# metadata print-to-file 用的欄位分隔符（極不可能出現在標題中）
_META_SEP = "|@|"
_META_TEMPLATE = (
    "after_move:%(title|)s" + _META_SEP +
    "%(uploader,channel,uploader_id|)s" + _META_SEP +
    "%(duration|)s" + _META_SEP +
    "%(extractor_key|)s" + _META_SEP +
    "%(webpage_url|)s" + _META_SEP +
    "%(width|)s" + _META_SEP +
    "%(height|)s"
)

# --- Windows 路徑長度預算（見 _path_budget_args） ---
# Windows 預設的 MAX_PATH 是 260 個字元（LongPathsEnabled=0 時無法突破）。
_MAX_PATH = 260
# yt-dlp 下載中的暫存檔後綴可能很長，例如
#   .fhls-audio-128000-Audio.mp4.part-Frag12.part （約 45 字元）
# 預算一定要先扣掉，否則「最終檔名沒超過」但「下載中的暫存檔超過」就會失敗。
_TEMP_SUFFIX_RESERVE = 50
# 檔名預算的下限，避免路徑太深時把檔名砍到完全無法辨識
_MIN_NAME_BUDGET = 40
# 檔名裡除了標題以外的固定成本（" [影片ID].副檔名" 之類）
_TITLE_TAIL_RESERVE = 30

_PROFILES_CACHE: dict | None = None


def load_profiles(force: bool = False) -> dict:
    """載入 config\\profiles.json；缺鍵時以 DEFAULT_PROFILES 補齊。"""
    global _PROFILES_CACHE
    if _PROFILES_CACHE is not None and not force:
        return _PROFILES_CACHE

    profiles = json.loads(json.dumps(DEFAULT_PROFILES))  # 深拷貝
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
            user_cfg = json.load(fh)
        for key, value in user_cfg.items():
            if key.startswith("_"):  # _comment 之類的註解欄位略過
                continue
            if isinstance(value, dict) and isinstance(profiles.get(key), dict):
                profiles[key].update(value)
            else:
                profiles[key] = value
    except Exception:
        # 設定檔不存在或格式錯誤 → 靜默使用內建預設值（doctor 會回報）
        pass

    _PROFILES_CACHE = profiles
    return profiles


def _envelope(action: str, url=None, **kwargs) -> dict:
    """建立統一 JSON 信封，缺值一律 null。"""
    env = {
        "ok": True,
        "action": action,
        "url": url,
        "site": None,
        "title": None,
        "duration": None,
        "uploader": None,
        "files": [],
        "output_dir": None,
        "elapsed_sec": None,
        "attempts": 0,
        "warnings": [],
        "error": None,
        "hint": None,
        "log_tail": None,
    }
    env.update(kwargs)
    return env


def _fail(env: dict, error: str, hint: str | None = None, stderr: str = "") -> dict:
    """把信封標記為失敗，並填入精簡錯誤、hint 與 stderr 尾巴。"""
    env["ok"] = False
    env["error"] = error
    env["hint"] = hint
    if stderr:
        env["log_tail"] = _log_tail(stderr)
    return env


# ==========================================================================
# 2. 執行檔尋找（yt-dlp / ffmpeg）
# ==========================================================================

def _which(names: list[str]) -> Path | None:
    for name in names:
        found = shutil.which(name)
        if found:
            return Path(found)
    return None


def find_ytdlp() -> Path | None:
    """先找 <root>\\bin\\yt-dlp.exe，再找 PATH 上的 yt-dlp。"""
    local = BIN_DIR / "yt-dlp.exe"
    if local.is_file():
        return local
    local_nix = BIN_DIR / "yt-dlp"
    if local_nix.is_file():
        return local_nix
    return _which(["yt-dlp.exe", "yt-dlp"])


def find_ffmpeg() -> Path | None:
    """先找 <root>\\bin\\ffmpeg.exe，再找 PATH 上的 ffmpeg。"""
    local = BIN_DIR / "ffmpeg.exe"
    if local.is_file():
        return local
    local_nix = BIN_DIR / "ffmpeg"
    if local_nix.is_file():
        return local_nix
    return _which(["ffmpeg.exe", "ffmpeg"])


def find_gallery_dl() -> Path | None:
    """先找 <root>\\bin\\gallery-dl.exe，再找 PATH 上的 gallery-dl（下載貼文照片用）。"""
    local = BIN_DIR / "gallery-dl.exe"
    if local.is_file():
        return local
    local_nix = BIN_DIR / "gallery-dl"
    if local_nix.is_file():
        return local_nix
    return _which(["gallery-dl.exe", "gallery-dl"])


def find_ffprobe() -> Path | None:
    local = BIN_DIR / "ffprobe.exe"
    if local.is_file():
        return local
    local_nix = BIN_DIR / "ffprobe"
    if local_nix.is_file():
        return local_nix
    return _which(["ffprobe.exe", "ffprobe"])


def _ffmpeg_location_args() -> tuple[list[str], list[str]]:
    """回傳 (要附加的參數, 警告訊息清單)。找不到 ffmpeg 仍允許執行。"""
    ffmpeg = find_ffmpeg()
    if ffmpeg:
        return ["--ffmpeg-location", str(ffmpeg.parent)], []
    return [], [
        "找不到 ffmpeg：無法合併分離的影音軌，也無法轉檔 mp3。"
        "實測 YouTube 目前已經不再提供「影音已合併」的格式，所以沒有 ffmpeg 時 YouTube 一定會失敗。"
        + SETUP_HINT
    ]


# ==========================================================================
# 3. 子行程執行與錯誤判讀
# ==========================================================================

def _no_window_kwargs() -> dict:
    """Windows 下避免彈出黑色主控台視窗；非 Windows 平台自動忽略。"""
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    return {"creationflags": flags} if flags else {}


def _drain(pipe, sink: list[str], echo_to) -> None:
    """逐行讀取 bytes、以 utf-8/replace 解碼（Windows 中文標題會爆），必要時即時輸出。"""
    try:
        for raw in iter(pipe.readline, b""):
            line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
            sink.append(line)
            if echo_to is not None:
                print(line, file=echo_to, flush=True)
    except Exception:
        pass
    finally:
        try:
            pipe.close()
        except Exception:
            pass


def run_cmd(cmd: list[str], echo_stdout: bool = False, echo_stderr: bool = False,
            timeout: int | None = None, stdout_file: str | None = None) -> tuple[int, str, str]:
    """
    執行子行程，回傳 (returncode, stdout_text, stderr_text)。
    stdout 用 Popen + readline 串流（--newline 讓 yt-dlp 每行一個進度），
    stderr 另開執行緒收集避免管線塞住造成 deadlock。
    stdout_file：把 stdout 原封不動寫進這個檔案（覆寫），不放進記憶體、也不 echo；回傳的 stdout_text 是空字串
    （yt-dlp -j 一支影片就是幾百 KB 的 JSON，播放清單會到上百 MB）。
    """
    out_handle = None
    try:
        if stdout_file:
            out_handle = open(stdout_file, "wb")
        proc = subprocess.Popen(
            cmd,
            stdout=out_handle if out_handle is not None else subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            **_no_window_kwargs(),
        )
    except Exception as exc:  # 執行檔不存在、被佔用、權限不足…
        if out_handle is not None:
            out_handle.close()
        return -1, "", f"無法啟動子行程：{exc}"

    out_lines: list[str] = []
    err_lines: list[str] = []
    err_thread = threading.Thread(
        target=_drain,
        args=(proc.stderr, err_lines, sys.stderr if echo_stderr else None),
        daemon=True,
    )
    err_thread.start()

    # 主執行緒負責 stdout（進度），這樣 echo 的順序才自然
    if out_handle is None:
        _drain(proc.stdout, out_lines, sys.stdout if echo_stdout else None)

    try:
        rc = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        rc = -1
        err_lines.append("子行程逾時，已強制結束。")
    finally:
        if out_handle is not None:
            try:
                out_handle.close()
            except Exception:
                pass
    err_thread.join(timeout=5)

    return rc, "\n".join(out_lines), "\n".join(err_lines)


def _log_tail(text: str, lines: int = 15) -> list[str]:
    """取 stderr 最後 N 行（去掉空行）。"""
    rows = [ln for ln in (text or "").splitlines() if ln.strip()]
    return rows[-lines:]


def compact_error(stderr: str, stdout: str = "") -> str:
    """從一堆輸出中萃取最有意義的一行錯誤，而不是整坨 traceback。"""
    blob = (stderr or "") + "\n" + (stdout or "")
    rows = [ln.strip() for ln in blob.splitlines() if ln.strip()]

    errors = [ln for ln in rows if ln.startswith("ERROR:") or "ERROR:" in ln]
    if errors:
        msg = errors[-1]
    elif rows:
        # 避開 traceback 的框架行，取最後一行有意義的訊息
        meaningful = [ln for ln in rows if not ln.startswith(("File \"", "Traceback", "  "))]
        msg = meaningful[-1] if meaningful else rows[-1]
    else:
        msg = "yt-dlp 執行失敗但沒有輸出任何訊息。"

    msg = re.sub(r"\s+", " ", msg).strip()
    return msg[:500]


def _impersonate_unsupported(stderr: str) -> bool:
    """判斷失敗是否肇因於這份 yt-dlp 不支援 --impersonate（避免誤導性錯誤）。"""
    low = (stderr or "").lower()
    if "impersonate" not in low:
        return False
    patterns = (
        "no such option",
        "unrecognized argument",
        "unsupported impersonate target",
        "impersonate target",
        "not available",
        "not supported",
        "curl_cffi",
        "invalid",
    )
    return any(p in low for p in patterns)


# --- cookie 取用失敗（措辭取自 yt-dlp 的 yt_dlp/cookies.py）-----------------
# 這類錯誤發生在「還沒開始連網」的階段：yt-dlp 連 cookie 都沒讀到就放棄了。
# 它跟「這個內容需要登入」完全是兩回事，卻含有 cookie 字樣，會被底下的登入規則
# 誤判成「請加上 --cookies-from-browser」——但使用者根本就是加了才會走到這裡。
# 所以這條規則必須排在所有規則之前。
_COOKIE_DB_RE = re.compile(
    "|".join((
        r"could not copy .{0,40}cookie",          # Could not copy Chrome cookie database（檔案被鎖住）
        r"cookies? database",                     # could not find chrome cookies database / unsupported ... version
        r"failed to (decrypt|read) .{0,40}cookie",
        r"could not decrypt.{0,40}cookie",        # Could not decrypt and skipped N cookies
        r"failed to decrypt with dpapi",          # Chrome v20 app-bound 加密
        r"failed to (read from|read secret from) keyring",
        r"secretstorage not available",
        r"unsupported keyring",
        r"kwallet-query",
        r"cannot extract cookies from .{0,40}sqlite3",
        r"failed to load cookies",
        r"could not read containers\.json",
        r"could not find firefox container",
        r"(permission denied|errno 13).{0,60}cookie",
        r"cookie.{0,60}(permission denied|errno 13)",
    )),
    re.IGNORECASE,
)
# cookie「來源指定錯了」——檔案不存在／格式不對／瀏覽器名稱不認得
_COOKIE_SOURCE_RE = re.compile(
    "|".join((
        r"unsupported browser",
        r"unknown browser",
        r"does not support profiles",
        r"netscape format",                       # cookies.txt 格式不對（例如存成 JSON）
        r"cookies file",
        r"(no such file or directory|errno 2).{0,60}cookies",
        r"cookies.{0,60}(no such file or directory|errno 2)",
    )),
    re.IGNORECASE,
)
_COOKIE_BROWSER_RE = re.compile(
    r"(?:could not copy|could not find|extract cookies from)\s+(\w+)\s+cookie", re.IGNORECASE)


def _cookie_failure_kind(text: str) -> str | None:
    """回傳 'db'（讀不到／解不開 cookie 資料庫）、'source'（來源指定錯誤）或 None。"""
    blob = text or ""
    if _COOKIE_DB_RE.search(blob):
        return "db"
    if _COOKIE_SOURCE_RE.search(blob):
        return "source"
    return None


def _cookie_browser_name(text: str) -> str:
    """從錯誤訊息裡撈出瀏覽器名稱（撈不到就用泛稱）。"""
    match = _COOKIE_BROWSER_RE.search(text or "")
    if not match:
        return "該瀏覽器"
    name = match.group(1)
    return name[:1].upper() + name[1:].lower()


def _login_browser_tip(images: bool = False) -> str:
    """「需要登入」時的建議：登入瀏覽器優先，--cookies-from-browser firefox / --cookies 為替代。"""
    file_note = "（Netscape 格式，agent：cookies_file）" if images else "（Netscape 格式）"
    return ("建議用登入瀏覽器：執行「登入瀏覽器.bat」在那個視窗登入這個網站一次，之後加 --login-browser"
            "（agent：use_login_browser=true），平常用的 Chrome 不必關；"
            f"其他做法：--cookies-from-browser firefox，或 --cookies cookies.txt{file_note}。")


# 已經用登入瀏覽器的 cookie 卻仍被要求登入 → 幾乎都是「登入瀏覽器還沒登入這個網站」
_LB_NOT_LOGGED_IN_TIP = (
    "本次已使用登入瀏覽器的 cookie，網站卻仍要求登入：登入瀏覽器多半還沒登入這個網站（或登入已過期），"
    "也可能是該帳號無權觀看。請執行「登入瀏覽器.bat」（agent：mdl_login_browser action=open，url 帶這個網址），"
    "在那個視窗登入並確認看得到內容後再試。")
_LB_SHORT_TIP = "改以登入狀態下載（--login-browser，agent：use_login_browser=true；先用「登入瀏覽器.bat」登入）"


def _cookie_failure_hint(kind: str, text: str) -> str:
    if kind == "source":
        return ("指定的 cookie 來源本身無法使用（不是「需要登入」）："
                "請確認 --cookies 指向的 cookies.txt 確實存在、而且是 Netscape 格式（不是 JSON）；"
                "若用 --cookies-from-browser，瀏覽器名稱只能是 "
                "chrome / edge / firefox / brave / opera / vivaldi / chromium / safari。"
                "也可以改用登入瀏覽器（--login-browser，agent：use_login_browser=true）。")
    browser = _cookie_browser_name(text)
    return (f"偵測到瀏覽器 cookie 資料庫無法讀取（{browser}正在執行時會鎖住資料庫，"
            "新版 Chrome/Edge 的 app-bound 加密也可能讓 cookie 解不開）。"
            "建議改用登入瀏覽器：執行「登入瀏覽器.bat」在那個視窗登入一次，之後改加 --login-browser"
            f"（agent：use_login_browser=true），{browser}不必關。"
            f"其他做法：先「完全關閉」{browser}（含背景常駐行程，可到工作管理員確認）再重跑、"
            "改用 --cookies-from-browser firefox，或用瀏覽器擴充套件匯出 cookies.txt 搭配 --cookies。"
            "注意：這不是「沒加 cookie 參數」，再加一次同樣的參數也不會成功。")


# --- 只有照片、沒有影片的貼文（yt-dlp 只下載影片）--------------------------
# 實測訊息（yt-dlp 2026.08.19）：
#   IG 單張照片貼文：ERROR: [Instagram] <id>: There is no video in this post
#   IG 全照片輪播：  ERROR: [Instagram] <id>: No video formats found!（每一格各一行）
#   X 照片推文：     ERROR: [twitter] <id>: No video could be found in this tweet
#   FB 照片網址：    ERROR: Unsupported URL: https://www.facebook.com/photo/?fbid=...
#   FB 純照片貼文：  ERROR: [facebook] pfbid...: Unable to download webpage: HTTP Error 404
#   FB 純照片貼文（2026-10 實測，/posts/、permalink.php、story.php 都一樣）：
#                    ERROR: [facebook] <id>: Cannot parse data; please report this issue on ...
#   FB 分享短網址：  ERROR: Unsupported URL: https://www.facebook.com/share/p/<代碼>/...
_IMAGES_TOOL_TIP = ("請改用 images 指令（mdl.bat images \"<網址>\"）或 agent 工具 "
                    "mdl_download_images 下載照片（整則貼文，輪播裡的影片也會一起抓）。")
_SOCIAL_TAG_RE = re.compile(r"\[(instagram|twitter|facebook)[^\]]*\]", re.IGNORECASE)
_FB_PHOTO_URL_RE = re.compile(
    r"facebook\.com/(?:photo(?:\.php)?/?\?|[^/\s]+/photos/|media/set/?\?|share/p/)", re.IGNORECASE)


def _photo_post_kind(text: str) -> str | None:
    """
    判斷 yt-dlp 的失敗是不是「這則貼文只有照片」。
    回傳 'no_video'（確定沒有影片）、'fb_photo_url'（FB 照片／分享貼文網址，yt-dlp 不支援）、
    'fb_404'（FB 貼文 404）、'fb_no_data'（FB 貼文「Cannot parse data」；這兩種都是純照片貼文
    實測會出現的反應，但不保證）或 None。
    """
    low = (text or "").lower()
    if "there is no video in this post" in low or "no video could be found in this tweet" in low:
        return "no_video"
    if "no video formats found" in low and _SOCIAL_TAG_RE.search(low):
        return "no_video"
    if "unsupported url" in low and _FB_PHOTO_URL_RE.search(low):
        return "fb_photo_url"
    if "http error 404" in low and re.search(r"\[facebook[^\]]*\]", low):
        return "fb_404"
    if "cannot parse data" in low and re.search(r"\[facebook[^\]]*\]", low):
        return "fb_no_data"
    return None


_NO_VIDEO_SKIP_NOTE = "這則貼文（或其中幾格）只有照片、沒有影片，--impersonate 重試也不會有影片，已略過重試。"
_NO_VIDEO_NO_PHOTO_NOTE = "這則貼文沒有影片，--impersonate 重試也不會有，已略過重試。"
_FB_PHOTO_URL_SKIP_NOTE ="這是 Facebook 的照片／貼文網址，yt-dlp 沒有對應的影片抽取器，--impersonate 重試也一樣，已略過重試。"
_FB_PHOTOS_FOUND_SKIP_NOTE = "yt-dlp 抓不到這則 Facebook 貼文的影片，但貼文裡有照片（純照片貼文就是這個反應），已略過 --impersonate 重試。"


def _skip_retry_reason(stderr: str, stdout: str = "") -> str | None:
    """
    判斷第一次的失敗屬不屬於「重試必然再失敗」，是的話回傳要記在 warnings 的說明。

    1. cookie 取用失敗：yt-dlp 是在連網之前就因為讀不到／解不開 cookie 而放棄，
       第二次重試只是多加 --impersonate（TLS 指紋），cookie 來源一模一樣，結果必然相同，
       只會白白多花一次啟動與連線的時間（實測約多 7 秒）。
    2. 貼文本來就只有照片（IG／X）：網站已經回應了「沒有影片」，換 TLS 指紋也變不出影片。
    3. FB 照片網址／分享貼文短網址：yt-dlp 沒有對應的抽取器（Unsupported URL），與 TLS 指紋無關。
    """
    blob = (stderr or "") + "\n" + (stdout or "")
    if _cookie_failure_kind(blob):
        return ("cookie 來源本身就讀不到（失敗發生在連網之前，與網站無關），"
                "--impersonate 重試必然同樣失敗，已略過重試以免浪費時間。")
    kind = _photo_post_kind(blob)
    if kind == "no_video":
        return _NO_VIDEO_SKIP_NOTE
    if kind == "fb_photo_url":
        return _FB_PHOTO_URL_SKIP_NOTE
    return None


def build_hint(stderr: str, stdout: str = "", has_cookies: bool = False,
               login_browser: bool = False) -> str | None:
    """
    依 stderr 內容給出可行動的建議。

    has_cookies：本次執行是否已經帶了 --cookies-from-browser / --cookies / --login-browser。
    帶了還叫使用者「加上 cookie 參數」是誤導，所以相關建議要改口徑。
    login_browser：cookie 來自登入瀏覽器 → 仍要求登入時，多半是登入瀏覽器沒登入該網站。
    """
    has_cookies = bool(has_cookies or login_browser)
    blob = (stderr or "") + "\n" + (stdout or "")
    low = blob.lower()

    # 最優先：cookie 根本沒讀成功（訊息裡有 cookie 字樣，但原因完全不是「需要登入」）
    cookie_kind = _cookie_failure_kind(blob)
    if cookie_kind:
        return _cookie_failure_hint(cookie_kind, blob)

    if "ffmpeg not found" in low or "ffmpeg is not installed" in low or "ffmpeg-location" in low:
        return ("缺少 ffmpeg：請執行「首次設定.bat」把 ffmpeg.exe 放進 bin 資料夾，"
                "否則無法合併高畫質影音軌、轉 mp3 或擷取片段。")

    # 只有照片的貼文：yt-dlp 的訊息看起來像抽取器壞掉（還叫人去回報 bug），其實只是沒有影片
    photo_kind = _photo_post_kind(blob)
    if photo_kind == "no_video":
        return "這則貼文只有照片、沒有影片（yt-dlp 只下載影片，照片會被略過）：" + _IMAGES_TOOL_TIP
    if photo_kind == "fb_photo_url":
        return "這是 Facebook 的照片／貼文網址，yt-dlp 只支援影片：" + _IMAGES_TOOL_TIP
    if photo_kind in ("fb_404", "fb_no_data"):
        if login_browser:
            login_tip = "若確定是影片貼文：" + _LB_NOT_LOGGED_IN_TIP
        elif has_cookies:
            login_tip = "本次已經帶了 cookie，若確定是影片貼文，多半是 cookie 過期或該帳號看不到這則貼文。"
        else:
            login_tip = "若確定是影片貼文，可能是貼文不公開或需要登入：" + _login_browser_tip()
        what = "HTTP 404" if photo_kind == "fb_404" else "Cannot parse data，讀不到影片資料"
        return (f"yt-dlp 抓不到這則 Facebook 貼文（{what}）。實測純照片貼文就會出現這個錯誤，"
                "如果這則貼文只有照片，" + _IMAGES_TOOL_TIP + login_tip)

    # 路徑過長（Windows MAX_PATH=260）或磁碟寫不進去。
    # 真正的原因埋在 log 裡的 "unable to open for writing"，最後才浮出
    # "The downloaded file is empty" 這種毫無線索的訊息，所以要優先攔截。
    path_keys = (
        "unable to open for writing", "the downloaded file is empty",
        "no such file or directory", "filename too long", "file name too long",
        "path too long", "errno 2", "errno 36", "errno 28", "no space left",
    )
    if any(k in low for k in path_keys):
        return ("輸出路徑可能過長（Windows 上限 260 字元，下載中的暫存檔還會再加約 45 字元）"
                "或磁碟空間不足：請改用較短的輸出資料夾路徑（例如 D:\\dl），或清出磁碟空間。")

    if "unsupported url" in low:
        return "yt-dlp 不支援這個網站或這種網址；請確認網址是影片頁面本身，或改用其他來源。"

    # Instagram 不讓未登入者列舉帳號／標籤／限時動態的內容，錯誤訊息卻長得像抽取器壞掉。
    ig_listing = ("instagram:user", "instagram:tag", "instagram:story", "instagram:user:")
    if any(k in low for k in ig_listing) or (
            "instagram" in low and "unable to extract data" in low):
        ig_head = ("Instagram 不允許未登入者列舉帳號／標籤／限時動態的內容（訊息看起來像抽取器失效，"
                   "但跑 update 沒有用）：")
        if login_browser:
            return ig_head + _LB_NOT_LOGGED_IN_TIP
        if has_cookies:
            return (ig_head + "本次已經帶了 cookie，所以問題多半出在 cookie 已過期、"
                    "或那個瀏覽器設定檔其實沒登入 IG／該帳號無權觀看。"
                    "請在同一個瀏覽器裡實際打開這個網址確認看得到內容，必要時重新登入後再試。")
        return (ig_head + "需要登入 IG。" + _login_browser_tip()
                + "單篇貼文或 Reel 的網址通常不需要登入就能下載。")

    login_keys = (
        "sign in", "log in", "login required", "private video", "this video is private",
        "members-only", "member-only", "requires authentication", "age-restricted",
        "confirm your age", "not a bot", "use --cookies", "cookies", "paid members",
        "subscribe to this channel", "login to view",
        # IG 限制級／限定對象的內容（實測：未登入抓不到，登入瀏覽器登入後就能下載）
        "isn't available to everyone", "can't be seen by certain audiences",
    )
    if any(k in low for k in login_keys):
        if login_browser:
            return _LB_NOT_LOGGED_IN_TIP
        if has_cookies:
            return ("本次已經帶了 cookie 卻仍被要求登入／驗證：這份 cookie 可能已過期，"
                    "或該帳號無權觀看此內容。請先在同一個瀏覽器（同一個設定檔）實際打開這個網址，"
                    "確認登入狀態下真的看得到內容；必要時重新登入後再試，或改用剛匯出的 cookies.txt。")
        return "此內容需要登入或年齡驗證：" + _login_browser_tip()

    if "429" in low or "too many requests" in low or "rate limit" in low:
        if has_cookies:
            return "被網站限流（HTTP 429）：請等幾分鐘再試（已帶 cookie，換參數沒有用）。"
        return f"被網站限流（HTTP 429）：請稍後再試，或{_LB_SHORT_TIP}降低被擋機率。"

    if "403" in low or "forbidden" in low:
        if has_cookies:
            return ("被網站拒絕（HTTP 403）：請稍後再試；已帶 cookie 的情況下，"
                    "多半是 cookie 過期或網址簽章失效，先跑 mdl.py update 更新 yt-dlp 再重試。")
        return (f"被網站拒絕（HTTP 403）：請稍後再試，或{_LB_SHORT_TIP}；"
                "若持續失敗，先跑 mdl.py update 更新 yt-dlp。")

    outdated_keys = (
        "out of date", "outdated", "update to the latest version", "yt-dlp is out of date",
        "please report this issue", "nightly", "unable to extract", "extractor",
    )
    if any(k in low for k in outdated_keys):
        return "抽取器可能已失效或 yt-dlp 版本過舊：請執行 mdl.py update 更新後再試。"

    if ("http error 404" in low or "unavailable" in low
            or "has been removed" in low or "does not exist" in low
            or "no longer available" in low):
        return "網址無效、影片已被移除或設為不公開：請確認網址是否正確、能不能在瀏覽器開啟。"

    if "unable to download" in low or "network" in low or "timed out" in low:
        return "網路連線問題：請確認網路或代理設定後重試。"

    return None


def _ytdlp_or_fail(env: dict) -> Path | None:
    """取得 yt-dlp 路徑；找不到就直接把 env 標記成失敗。"""
    exe = find_ytdlp()
    if exe is None:
        _fail(env,
              f"找不到 yt-dlp：{BIN_DIR / 'yt-dlp.exe'} 不存在，PATH 上也沒有 yt-dlp。",
              SETUP_HINT)
        return None
    return exe


# ==========================================================================
# 4. 參數組裝
# ==========================================================================

_CLIP_RE = re.compile(r"^\s*(\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?|\d+(?:\.\d+)?)\s*-\s*"
                      r"(\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?|\d+(?:\.\d+)?)\s*$")


class OptionError(ValueError):
    """使用者給的選項不合法（可直接轉成 ok:false 的錯誤訊息）。"""


def _norm_opts(opts: dict) -> dict:
    """把散落的 kwargs 正規化成一份完整選項（同時接受 out / out_dir 兩種鍵名）。"""
    out = {
        "out_dir": opts.get("out_dir") or opts.get("out") or None,
        "quality": str(opts.get("quality") or "best"),
        "audio_quality": str(opts.get("audio_quality") or "0"),
        "playlist": bool(opts.get("playlist") or False),
        "clip": opts.get("clip") or None,
        "subs": opts.get("subs") or None,
        "cookies_from_browser": opts.get("cookies_from_browser") or None,
        "cookies": opts.get("cookies") or None,
        # 內部旗標：cookies 是 _with_login_browser 從登入瀏覽器匯出的暫存檔（影響 hint 口徑）
        "login_browser_used": bool(opts.get("_login_browser") or False),
        "name": opts.get("name") or None,
        "extra_args": list(opts.get("extra_args") or []),
        "quiet": bool(opts.get("quiet") or False),
        "json_mode": bool(opts.get("json_mode") or False),
        # 影片模式：IG / FB / X 貼文的照片一併下載（預設開；CLI --no-photos、agent include_photos=false 關閉）
        "include_photos": True if opts.get("include_photos") is None else _truthy(opts.get("include_photos")),
    }
    return out


def _resolve_out_dir(opts: dict) -> Path:
    """決定輸出資料夾（預設 <root>\\downloads），不存在就建立。"""
    target = Path(opts["out_dir"]).expanduser() if opts["out_dir"] else DEFAULT_OUT_DIR
    target = target.resolve()
    target.mkdir(parents=True, exist_ok=True)
    return target


_TITLE_TRUNC_RE = re.compile(r"%\(title\)\.(\d+)([BsU]?)")


def _path_budget_args(out_dir: Path) -> tuple[list[str], int, list[str]]:
    """
    依輸出資料夾的絕對路徑長度，算出這次下載可用的檔名預算。
    回傳 (要附加的 yt-dlp 參數, 檔名預算字元數, 警告清單)。

    重點（實測）：yt-dlp 的 --trim-filenames 是對「整條路徑」做截斷，不是只截檔名，
    所以傳進去的數字必須是「資料夾長度 + 檔名預算」，而且一定要大於資料夾長度，
    否則會把資料夾也一起砍掉，檔案就跑到別的地方去了。
    """
    if os.name != "nt":
        return [], _MAX_PATH, []

    warnings: list[str] = []
    dir_len = len(str(out_dir))
    prefix = dir_len + 1  # 含路徑分隔符
    budget = _MAX_PATH - _TEMP_SUFFIX_RESERVE - prefix
    if budget < _MIN_NAME_BUDGET:
        warnings.append(
            f"輸出資料夾路徑已經有 {dir_len} 個字元，逼近 Windows 的 260 字元上限："
            "檔名只能留最短的長度，仍有可能下載失敗，建議改用較短的輸出資料夾（例如 D:\\dl）。")
        budget = _MIN_NAME_BUDGET
    return ["--trim-filenames", str(prefix + budget)], budget, warnings


def _cap_title_in_template(template: str, name_budget: int) -> str:
    """
    把輸出樣板裡 %(title).NNNB 的截斷長度壓進檔名預算內（只會變小，不會變大）。
    --trim-filenames 只是最後的保險；真正可靠的是一開始就不要產生過長的標題。
    """
    cap = max(20, name_budget - _TITLE_TAIL_RESERVE)

    def _repl(match: re.Match) -> str:
        try:
            current = int(match.group(1))
        except ValueError:
            return match.group(0)
        return f"%(title).{min(current, cap)}{match.group(2)}"

    return _TITLE_TRUNC_RE.sub(_repl, template)


def _inject_width_fallback(fmt: str, quality: str) -> str:
    """
    直式影片（例如 IG Reel 892x1584）的短邊是寬度，height<=N 會篩不到任何格式，
    結果直接掉到完全沒有上限的 fallback。這裡在「無上限 fallback」之前插入以寬度為準的備選。
    """
    parts = [p for p in fmt.split("/") if p]
    extra = [f"bv*[width<={quality}]+ba", f"b[width<={quality}]"]
    if any(e in parts for e in extra):
        return fmt
    index = next((i for i, p in enumerate(parts) if "<=" not in p), len(parts))
    return "/".join(parts[:index] + extra + parts[index:])


def build_download_args(mode: str, opts: dict, out_dir: Path,
                        profiles: dict, work_dir: Path | None = None) -> tuple[list[str], list[str]]:
    """
    組出一次下載所需的 yt-dlp 參數（不含 URL 與 print-to-file）。
    回傳 (args, warnings)。
    work_dir：隔離下載用的工作資料夾（見 _isolated_run）。有給的話 yt-dlp 的輸出樣板與路徑長度預算
    都以它為準——yt-dlp 完全不會在 out_dir 裡讀寫任何檔案，成品由我們自己搬過去。
    """
    warnings: list[str] = []
    args: list[str] = list(profiles.get("common", []))

    ff_args, ff_warn = _ffmpeg_location_args()
    args += ff_args
    has_ffmpeg = bool(ff_args)
    if not has_ffmpeg:
        warnings += ff_warn

    # --- 輸出路徑長度預算（Windows MAX_PATH=260）---
    target_dir = work_dir if work_dir is not None else out_dir
    budget_args, name_budget, budget_warn = _path_budget_args(target_dir)
    args += budget_args
    warnings += budget_warn

    # --- 清單 / 單支 與輸出樣板 ---
    if opts["playlist"]:
        args.append("--yes-playlist")
        template = profiles.get("output_template_playlist") or DEFAULT_PROFILES["output_template_playlist"]
    else:
        args.append("--no-playlist")
        template = profiles.get("output_template") or DEFAULT_PROFILES["output_template"]
    if opts["name"]:
        template = opts["name"]
    template = _cap_title_in_template(template, name_budget)
    args += ["-o", str(target_dir / template)]

    # --- 格式與轉檔 ---
    if mode == "mp4":
        vcfg = profiles.get("video", {})
        quality = opts["quality"] or "best"
        choices = profiles.get("quality_choices", DEFAULT_PROFILES["quality_choices"])
        if quality not in choices:
            raise OptionError(f"quality 只能是 {', '.join(choices)}，收到 {quality!r}。")
        if quality == "best":
            fmt = vcfg.get("format_best", DEFAULT_PROFILES["video"]["format_best"])
        else:
            fmt = vcfg.get("format_capped", DEFAULT_PROFILES["video"]["format_capped"]).replace("{H}", quality)
            fmt = _inject_width_fallback(fmt, quality)
        extra = list(vcfg.get("extra", []))
        if not has_ffmpeg:
            # 沒有 ffmpeg 就不能合併分離的影音軌，只能抓「本來就已合併」的單一檔案
            merge_free = "b" if quality == "best" else f"b[height<={quality}]/b[width<={quality}]/b"
            fmt = f"{merge_free}/{fmt}"
            extra = _strip_ffmpeg_args(extra)
            warnings.append(
                "沒有 ffmpeg，只能抓「影音已合併」的單一檔案。實測 YouTube 目前這種格式的數量是 0，"
                "所以 YouTube 不是降畫質而是一定會失敗；其他網站也未必有這種格式。"
                "請先執行「首次設定.bat」安裝 ffmpeg。")
        args += ["-f", fmt]
        if vcfg.get("sort"):
            args += ["-S", str(vcfg["sort"])]
        args += extra
    elif mode == "mp3":
        acfg = profiles.get("audio", {})
        aq = opts["audio_quality"] or "0"
        achoices = profiles.get("audio_quality_choices", DEFAULT_PROFILES["audio_quality_choices"])
        if aq not in achoices:
            raise OptionError(f"audio_quality 只能是 {', '.join(achoices)}，收到 {aq!r}。")
        args += ["-f", acfg.get("format", DEFAULT_PROFILES["audio"]["format"])]
        args += list(acfg.get("extra", []))
        args += ["--audio-quality", aq]
        if not has_ffmpeg:
            warnings.append("沒有 ffmpeg，mp3 轉檔一定會失敗，請先完成首次設定。")
    else:
        raise OptionError(f"mode 只能是 mp4 或 mp3，收到 {mode!r}。")

    # --- 片段擷取 ---
    if opts["clip"]:
        m = _CLIP_RE.match(str(opts["clip"]))
        if not m:
            raise OptionError(f"--clip 格式應為 START-END（例如 00:01:00-00:02:30），收到 {opts['clip']!r}。")
        args += ["--download-sections", f"*{m.group(1)}-{m.group(2)}", "--force-keyframes-at-cuts"]
        if not has_ffmpeg:
            warnings.append("沒有 ffmpeg，--clip 片段擷取無法運作。")

    # --- 字幕 ---
    if opts["subs"]:
        args += ["--write-subs", "--write-auto-subs", "--sub-langs", str(opts["subs"])]
        if has_ffmpeg:
            args.append("--embed-subs")
        else:
            warnings.append("沒有 ffmpeg，字幕無法內嵌（只會另存字幕檔）。")

    # --- cookies ---
    args += _cookie_args(opts)

    # --- 進階使用者逃生口，原樣附加 ---
    args += [str(a) for a in opts["extra_args"]]

    return args, warnings


# 這些 yt-dlp 參數需要 ffmpeg 才能運作；沒有 ffmpeg 時必須拿掉，否則後處理會直接失敗
_FFMPEG_FLAGS_WITH_VALUE = {"--merge-output-format", "--audio-format", "--recode-video"}
_FFMPEG_FLAGS_NO_VALUE = {"--embed-metadata", "--embed-thumbnail", "--embed-subs",
                          "--add-metadata", "-x", "--extract-audio"}


def _strip_ffmpeg_args(args: list[str]) -> list[str]:
    """移除需要 ffmpeg 的參數，讓沒有 ffmpeg 時仍能下載單一檔案。"""
    result: list[str] = []
    skip_next = False
    for arg in args:
        if skip_next:
            skip_next = False
            continue
        if arg in _FFMPEG_FLAGS_WITH_VALUE:
            skip_next = True
            continue
        if arg in _FFMPEG_FLAGS_NO_VALUE:
            continue
        result.append(arg)
    return result


def _has_cookie_opts(opts: dict) -> bool:
    """本次執行是否已經帶了 cookie（含使用者用 --extra-arg 自己塞的）。"""
    if opts.get("cookies_from_browser") or opts.get("cookies"):
        return True
    return any(str(a).startswith("--cookies") for a in (opts.get("extra_args") or []))


def _cookie_args(opts: dict) -> list[str]:
    args: list[str] = []
    if opts.get("cookies_from_browser"):
        args += ["--cookies-from-browser", str(opts["cookies_from_browser"])]
    if opts.get("cookies"):
        args += ["--cookies", str(opts["cookies"])]
    return args


def _static_cookie_source(o: dict) -> dict | None:
    """結果裡的 cookie_source（只描述來源，絕不含 cookie 的值）。登入瀏覽器的詳細資訊由外層補上。"""
    if o.get("login_browser_used"):
        return {"type": "login_browser"}
    if o.get("cookies"):
        return {"type": "cookies_file", "file": str(o["cookies"])}
    if o.get("cookies_from_browser"):
        return {"type": "browser", "browser": str(o["cookies_from_browser"])}
    if any(str(a).startswith("--cookies") for a in (o.get("extra_args") or [])):
        return {"type": "extra_args"}
    return None


# ==========================================================================
# 4b. 登入瀏覽器（tools\browser.ps1）
# ==========================================================================
#
# 為什麼：使用者平常用的 Chrome 開著時，--cookies-from-browser chrome 會失敗（cookie 資料庫被鎖、
# 新版 app-bound 加密也解不開）。登入瀏覽器是用已安裝的 Chrome/Edge 開的「專用設定檔」
# （預設 %LOCALAPPDATA%\影音下載器\browser，可用環境變數 MDL_BROWSER_PROFILE 改），使用者在那個
# 視窗登入一次；要下載時由 browser.ps1 透過 CDP 把 cookie 匯出成暫存 cookies.txt（視窗開著 → live，
# 關著 → 無頭模式開一下就關，headless）。契約見 tools\browser.ps1 開頭註解：
# stdout 恰好一行 ASCII JSON、exit 0/1、失敗時有 code + 中文 hint。
#
# 注意：yt-dlp 跑完會把 cookie jar 寫回 --cookies 的檔案 → 每次都匯出到新的暫存檔、用完一定刪掉。

BROWSER_PS1 = ROOT / "tools" / "browser.ps1"
LOGIN_BROWSER_BAT = "登入瀏覽器.bat"
BROWSER_ACTIONS = ("status", "open", "tabs", "close")
# browser.ps1 內部最多會等 60 秒的互斥鎖（同設定檔同時只能一個動作），再加上實際工作時間
_BROWSER_TIMEOUTS = {"status": 120, "tabs": 90, "open": 120, "close": 120, "export": 180}
_COOKIE_TEMP_PREFIX = "mdl_cookies_"

# 網址主機 → 要匯出的 cookie 網域、要檢查的登入狀態鍵（browser.ps1 的 logged_in）
# 只列「確定只需要自家網域 cookie」的站台；其他網站一律匯出全部 cookie（通用抽取器可能跟著
# 內嵌播放器跑到別的網域，少給反而會變成未登入）。媒體 CDN（cdninstagram / fbcdn / twimg）
# 用的是簽章網址，不需要 cookie。
_LOGIN_SITES = (
    (("instagram.com", "instagr.am"), ("instagram.com",), "instagram", "Instagram"),
    (("x.com", "twitter.com", "fxtwitter.com", "vxtwitter.com", "t.co"), ("x.com", "twitter.com"), "x", "X"),
    (("facebook.com", "fb.com", "fb.watch"), ("facebook.com",), "facebook", "Facebook"),
    (("youtube.com", "youtu.be", "youtube-nocookie.com"), ("youtube.com",), None, "YouTube"),
)


def _truthy(value) -> bool:
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "y", "on")
    return bool(value)


def _find_powershell() -> str | None:
    if os.name != "nt":
        return None
    found = shutil.which("powershell.exe") or shutil.which("powershell")
    if found:
        return found
    cand = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    return str(cand) if cand.is_file() else None


def run_browser_ps1(action: str, params: list[str] | None = None, timeout: int | None = None) -> dict:
    """
    呼叫 tools\\browser.ps1 -Action <action>，回傳它輸出的那一行 JSON（dict）。
    任何失敗（找不到 PowerShell、逾時、stdout 沒有 JSON——例如參數名稱打錯時 PowerShell 在進入
    腳本前就報錯）也一律回傳帶 ok:false / code / error / hint 的 dict，絕不拋例外。
    """
    def _err(code: str, error: str, hint: str, tail=None) -> dict:
        return {"ok": False, "action": action, "code": code, "error": error, "hint": hint,
                "warnings": [], "log_tail": tail}

    ps = _find_powershell()
    if ps is None:
        return _err("no_powershell", "找不到 Windows PowerShell（powershell.exe）。",
                    "登入瀏覽器只支援 Windows；請改用 --cookies cookies.txt。")
    if not BROWSER_PS1.is_file():
        return _err("missing_script", f"找不到 {BROWSER_PS1}。",
                    "專案資料夾不完整：請重新取得 tools\\browser.ps1。")
    cmd = [ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
           "-File", str(BROWSER_PS1), "-Action", action] + [str(p) for p in (params or [])]
    limit = timeout or _BROWSER_TIMEOUTS.get(action, 120)
    try:
        # 不能用會等「所有子孫行程」的呼叫方式；subprocess.run 只等 powershell 本身。
        # browser.ps1 用 ShellExecute 啟動瀏覽器，不會繼承我們的 stdout pipe（實測約 1 秒返回）。
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              stdin=subprocess.DEVNULL, timeout=limit, **_no_window_kwargs())
    except subprocess.TimeoutExpired:
        return _err("timeout", f"登入瀏覽器動作 {action} 超過 {limit} 秒沒有完成。",
                    "請關閉登入瀏覽器（mdl.py browser close）後再試；若一直逾時，重新開機後再試。")
    except Exception as exc:
        return _err("spawn_failed", f"無法執行 PowerShell：{exc}",
                    "請確認 Windows PowerShell 可以正常執行。")

    out = proc.stdout.decode("utf-8", errors="replace")
    # browser.ps1 自己的 stderr 是 UTF-8；但 PowerShell 在進入腳本前的錯誤（例如參數名稱打錯）
    # 用的是主控台的 OEM 字碼頁（中文 Windows 是 cp950）→ 逐行判斷
    err_lines = []
    for raw in proc.stderr.splitlines():
        try:
            err_lines.append(raw.decode("utf-8"))
        except UnicodeDecodeError:
            try:
                err_lines.append(raw.decode("oem", errors="replace"))
            except LookupError:
                err_lines.append(raw.decode("mbcs" if os.name == "nt" else "latin-1", errors="replace"))
    err = "\n".join(err_lines)
    data = None
    for line in reversed(out.splitlines()):
        line = line.strip().lstrip("\ufeff")
        if line.startswith("{"):
            try:
                data = json.loads(line)
                break
            except Exception:
                continue
    if not isinstance(data, dict):
        tail = _log_tail(err, 8)
        # PowerShell 的錯誤第一行是訊息本身，後面是 "+ CategoryInfo ..." 之類的附註
        main = next((ln.strip() for ln in tail if not ln.strip().startswith(("+", "At ", "位於", "~"))), None)
        detail = f"：{main[:300]}" if main else ""
        return _err("no_output", f"browser.ps1 沒有輸出結果（exit {proc.returncode}）{detail}",
                    "登入瀏覽器腳本執行失敗：請手動執行 powershell -NoProfile -ExecutionPolicy Bypass "
                    "-File tools\\browser.ps1 -Action status 查看錯誤訊息。", tail)
    data.setdefault("ok", proc.returncode == 0)
    data.setdefault("warnings", [])
    if not data.get("ok"):
        data.setdefault("code", "error")
        data.setdefault("hint", "登入瀏覽器操作失敗，請關閉登入瀏覽器後重試。")
        # 已知錯誤（no_profile / profile_locked…）的 stderr 只是把 error + hint 再印一次；
        # 只有未預期的錯誤才附上診斷訊息
        tail = _log_tail(err, 8)
        if tail and data.get("code") == "error":
            data.setdefault("log_tail", tail)
    return data


def _host_of(url: str) -> str:
    text = str(url or "").strip()
    if text and "://" not in text:
        text = "https://" + text     # images 指令接受沒有 https:// 的網址
    try:
        return (urllib.parse.urlsplit(text).hostname or "").lower().rstrip(".")
    except Exception:
        return ""


def _login_cookie_scope(urls: list[str]) -> tuple[list[str] | None, list[tuple[str, str]]]:
    """
    依網址決定要匯出哪些網域的 cookie。
    回傳 (domains 或 None = 全部匯出, [(logged_in 鍵, 站名), ...])。
    只要有一個網址不在已知清單裡（或解析不出主機），就匯出全部。
    """
    domains: list[str] = []
    checks: list[tuple[str, str]] = []
    export_all = False
    for url in urls:
        host = _host_of(url)
        site = next((s for s in _LOGIN_SITES
                     if any(host == h or host.endswith("." + h) for h in s[0])), None) if host else None
        if site is None:
            export_all = True
            continue
        domains.extend(d for d in site[1] if d not in domains)
        if site[2] and (site[2], site[3]) not in checks:
            checks.append((site[2], site[3]))
    return (None if export_all or not domains else domains), checks


def _remove_cookie_temp(path: str | None) -> None:
    """刪掉暫存 cookies.txt（含 browser.ps1 寫到一半留下的 <檔名>.tmp<PID>）。"""
    if not path:
        return
    _cleanup(path)
    try:
        p = Path(path)
        for sib in p.parent.glob(p.name + ".tmp*"):
            _cleanup(str(sib))
    except Exception:
        pass


def _login_browser_export(urls: list[str]) -> tuple[dict | None, dict | None]:
    """
    從登入瀏覽器匯出這些網址需要的 cookie 到一個新的暫存檔。
    回傳 (ctx, failure)：成功時 ctx = {file, source, warnings}；失敗時 failure = browser.ps1 的結果。
    """
    domains, checks = _login_cookie_scope(urls)
    fd, path = tempfile.mkstemp(prefix=_COOKIE_TEMP_PREFIX, suffix=".txt")
    os.close(fd)
    params = ["-OutFile", path]
    if domains:
        params += ["-Domains", ",".join(domains)]
    res = run_browser_ps1("export", params)
    if not res.get("ok"):
        _remove_cookie_temp(path)
        return None, res

    got_domains = res.get("domains")
    if isinstance(got_domains, str):
        got_domains = [got_domains]
    logged_in = res.get("logged_in") if isinstance(res.get("logged_in"), dict) else {}
    count = res.get("count")
    source = {
        "type": "login_browser",
        "mode": res.get("mode"),              # live（視窗開著）/ headless（臨時無頭）/ headless_orphan
        "browser": res.get("browser"),
        "count": count,                        # 寫進 cookies.txt 的數量（已依網域篩選）
        "total": res.get("total"),             # 登入瀏覽器裡的 cookie 總數
        "domains": got_domains or None,        # null = 全部網域
        "logged_in": logged_in or None,
    }
    warnings: list[str] = []
    scope_txt = "、".join(got_domains) if got_domains else "所有網站"
    if not count:
        warnings.append(
            f"登入瀏覽器沒有 {scope_txt} 的 cookie（匯出 0 顆），本次等於未登入。公開內容仍可下載；"
            "需要登入的內容請先執行「登入瀏覽器.bat」（agent：mdl_login_browser action=open）登入該網站。")
    else:
        for key, label in checks:
            if logged_in.get(key) is False:
                warnings.append(
                    f"登入瀏覽器還沒登入 {label}（找不到登入 cookie），本次以未登入身分存取；公開內容仍可下載，"
                    f"需要登入的內容請先執行「登入瀏覽器.bat」（agent：mdl_login_browser action=open）登入 {label}。")
    for w in res.get("warnings") or []:
        warnings.append(f"登入瀏覽器：{w}")
    return {"file": path, "source": source, "warnings": warnings}, None


def _with_login_browser(action: str, url, urls: list[str], opts: dict, run) -> dict:
    """
    --login-browser / use_login_browser 的共用流程：
    檢查與其他 cookie 來源互斥 → 匯出一次暫存 cookies.txt → run(新 opts) → finally 刪檔
    → 在結果補上 cookie_source 與登入狀態警告。
    """
    started = time.time()
    clash = [k for k in ("cookies", "cookies_file", "cookies_from_browser") if opts.get(k)]
    if any(str(a).startswith("--cookies") for a in (opts.get("extra_args") or [])):
        clash.append("extra_args 裡的 --cookies…")
    if clash:
        env = _envelope(action, url, cookie_source=None)
        return _fail(env,
                     "--login-browser（use_login_browser）不能和 --cookies / --cookies-from-browser 同時使用"
                     f"（同時收到：{', '.join(clash)}）。",
                     "cookie 來源只能擇一：登入瀏覽器（--login-browser，agent：use_login_browser=true）、"
                     "--cookies-from-browser <瀏覽器>，或 --cookies <cookies.txt>。請拿掉其中一個再試。")

    ctx, failure = _login_browser_export(urls)
    if failure is not None:
        code = failure.get("code") or "error"
        env = _envelope(action, url, cookie_source={"type": "login_browser", "ok": False, "code": code})
        env["elapsed_sec"] = round(time.time() - started, 2)
        hint = failure.get("hint") or "登入瀏覽器匯出 cookie 失敗。"
        if code == "no_profile":
            hint += ("（agent：可呼叫 mdl_login_browser action=open 開啟登入瀏覽器，請使用者在視窗中登入後再試；"
                     "公開內容也可以拿掉 use_login_browser 直接下載。）")
        env = _fail(env, "登入瀏覽器匯出 cookie 失敗：" + str(failure.get("error") or "未知錯誤"), hint)
        if failure.get("log_tail"):
            env["log_tail"] = failure["log_tail"]
        env["warnings"].extend(f"登入瀏覽器：{w}" for w in (failure.get("warnings") or []))
        return env

    try:
        inner = {k: v for k, v in opts.items()
                 if k not in ("use_login_browser", "cookies", "cookies_file", "cookies_from_browser")}
        inner["cookies"] = ctx["file"]
        inner["_login_browser"] = True
        env = run(inner)
    finally:
        _remove_cookie_temp(ctx["file"])
    env["cookie_source"] = ctx["source"]
    env["warnings"] = ctx["warnings"] + list(env.get("warnings") or [])
    return env


def login_browser(action: str = "status", url: str | None = None, probe: bool = False, **_ignored) -> dict:
    """
    登入瀏覽器的管理動作（包裝 tools\\browser.ps1）：
      status [probe]  是否開著、設定檔、各站登入狀態（開著時才讀得到；probe=True 關著時用無頭模式讀）
      open [url]      開啟視窗；已開則開新分頁到 url
      tabs            目前開著的分頁（url / title）
      close           關閉登入瀏覽器
    回傳 browser.ps1 的欄位（攤平），另加 action="login_browser"、browser_action、elapsed_sec。
    """
    started = time.time()
    act = str(action or "status").strip().lower()
    env: dict = {"ok": True, "action": "login_browser", "browser_action": act,
                 "warnings": [], "error": None, "hint": None}
    if act not in BROWSER_ACTIONS:
        env.update(ok=False, code="bad_args", error=f"不認得的 action：{action!r}",
                   hint="action 只能是 " + " / ".join(BROWSER_ACTIONS) + "。")
        return env
    params: list[str] = []
    if url and act == "open":
        params += ["-Url", str(url)]
    elif url:
        env["warnings"].append(f"url 只在 action=open 時使用，action={act} 已忽略它。")
    if probe and act == "status":
        params.append("-Probe")
    res = run_browser_ps1(act, params)
    for key, value in res.items():
        if key in ("action", "warnings", "elapsed_ms"):
            continue
        env[key] = value
    env["warnings"].extend(res.get("warnings") or [])
    env["ok"] = bool(res.get("ok"))
    if act == "tabs" and env["ok"]:
        # /json/list 的順序大致是「最近使用的在前」，但不保證；只挑一般網頁當「可能是目前分頁」
        pages = [t for t in (env.get("tabs") or [])
                 if isinstance(t, dict) and str(t.get("url") or "").lower().startswith(("http://", "https://"))]
        env["likely_current_url"] = pages[0]["url"] if pages else None
    if act == "status" and env["ok"] and not env.get("profile_exists"):
        env["hint"] = ("登入瀏覽器還沒建立過：請執行「登入瀏覽器.bat」（agent：action=open），"
                       "在那個視窗登入需要的網站（IG / FB / X…）一次，之後下載時加 --login-browser / use_login_browser。")
    env["elapsed_sec"] = round(time.time() - started, 2)
    return env


# ==========================================================================
# 5. 核心動作
# ==========================================================================

def _new_tempfile(suffix: str) -> str:
    fd, path = tempfile.mkstemp(prefix="mdl_", suffix=suffix)
    os.close(fd)
    return path


def _read_lines(path: str) -> list[str]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return [ln.strip() for ln in fh if ln.strip()]
    except Exception:
        return []


def _cleanup(*paths: str) -> None:
    for p in paths:
        try:
            os.unlink(p)
        except Exception:
            pass


def _file_entry(path_str: str) -> dict:
    p = Path(path_str)
    try:
        size = p.stat().st_size if p.is_file() else None
    except Exception:
        size = None
    return {
        "path": str(p),
        "name": p.name,
        "size": size,
        "ext": p.suffix.lstrip(".").lower() or None,
    }


# 只有長得像 yt-dlp 分軌暫存檔的名字才可以刪：.f398.mp4 / .f140.m4a / .fhls-605.mp4 …
_FRAG_TEMP_RE = re.compile(r"\.f[0-9A-Za-z][0-9A-Za-z_\-]*\.[A-Za-z0-9]{1,5}$")
_DEST_RE = re.compile(r"^\[download\]\s+Destination:\s*(.+)$")


def _reported_paths(stdout: str, stderr: str) -> list[str]:
    """
    抓出本次 yt-dlp 自己講過的目的檔路徑（[download] Destination: ...）。
    只認這些明確回報過的檔名，絕不用萬用字元掃整個資料夾。
    """
    paths: list[str] = []
    for raw in ((stdout or "") + "\n" + (stderr or "")).splitlines():
        match = _DEST_RE.match(raw.strip())
        if match:
            paths.append(match.group(1).strip())
    return _dedupe(paths)


def _cleanup_partials(stdout: str, stderr: str, out_dir: Path,
                      keep: list[str]) -> list[str]:
    """
    下載判定失敗時，清掉本次留下的無用殘檔（.part / .ytdl / .fNNN.ext 分軌檔）。

    安全規則（寧可保守）：
      1. 只處理 yt-dlp 本次回報過的目的檔名；
      2. 該檔名必須長得像暫存檔；
      3. 必須位於本次的輸出資料夾底下；
      4. 已經成功產出的檔案（keep）永遠不動。
    """
    removed: list[str] = []
    keep_set = {os.path.normcase(os.path.abspath(p)) for p in (keep or [])}
    try:
        out_abs = out_dir.resolve()
    except Exception:
        return removed

    for raw in _reported_paths(stdout, stderr):
        try:
            dest = Path(raw)
            if not dest.is_absolute():
                dest = out_dir / dest
            dest = dest.resolve()
            if not dest.is_relative_to(out_abs):
                continue
        except Exception:
            continue

        candidates = [dest, Path(str(dest) + ".part"), Path(str(dest) + ".ytdl")]
        # 分段下載的 .part-FragN.part：以「本次回報的檔名」為前綴比對，不用萬用字元
        try:
            frag_prefix = dest.name + ".part-Frag"
            for sibling in dest.parent.iterdir():
                if sibling.name.startswith(frag_prefix):
                    candidates.append(sibling)
        except Exception:
            pass

        for cand in candidates:
            if os.path.normcase(os.path.abspath(str(cand))) in keep_set:
                continue
            name = cand.name
            looks_temp = (name.endswith(".part") or name.endswith(".ytdl")
                          or bool(_FRAG_TEMP_RE.search(name)))
            if not looks_temp:
                continue
            try:
                if cand.is_file():
                    cand.unlink()
                    removed.append(str(cand))
            except Exception:
                pass
    return removed


def _partial_failure_warning(stdout: str, stderr: str, ok_files: int, images_tip: bool = True) -> str:
    """
    有檔案產出、但 yt-dlp 回傳非零 exit code 時，把子項目的失敗降級成一句人話警告。
    （典型情境：IG 輪播貼文被當成 playlist 展開，照片那幾格沒有影片可下載。）
    images_tip=False：不附「請改用 images 指令」（影片模式的照片階段已經自動去抓照片了）。
    """
    blob = (stdout or "") + "\n" + (stderr or "")
    total = 0
    for match in re.finditer(r"Downloading item \d+ of (\d+)", blob):
        total = max(total, int(match.group(1)))

    err_lines = _dedupe([ln.strip() for ln in blob.splitlines()
                         if ln.strip().startswith("ERROR:")])
    failed = len(err_lines) or 1
    total = max(total, ok_files + failed)

    photo_items = any("no video formats found" in ln.lower() for ln in err_lines)
    reason = "沒有影片可下載（可能是輪播貼文中的照片）" if photo_items else "下載失敗"
    message = (f"{total} 個項目中有 {failed} 個{reason}，已略過；"
               f"其餘 {ok_files} 個檔案已成功下載。")
    if photo_items and images_tip:
        message += "若要連照片一起下載，" + _IMAGES_TOOL_TIP
    return message


def _run_with_retry(cmd_base: list[str], url: str, echo_stdout: bool,
                    echo_stderr: bool, extra_skip=None) -> tuple[int, str, str, int, list[str]]:
    """
    跑 yt-dlp；第一次失敗就自動加 --impersonate chrome 重試一次（IG/X/FB 常需要）。
    回傳 (rc, stdout, stderr, attempts, warnings)。
    extra_skip(stderr, stdout)：呼叫端額外的「不必重試」判斷，回傳說明文字或 None
    （影片模式的照片階段用：FB 貼文抓不到影片但有照片時，不必再重試一次）。
    """
    warnings: list[str] = []
    tail = [url] if url else []      # url=None：網址以外的來源（--load-info-json）已經在 cmd_base 裡

    rc, out, err = run_cmd(cmd_base + tail, echo_stdout, echo_stderr)
    if rc == 0:
        return rc, out, err, 1, warnings

    skip = _skip_retry_reason(err, out)
    if not skip and extra_skip is not None:
        try:
            skip = extra_skip(err, out)
        except Exception:
            skip = None
    if skip:
        warnings.append(skip)
        if echo_stdout:
            print(f"[mdl] {skip}", flush=True)
        return rc, out, err, 1, warnings

    # 第二次：模擬 Chrome TLS 指紋
    if echo_stdout:
        print("[mdl] 第一次失敗，改用 --impersonate chrome 重試…", flush=True)
    rc2, out2, err2 = run_cmd(cmd_base + ["--impersonate", "chrome"] + tail, echo_stdout, echo_stderr)
    if rc2 == 0:
        warnings.append("第一次下載失敗，改用 --impersonate chrome 後成功。")
        return rc2, out2, err2, 2, warnings

    if _impersonate_unsupported(err2):
        # 這份 yt-dlp 沒有 impersonate 能力 → 回報第一次的真正錯誤，不要誤導
        warnings.append("這份 yt-dlp 不支援 --impersonate（需要 curl_cffi 版本），已略過重試。")
        return rc, out, err, 2, warnings

    return rc2, out2, err2, 2, warnings


def _max_height(info: dict) -> int | None:
    """從 -J 結果推算最高可用解析度（只看有視訊軌的格式）。"""
    heights: list[int] = []
    for f in (info.get("formats") or []):
        if (f.get("vcodec") or "none") == "none":
            continue
        h = f.get("height")
        if isinstance(h, int):
            heights.append(h)
    if heights:
        return max(heights)
    h = info.get("height")
    return h if isinstance(h, int) else None


# ---------------------------------------------------------------- info ---

def get_info(url: str, **opts) -> dict:
    """取得單支影片的精簡 metadata（-J --no-playlist）。use_login_browser=True 時用登入瀏覽器的 cookie。"""
    if _truthy(opts.get("use_login_browser")):
        return _with_login_browser("info", url, [url], opts, lambda o2: get_info(url, **o2))
    o = _norm_opts(opts)
    env = _envelope("info", url, cookie_source=_static_cookie_source(o))
    started = time.time()

    exe = _ytdlp_or_fail(env)
    if exe is None:
        return env

    profiles = load_profiles()
    cmd = [str(exe)] + list(profiles.get("common", [])) + ["-J", "--no-playlist"]
    cmd += _cookie_args(o)
    cmd += [str(a) for a in o["extra_args"]]

    rc, out, err = run_cmd(cmd + [url], echo_stdout=False, echo_stderr=False)
    env["attempts"] = 1
    if rc != 0 or not out.strip():
        skip = _skip_retry_reason(err, out)
        if skip:
            # cookie 讀不到：重試只是換 TLS 指紋，cookie 來源沒變，必然再失敗
            env["warnings"].append(skip)
        else:
            # 同樣給一次 impersonate 機會
            rc2, out2, err2 = run_cmd(cmd + ["--impersonate", "chrome", url], False, False)
            env["attempts"] = 2
            if rc2 == 0 and out2.strip():
                rc, out, err = rc2, out2, err2
            elif _impersonate_unsupported(err2):
                env["warnings"].append("這份 yt-dlp 不支援 --impersonate，已略過重試。")
            else:
                err = err2 or err

    env["elapsed_sec"] = round(time.time() - started, 2)

    if rc != 0 or not out.strip():
        return _fail(env, compact_error(err, out), build_hint(err, out, _has_cookie_opts(o), o["login_browser_used"]), err)

    try:
        data = json.loads(out.strip().lstrip("\ufeff"))
    except Exception:
        return _fail(env, "無法解析 yt-dlp 的 JSON 輸出。", None, err)

    max_h = _max_height(data)
    env["site"] = (data.get("extractor_key") or data.get("extractor") or "").lower() or None
    env["title"] = data.get("title")
    env["duration"] = data.get("duration")
    env["uploader"] = data.get("uploader") or data.get("channel") or data.get("uploader_id")
    env["info"] = {
        "title": data.get("title"),
        "uploader": env["uploader"],
        "duration": data.get("duration"),
        "duration_string": data.get("duration_string"),
        "upload_date": data.get("upload_date"),
        "webpage_url": data.get("webpage_url") or url,
        "site": env["site"],
        "extractor": data.get("extractor"),
        "thumbnail": data.get("thumbnail"),
        "is_live": bool(data.get("is_live")) if data.get("is_live") is not None else False,
        "view_count": data.get("view_count"),
        "max_height": max_h,
        "max_resolution": f"{max_h}p" if max_h else data.get("resolution"),
    }
    return env


# ------------------------------------------------------------- formats ---

def list_formats(url: str, json_mode: bool = True, **opts) -> dict:
    """
    列出可用格式。
    json_mode=True  → 用 -J 解析出結構化清單（給 GUI / agent）
    json_mode=False → 直接串流 yt-dlp -F 的原始表格（給人看）
    use_login_browser=True 時用登入瀏覽器的 cookie。
    """
    if _truthy(opts.get("use_login_browser")):
        return _with_login_browser("formats", url, [url], opts,
                                   lambda o2: list_formats(url, json_mode=json_mode, **o2))
    o = _norm_opts(opts)
    env = _envelope("formats", url, cookie_source=_static_cookie_source(o))
    started = time.time()

    exe = _ytdlp_or_fail(env)
    if exe is None:
        return env

    profiles = load_profiles()
    base = [str(exe)] + list(profiles.get("common", [])) + ["--no-playlist"]
    base += _cookie_args(o)
    base += [str(a) for a in o["extra_args"]]

    if not json_mode:
        rc, out, err = run_cmd(base + ["-F", url], echo_stdout=not o["quiet"], echo_stderr=not o["quiet"])
        env["attempts"] = 1
        env["elapsed_sec"] = round(time.time() - started, 2)
        if rc != 0:
            return _fail(env, compact_error(err, out), build_hint(err, out, _has_cookie_opts(o), o["login_browser_used"]), err)
        env["formats"] = []
        return env

    rc, out, err = run_cmd(base + ["-J", url], echo_stdout=False, echo_stderr=False)
    env["attempts"] = 1
    env["elapsed_sec"] = round(time.time() - started, 2)
    if rc != 0 or not out.strip():
        return _fail(env, compact_error(err, out), build_hint(err, out, _has_cookie_opts(o), o["login_browser_used"]), err)

    try:
        data = json.loads(out.strip().lstrip("﻿"))
    except Exception as exc:
        return _fail(env, f"無法解析 yt-dlp 的 JSON 輸出：{exc}", None, err)

    formats = []
    for f in (data.get("formats") or []):
        formats.append({
            "format_id": f.get("format_id"),
            "ext": f.get("ext"),
            "resolution": f.get("resolution") or (
                f"{f.get('width')}x{f.get('height')}" if f.get("width") and f.get("height") else None),
            "fps": f.get("fps"),
            "vcodec": f.get("vcodec"),
            "acodec": f.get("acodec"),
            "filesize": f.get("filesize") if f.get("filesize") is not None else f.get("filesize_approx"),
        })

    env["site"] = (data.get("extractor_key") or "").lower() or None
    env["title"] = data.get("title")
    env["duration"] = data.get("duration")
    env["uploader"] = data.get("uploader") or data.get("channel")
    env["formats"] = formats
    return env


# ------------------------------------------------------------ download ---

def download(url: str, mode: str = "mp4", **opts) -> dict:
    """
    下載單一 URL（mode: mp4 影片 / mp3 音訊），回傳統一信封。use_login_browser=True 時用登入瀏覽器的 cookie。

    影片模式（mp4）另有「照片階段」：網址是 IG / FB / X 的單篇貼文（見 _photo_pass_site）時，影片照舊由
    yt-dlp 下載，接著自動用照片引擎把貼文裡的照片也抓下來（只抓照片，不會重抓影片），cookie 與影片階段
    共用同一份。include_photos=False（CLI --no-photos）可關閉。影片模式的結果 files 每筆都有 kind
    （video / image / other），另有 media_counts 與 photo_pass（沒跑照片階段時是 null）。

    音訊模式（mp3）走「隔離下載」（見 _isolated_run）：yt-dlp 只在輸出資料夾底下這次才建立的工作資料夾裡
    動作，轉好的檔案才搬進輸出資料夾，所以既有的檔案（例如同名的影片）絕不會被刪除或改寫。結果 files
    每筆有 existing（True = 成品先前就已經存在，這次沒有重新下載）。
    """
    action = "video" if mode == "mp4" else "audio"
    if _truthy(opts.get("use_login_browser")):
        # 登入瀏覽器只匯出一次：內層 download() 的 yt-dlp 階段與照片階段共用同一個暫存 cookies.txt
        return _with_login_browser(action, url, [url], opts, lambda o2: download(url, mode=mode, **o2))
    o = _norm_opts(opts)
    env = _envelope(action, url, cookie_source=_static_cookie_source(o))
    if mode == "mp4":
        env["media_counts"] = {"images": 0, "videos": 0, "other": 0, "existing": 0}
        env["photo_pass"] = None
    started = time.time()

    exe = _ytdlp_or_fail(env)
    if exe is None:
        return env

    try:
        out_dir = _resolve_out_dir(o)
    except Exception as exc:
        return _fail(env, f"無法建立輸出資料夾：{exc}", "請改用 --out 指定一個可寫入的資料夾。")
    env["output_dir"] = str(out_dir)

    # 音訊（-x 轉檔）一律在輸出資料夾底下的專用工作資料夾裡下載，成品再搬出來（原因見 _isolated_run）。
    # 這裡只決定名字，真的要下載時才建立。
    work_dir = _new_work_dir_path(out_dir) if mode == "mp3" else None

    profiles = load_profiles()
    try:
        args, warnings = build_download_args(mode, o, out_dir, profiles, work_dir=work_dir)
    except OptionError as exc:
        return _fail(env, str(exc), "請檢查參數值；可用選項見 mdl.py --help。")
    env["warnings"].extend(warnings)

    echo = (not o["json_mode"]) and (not o["quiet"])

    # --- 照片階段（只有影片模式、而且網址是可能含照片的社群貼文時才有）---
    photo_site = None
    if mode == "mp4" and o["include_photos"]:
        photo_site = _photo_pass_site(url, bool(o["cookies"] or o["cookies_from_browser"]))
    photo_box: dict = {}

    def _photos() -> dict:
        """跑照片階段（整次下載最多跑一次），回傳 download_images 的信封。"""
        if "env" not in photo_box:
            if echo:
                print("[mdl] 這是社群貼文網址，一併檢查貼文裡的照片…", flush=True)
            photo_box["env"] = _run_photo_pass(url, o, out_dir)
        return photo_box["env"]

    def _fb_photo_probe(err_text: str, out_text: str) -> str | None:
        # FB 貼文「404／Cannot parse data」：純照片貼文實測就是這個反應，但不保證。
        # 先看貼文裡有沒有照片；有就不必再用 --impersonate 重試一次（省一次請求與 3～5 秒）。
        if _photo_post_kind((err_text or "") + "\n" + (out_text or "")) not in ("fb_404", "fb_no_data"):
            return None
        return _FB_PHOTOS_FOUND_SKIP_NOTE if _photos().get("files") else None

    ctx = _ytdlp_step(url, mode, o, env, exe, args, out_dir, echo,
                      extra_skip=_fb_photo_probe if photo_site == "facebook" else None,
                      work_dir=work_dir)

    if mode == "mp4":
        for entry in env["files"]:
            p = Path(entry["path"])
            entry["kind"] = _media_kind(p, _sniff_media(p))
        if photo_site and ctx.get("ran"):
            try:
                _merge_photo_pass(env, ctx, photo_site, o, _photos)
            except Exception as exc:   # 照片階段絕不能把影片的結果弄壞
                env["photo_pass"] = {"ran": True, "engine": None, "found": 0, "note": None,
                                     "error": f"{type(exc).__name__}: {exc}", "elapsed_sec": None}
        _count_media(env)
    env["elapsed_sec"] = round(time.time() - started, 2)
    return env


# ------------------------------------------------------- 隔離下載（音訊）---
#
# 為什麼音訊不能直接下載到輸出資料夾（實測 yt-dlp 2026.08.19）：
#   -x 轉檔前的檔名是 <標題> [<ID>].<來源副檔名>。X 的 HLS 音訊、IG / FB 退回 b 格式時來源副檔名是 mp4，
#   正好等於先前用影片模式下載的同一支影片。yt-dlp 看到同名檔就當成「已經下載好的中間檔」
#   （has already been downloaded），拿它轉出 mp3 之後把「中間檔」刪掉——使用者的影片就不見了。
#   同理，同名的封面圖（--embed-thumbnail 的中間檔）會被拿去嵌入後刪除；既有的 mp3 每跑一次都會被
#   重寫一遍（重新嵌入標題資訊與封面）。
#   -P temp:<資料夾> 沒有用（yt-dlp 照樣先檢查輸出資料夾裡的同名檔，實測影片照樣被刪）；
#   -k/--keep-video 會讓 mp3 變成「從既有檔案轉出來」而不是從網站下載，同名封面圖照樣被吃掉，
#   既有 mp3 照樣被重寫。
#
# 做法：yt-dlp 只在輸出資料夾底下一個「這次才建立」的工作資料夾裡動作，所以碰不到任何既有檔案。
#   1. 探查：yt-dlp -j（不下載）取得每個項目的資訊與檔名 → 算出成品路徑。成品已經存在的項目直接略過
#      （不重新下載，也不去動那個檔案）；全部都在就到此為止，連工作資料夾都不會建立。
#   2. 下載：把還沒有成品的項目的 JSON 交給 yt-dlp --load-info-json（不必重新向網站要一次資訊），
#      輸出到工作資料夾。
#   3. 搬移：只把 yt-dlp 回報的成品（以及同名的附屬檔，例如使用者要求另存的字幕）搬到輸出資料夾，
#      目的地已經有檔案就不搬（絕不覆蓋）。最後把工作資料夾整個刪掉——裡面只有這次產生的東西
#      （轉檔前的來源檔、封面圖、.part…），所以不會留下殘檔，也不可能刪到使用者的檔案。
# GUI（tools\gui.ps1 的「音樂：隔離下載」）是同一套流程。

_WORK_DIR_PREFIX = ".mdltmp-"
# 探查時每個項目印一行。標題與上傳者用 JSON 字串（j）輸出，裡面有換行也不會把一行拆成兩行。
_PROBE_TEMPLATE = _META_SEP.join([
    "%(ext|)s",
    "%(filename|)s",
    "%(duration|)s",
    "%(extractor_key|)s",
    "%(webpage_url|)s",
    "%(uploader,channel,uploader_id|)j",
    "%(title|)j",
])
# --audio-format → 成品副檔名（yt-dlp FFmpegExtractAudioPP）。不在表裡（best、aac…）就不預先判斷成品檔名。
_AUDIO_EXT_BY_FORMAT = {"mp3": "mp3", "m4a": "m4a", "opus": "opus", "flac": "flac", "wav": "wav",
                        "vorbis": "ogg"}
# 搬附屬檔時要排除的暫存檔：.part / .ytdl / .part-FragN / .temp.<ext>（分軌檔 .fNNN.<ext> 另由 _FRAG_TEMP_RE 排除）
_WORK_TEMP_NAME_RE = re.compile(r"(?:\.part|\.ytdl|\.part-Frag\d+(?:\.part)?|\.temp\.[A-Za-z0-9]{1,5})$",
                                re.IGNORECASE)


def _new_work_dir_path(out_dir: Path) -> Path:
    """挑一個目前不存在的工作資料夾路徑（只決定名字，不建立）。"""
    cand = out_dir / (_WORK_DIR_PREFIX + os.urandom(3).hex())
    for _ in range(50):
        if not os.path.lexists(cand):
            break
        cand = out_dir / (_WORK_DIR_PREFIX + os.urandom(3).hex())
    return cand


def _create_work_dir(work_dir: Path) -> None:
    """建立工作資料夾。一定要是「這次才建立」的（已存在就拋例外），結束時才能放心整個刪掉。"""
    os.mkdir(work_dir)
    if os.name == "nt":
        try:    # 設成隱藏：下載期間不要在使用者的資料夾裡閃一個奇怪的資料夾
            import ctypes
            ctypes.windll.kernel32.SetFileAttributesW(str(work_dir), 0x2)
        except Exception:
            pass


def _remove_work_dir(work_dir: Path) -> bool:
    """刪掉這次建立的工作資料夾（防毒／同步軟體可能短暫鎖檔，重試幾次）。回傳是否已經不存在。"""
    if not work_dir.name.startswith(_WORK_DIR_PREFIX):
        return False
    for attempt in range(8):
        if not os.path.lexists(work_dir):
            return True
        try:
            shutil.rmtree(work_dir)
        except Exception:
            time.sleep(0.25 * (attempt + 1))
    return not os.path.lexists(work_dir)


def _audio_final_ext(args: list[str]) -> str | None:
    """
    從 yt-dlp 參數推斷成品的副檔名：'mp3' 之類；''＝沒有 -x（成品就是下載到的檔案）；
    None＝不確定（--audio-format best…）。不確定時不預先判斷「成品已存在」，其餘流程照舊安全。
    """
    args = [str(a) for a in args]
    if not any(a in ("-x", "--extract-audio") for a in args):
        return ""
    fmt = None
    for i, a in enumerate(args):
        if a == "--audio-format" and i + 1 < len(args):
            fmt = args[i + 1]
        elif a.startswith("--audio-format="):
            fmt = a.split("=", 1)[1]
    return _AUDIO_EXT_BY_FORMAT.get(str(fmt or "").strip().lower())


def _expected_output(filename: str, src_ext: str, final_ext: str | None) -> str | None:
    """轉檔後的檔名（同 yt-dlp replace_extension）：<檔名去掉來源副檔名>.<成品副檔名>。"""
    if final_ext is None or not filename:
        return None
    if final_ext == "":
        return filename
    root, real_ext = os.path.splitext(filename)
    base = root if (not src_ext or real_ext[1:] == src_ext) else filename
    return f"{base}.{final_ext}"


def _rel_inside(path: str, base: Path) -> str | None:
    """path 在 base 底下就回傳相對路徑，否則 None。"""
    try:
        rel = os.path.relpath(os.path.abspath(path), os.path.abspath(str(base)))
    except Exception:
        return None
    if rel in (os.curdir, os.pardir) or rel.startswith(os.pardir + os.sep) or os.path.isabs(rel):
        return None
    return rel


def _parse_probe(lines: list[str]) -> list[dict]:
    """解析探查階段 _PROBE_TEMPLATE 印出的每一行。"""
    rows: list[dict] = []

    def _unjson(text: str) -> str | None:
        text = (text or "").strip()
        if text.startswith('"'):
            try:
                text = str(json.loads(text))
            except Exception:
                pass
        text = text.strip()
        return None if text in ("", "NA") else text

    for line in lines:
        parts = line.split(_META_SEP, 6)
        while len(parts) < 7:
            parts.append("")
        try:
            duration = int(float(parts[2])) if parts[2].strip() else None
        except Exception:
            duration = None
        rows.append({
            "ext": parts[0].strip(),
            "filename": parts[1].strip(),
            "duration": duration,
            "site": (parts[3].strip() or "").lower() or None,
            "webpage_url": parts[4].strip() or None,
            "uploader": _unjson(parts[5]),
            "title": _unjson(parts[6]),
        })
    return rows


def _count_json_lines(path: str) -> int:
    count = 0
    try:
        with open(path, "rb") as fh:
            for raw in fh:
                if raw.lstrip().startswith(b"{"):
                    count += 1
    except Exception:
        pass
    return count


def _write_info_list(probe_out: str, info_file: str, keep: set[int] | None) -> int:
    """把探查輸出（一行一個 JSON）裡要下載的項目寫成一個 JSON 陣列，給 --load-info-json 用。"""
    written = 0
    index = -1
    with open(probe_out, "rb") as src, open(info_file, "wb") as dst:
        dst.write(b"[")
        for raw in src:
            line = raw.strip()
            if not line.startswith(b"{"):
                continue
            index += 1
            if keep is not None and index not in keep:
                continue
            if written:
                dst.write(b",\n")
            dst.write(line)
            written += 1
        dst.write(b"]")
    return written


def _move_no_clobber(src: Path, dst: Path) -> str:
    """把 src 搬到 dst，目的地已經有東西就不搬。回傳 'moved' / 'exists' / 錯誤訊息。"""
    last = ""
    for attempt in range(6):
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            if os.path.lexists(dst):
                return "exists"
            os.rename(src, dst)      # Windows：目的地已存在會失敗（FileExistsError），不會覆蓋
            return "moved"
        except FileExistsError:
            return "exists"
        except OSError as exc:       # 防毒／同步軟體短暫鎖檔
            last = f"{type(exc).__name__}: {exc}"
            time.sleep(0.3 * (attempt + 1))
    return last or "搬移失敗"


def _relocate_outputs(work_dir: Path, out_dir: Path,
                      reported: list[str]) -> tuple[list[str], list[str], list[str]]:
    """
    把工作資料夾裡 yt-dlp 回報的成品搬到輸出資料夾（保留相對路徑，例如播放清單的子資料夾）。
    回傳 (成品在輸出資料夾裡的路徑, 其中「目的地原本就有檔案、所以沒有搬」的路徑, 警告)。
    """
    finals: list[str] = []
    collided: list[str] = []
    warnings: list[str] = []
    for raw in reported:
        rel = _rel_inside(raw, work_dir)
        if rel is None:
            finals.append(raw)       # 不在工作資料夾裡（理論上不會發生）：照原樣回報，不搬
            continue
        src = Path(raw)
        dst = out_dir / rel
        finals.append(str(dst))
        if not src.is_file():
            continue
        # 同名的附屬檔（例如另存的字幕 <檔名>.en.vtt）：只認「這個成品的檔名 + .」開頭、而且不是暫存檔的
        stem_prefix = src.stem + "."
        try:
            siblings = [p for p in src.parent.iterdir()
                        if p != src and p.is_file() and p.name.startswith(stem_prefix)
                        and not _WORK_TEMP_NAME_RE.search(p.name) and not _FRAG_TEMP_RE.search(p.name)]
        except Exception:
            siblings = []
        result = _move_no_clobber(src, dst)
        if result == "exists":
            collided.append(str(dst))
        elif result != "moved":
            warnings.append(f"下載完成，但無法把 {src.name} 搬到輸出資料夾：{result}")
        for sib in siblings:
            sib_rel = _rel_inside(str(sib), work_dir)
            if sib_rel:
                _move_no_clobber(sib, out_dir / sib_rel)
    return finals, collided, warnings


def _isolated_run(base: list[str], dl_args: list[str], url: str, out_dir: Path, work_dir: Path,
                  echo: bool, path_file: str, meta_file: str, extra_skip=None) -> dict:
    """
    隔離下載（說明見本區開頭）。base = [yt-dlp, 一般參數…]（輸出樣板指向 work_dir），
    dl_args = 下載階段才加的 --print-to-file。回傳：
      rc / out / err / attempts / retry_warn   同 _run_with_retry
      reported   成品在 out_dir 裡的路徑（含先前就存在而略過的）
      already    其中先前就存在、這次沒有重新下載的路徑
      meta       同 _parse_meta
      warnings   額外的警告
    """
    res: dict = {"rc": 1, "out": "", "err": "", "attempts": 1, "retry_warn": [],
                 "reported": [], "already": [], "meta": {}, "warnings": []}
    probe_out = _new_tempfile(".probe.jsonl")
    probe_meta = _new_tempfile(".probe.txt")
    info_file = _new_tempfile(".infos.json")
    created = False
    try:
        # ---------- 1. 探查
        def _probe(extra: list[str]) -> tuple[int, str, int, list[dict]]:
            with open(probe_meta, "wb"):
                pass                 # --print-to-file 是附加寫入，重試前要清空
            prc, _unused, perr = run_cmd(
                base + extra + ["-j", "--print-to-file", _PROBE_TEMPLATE, probe_meta, url],
                echo_stdout=False, echo_stderr=echo, stdout_file=probe_out)
            return prc, perr, _count_json_lines(probe_out), _parse_probe(_read_lines(probe_meta))

        if echo:
            print("[mdl] 取得資訊中…", flush=True)
        impersonate: list[str] = []
        prc, perr, n_json, rows = _probe([])
        if n_json == 0 and prc != 0:
            skip = _skip_retry_reason(perr, "")
            if not skip and extra_skip is not None:
                try:
                    skip = extra_skip(perr, "")
                except Exception:
                    skip = None
            if skip:
                res["retry_warn"].append(skip)
                if echo:
                    print(f"[mdl] {skip}", flush=True)
            else:
                if echo:
                    print("[mdl] 第一次失敗，改用 --impersonate chrome 重試…", flush=True)
                prc2, perr2, n2, rows2 = _probe(["--impersonate", "chrome"])
                res["attempts"] = 2
                if n2:
                    prc, perr, n_json, rows = prc2, perr2, n2, rows2
                    impersonate = ["--impersonate", "chrome"]
                    res["retry_warn"].append("第一次下載失敗，改用 --impersonate chrome 後成功。")
                elif _impersonate_unsupported(perr2):
                    res["retry_warn"].append("這份 yt-dlp 不支援 --impersonate（需要 curl_cffi 版本），已略過重試。")
                else:
                    prc, perr = prc2, perr2
        res["rc"], res["err"] = prc, perr
        if rows:
            first = rows[0]
            res["meta"] = {"title": first["title"], "uploader": first["uploader"],
                           "duration": first["duration"], "site": first["site"],
                           "webpage_url": first["webpage_url"], "width": None, "height": None}
        if n_json == 0:
            return res               # 什麼都沒拿到：成敗由呼叫端依 rc / err 判讀

        # ---------- 2. 哪些項目的成品已經存在
        final_ext = _audio_final_ext(base)
        keep: set[int] | None = None
        if len(rows) == n_json and final_ext is not None:
            keep = set()
            for index, row in enumerate(rows):
                expected = _expected_output(row["filename"], row["ext"], final_ext)
                rel = _rel_inside(expected, work_dir) if expected else None
                dest = (out_dir / rel) if rel else None
                try:
                    done = bool(dest and dest.is_file() and dest.stat().st_size > 0)
                except Exception:
                    done = False
                if done:
                    res["already"].append(str(dest))
                else:
                    keep.add(index)
        res["reported"] = list(res["already"])
        if keep is not None and not keep:
            if echo:
                for path in res["already"]:
                    print(f"[mdl] 已存在，略過：{path}", flush=True)
            return res               # 全部都下載過了：不建立工作資料夾、不碰任何檔案

        # ---------- 3. 下載到工作資料夾（沿用探查到的資訊，不重新向網站要）
        _write_info_list(probe_out, info_file, keep)
        try:
            _create_work_dir(work_dir)
        except Exception as exc:
            res["rc"] = 1
            res["err"] = ((perr + "\n") if perr else "") + \
                f"ERROR: 無法在輸出資料夾建立工作資料夾 {work_dir.name}：{exc}"
            return res
        created = True
        drc, out, derr, attempts, retry_warn = _run_with_retry(
            base + impersonate + dl_args + ["--load-info-json", info_file], None,
            echo_stdout=echo, echo_stderr=echo)
        res["attempts"] = max(res["attempts"], attempts)
        res["retry_warn"].extend(w for w in retry_warn if w not in res["retry_warn"])
        res["out"] = out
        res["err"] = ((perr + "\n") if (perr and prc != 0) else "") + derr
        res["rc"] = drc if drc != 0 else prc
        meta = _parse_meta(_read_lines(meta_file))
        if meta:
            res["meta"] = meta

        # ---------- 4. 成品搬到輸出資料夾（絕不覆蓋）
        finals, collided, move_warn = _relocate_outputs(work_dir, out_dir, _dedupe(_read_lines(path_file)))
        res["reported"] = _dedupe(res["already"] + finals)
        res["already"].extend(collided)
        res["warnings"].extend(move_warn)
        return res
    finally:
        _cleanup(probe_out, probe_meta, info_file)
        if created and not _remove_work_dir(work_dir):
            res["warnings"].append(
                f"工作資料夾 {work_dir} 沒有刪乾淨（可能被防毒或同步軟體鎖住），"
                "裡面只有這次下載的暫存檔，可以手動刪除。")


_PHOTO_ERROR_KEYS = ("no video formats found", "there is no video in this post",
                     "no video could be found in this tweet")


def _ytdlp_step(url: str, mode: str, o: dict, env: dict, exe: Path, args: list[str],
                out_dir: Path, echo: bool, extra_skip=None, work_dir: Path | None = None) -> dict:
    """
    download() 的 yt-dlp 階段：實際下載，並把結果寫進 env（成敗一律以磁碟為準）。
    work_dir 有給（音訊）時走隔離下載（_isolated_run）：yt-dlp 只在工作資料夾裡動作，成品再搬到 out_dir。
    回傳照片階段需要的內部狀態：
      ran        有沒有真的跑到 yt-dlp
      blob       yt-dlp 的 stderr + stdout（判讀失敗原因用）
      fail_kind  判定失敗時 _photo_post_kind 的結果（不是「沒有影片」類的失敗就是 None）
      noise      照片有抓到時就沒有意義的警告（「只有照片，已略過重試」之類）
      partial    部分成功時的警告資訊（warning / base / photo_items / other_errors）
    """
    ctx: dict = {"ran": True, "blob": "", "fail_kind": None, "noise": [], "partial": None}
    started = time.time()

    # 一定要用 print-to-file 取得實際檔案路徑，不要用猜的
    path_file = _new_tempfile(".paths.txt")
    meta_file = _new_tempfile(".meta.txt")
    dl_args = ["--print-to-file", "after_move:filepath", path_file,
               "--print-to-file", _META_TEMPLATE, meta_file]
    already: set[str] = set()       # 隔離下載：成品先前就已經存在、這次沒有重新下載的路徑

    try:
        if work_dir is None:
            rc, out, err, attempts, retry_warn = _run_with_retry(
                [str(exe)] + list(args) + dl_args, url, echo_stdout=echo, echo_stderr=echo,
                extra_skip=extra_skip)
            reported = _dedupe(_read_lines(path_file))
            meta = _parse_meta(_read_lines(meta_file))
        else:
            iso = _isolated_run([str(exe)] + list(args), dl_args, url, out_dir, work_dir, echo,
                                path_file, meta_file, extra_skip=extra_skip)
            rc, out, err, attempts, retry_warn = (iso["rc"], iso["out"], iso["err"],
                                                  iso["attempts"], iso["retry_warn"])
            reported, meta = iso["reported"], iso["meta"]
            already = {os.path.normcase(os.path.abspath(p)) for p in iso["already"]}
            env["warnings"].extend(iso["warnings"])
        env["attempts"] = attempts
        env["warnings"].extend(retry_warn)
    finally:
        _cleanup(path_file, meta_file)

    ctx["blob"] = (err or "") + "\n" + (out or "")
    ctx["noise"] = [w for w in retry_warn if w in (
        _NO_VIDEO_SKIP_NOTE, _FB_PHOTO_URL_SKIP_NOTE, _FB_PHOTOS_FOUND_SKIP_NOTE)]

    # yt-dlp 可能回傳 0 卻沒真的產出檔案（例如缺 ffmpeg 時不會合併，只留下分離軌），
    # 所以一定要確認回報的路徑真的存在。
    existing = [p for p in reported if Path(p).is_file()]
    missing = [p for p in reported if p not in existing]
    files = [_file_entry(p) for p in existing]
    if work_dir is not None:
        # 隔離下載知道哪些成品是「先前就有」的（影片模式的 yt-dlp 分不出來，所以只有音訊有這個欄位）
        for entry in files:
            entry["existing"] = os.path.normcase(os.path.abspath(entry["path"])) in already
        old = sum(1 for entry in files if entry["existing"])
        if old and old == len(files):
            env["warnings"].append(
                f"全部 {old} 個檔案先前已經下載過，這次沒有重新下載（檔案仍在，已列入 files）。")
        elif old:
            env["warnings"].append(f"其中 {old} 個檔案先前已經下載過，沿用既有檔案。")

    env["files"] = files
    env["elapsed_sec"] = round(time.time() - started, 2)
    env["title"] = meta.get("title")
    env["uploader"] = meta.get("uploader")
    env["duration"] = meta.get("duration")
    env["site"] = meta.get("site")

    # 實際下載到的解析度超過使用者要的上限時要說清楚，不要悄悄給錯東西。
    # （例如 IG Reel 是 892x1584，height<=720 篩不到任何格式而掉到無上限的 fallback。）
    if files and mode == "mp4" and o["quality"] and o["quality"] != "best":
        try:
            cap = int(o["quality"])
        except (TypeError, ValueError):
            cap = None
        width, height = meta.get("width"), meta.get("height")
        if cap and isinstance(height, int) and height > cap:
            size_txt = f"{width}x{height}" if isinstance(width, int) else f"高度 {height}"
            note = ""
            if isinstance(width, int) and height > width:
                note = "（這是直式影片，短邊是寬度，height 上限篩不到任何格式）"
            env["warnings"].append(
                f"要求畫質上限 {cap}p，但此影片沒有符合的格式，實際下載 {size_txt}{note}。")

    # 判斷成敗一律以「磁碟上是否真的有檔案」為準：
    #   * exit code 非零但檔案存在 → 部分成功（例如輪播貼文中的照片沒有影片可抓）
    #   * exit code 為零但檔案不存在 → 仍然是失敗（例如缺 ffmpeg 沒合併）
    if rc != 0:
        if files:
            env["ok"] = True
            env["error"] = None
            env["hint"] = None
            env["log_tail"] = _log_tail(err)
            warning = _partial_failure_warning(out, err, len(files))
            env["warnings"].append(warning)
            err_lines = _dedupe([ln.strip().lower() for ln in ctx["blob"].splitlines()
                                 if ln.strip().startswith("ERROR:")])
            photo_errors = [ln for ln in err_lines if any(k in ln for k in _PHOTO_ERROR_KEYS)]
            ctx["partial"] = {
                "warning": warning,
                "base": _partial_failure_warning(out, err, len(files), images_tip=False),
                "photo_items": bool(photo_errors),
                "other_errors": len(err_lines) - len(photo_errors),
            }
            return ctx
        if work_dir is None:
            _note_cleanup(env, _cleanup_partials(out, err, out_dir, existing))
        _fail(env, compact_error(err, out),
              build_hint(err, out, _has_cookie_opts(o), o["login_browser_used"]), err)
        ctx["fail_kind"] = _photo_post_kind(ctx["blob"])
        return ctx

    if reported and not existing:
        no_ffmpeg = find_ffmpeg() is None
        if work_dir is None:
            _note_cleanup(env, _cleanup_partials(out, err, out_dir, existing))
        _fail(
            env,
            "yt-dlp 回報完成，但預期的輸出檔並不存在："
            + (missing[0] if missing else "(未知路徑)"),
            ("最可能是缺少 ffmpeg：影音軌各自下載完卻沒有合併，"
             "請執行「首次設定.bat」安裝 ffmpeg 後重跑。") if no_ffmpeg else
            "請確認輸出資料夾是否被防毒或同步軟體移動、刪除。",
            err)
        return ctx

    if missing:
        env["warnings"].append(f"有 {len(missing)} 個回報的檔案實際上不存在，已從結果中排除。")

    if not files:
        env["warnings"].append(
            "yt-dlp 回報成功但沒有輸出新檔案（可能因 --no-overwrites 而略過既有檔案）。")

    return ctx


# ------------------------------------------------- 影片模式的照片階段 ---
#
# 使用者不想自己判斷「這則貼文該用 video 還是 images」：影片模式貼了 IG / FB / X 的貼文網址時，
# 影片照舊由 yt-dlp 抓（畫質選擇、mp4/h264 偏好都不變），貼文裡的照片再由照片引擎補抓。
#
# 哪些網址要加跑照片階段（其餘一律不跑，行為與以前完全相同、不會呼叫 gallery-dl）：
#   IG   /p/<代碼>；/stories/…（限時動態一定要登入，所以只有帶了 cookie 才跑）。/reel/、/reels/、/tv/ 不跑。
#   X    /<帳號>/status/<數字>
#   FB   貼文／照片網址：/posts/、/permalink、story.php、/photo、/photos/、/share/p/。
#        影片網址（/videos/、/watch、/reel/、fb.watch、/share/v/、/share/r/）不跑。
_PP_IG_POST_RE = re.compile(
    r"^(?:https?://)?(?:www\.|m\.)?instagram\.com/(?:[^/?#]+/)?p/[A-Za-z0-9_-]+", re.IGNORECASE)
_PP_IG_STORIES_RE = re.compile(
    r"^(?:https?://)?(?:www\.|m\.)?instagram\.com/stories/[^/?#]+", re.IGNORECASE)
_PP_X_STATUS_RE = re.compile(
    r"^(?:https?://)?(?:(?:www|mobile)\.)?(?:x|twitter|fxtwitter|vxtwitter)\.com/[^/?#]+/status(?:es)?/\d+",
    re.IGNORECASE)
_PP_FB_RE = re.compile(r"^(?:https?://)?(?:[a-z0-9-]+\.)?facebook\.com(/[^#]*)", re.IGNORECASE)
_PP_FB_INCLUDE_RE = re.compile(
    r"/(?:posts/|permalink(?:\.php|[/?]|$)|story\.php|photo(?:\.php)?(?:[/?]|$)|photos/|share/p/)",
    re.IGNORECASE)
_PP_FB_EXCLUDE_RE = re.compile(r"/(?:videos/|watch(?:[/?]|$)|reel/|share/[vr]/)", re.IGNORECASE)


def _photo_pass_site(url: str, has_cookies: bool) -> str | None:
    """
    影片模式要不要加跑照片階段。回傳 'instagram' / 'instagram_stories' / 'twitter' / 'facebook'，
    或 None（不是「可能含照片的社群單篇貼文」）。has_cookies：照片階段用得到的 cookie
    （cookies 檔、--cookies-from-browser 或登入瀏覽器匯出的暫存檔）。
    """
    text = str(url or "").strip()
    if _PP_IG_POST_RE.match(text):
        return "instagram"
    if _PP_IG_STORIES_RE.match(text):
        return "instagram_stories" if has_cookies else None
    if _PP_X_STATUS_RE.match(text):
        return "twitter"
    match = _PP_FB_RE.match(text)
    if match and not _PP_FB_EXCLUDE_RE.search(match.group(1)) and _PP_FB_INCLUDE_RE.search(match.group(1)):
        return "facebook"
    return None


def _run_photo_pass(url: str, o: dict, out_dir: Path) -> dict:
    """
    照片階段 = 照片引擎（download_images）的「只抓照片」模式：gallery-dl 用 --filter 在下載前就把
    影片濾掉，IG 的 yt-dlp 備援也跳過影片那幾格，所以不會重抓 yt-dlp 已經下載的影片。
    沿用影片階段的 cookie；不沿用 --name（yt-dlp 的樣板語法）與 --extra-arg（yt-dlp 的參數）。
    檔名與 images 指令相同：<帳號>_<貼文ID>_<序號>.<副檔名>。絕不拋例外。
    """
    try:
        return download_images(
            url, out_dir=str(out_dir),
            cookies_file=o["cookies"], cookies_from_browser=o["cookies_from_browser"],
            _login_browser=o["login_browser_used"], _images_only=True,
            quiet=o["quiet"], json_mode=o["json_mode"])
    except Exception as exc:
        return _fail(_envelope("images", url), f"{type(exc).__name__}: {exc}", None)


def _merge_photo_pass(env: dict, ctx: dict, site: str, o: dict, get_photos) -> None:
    """
    把照片階段的結果併進影片階段的信封。規則（一律以磁碟為準）：
      * 只要有任何真實檔案就是 ok:true；files = 影片 + 照片。
      * 影片階段是因為「這則貼文沒有影片」而失敗、照片有抓到 → 乾淨的成功（error / hint 都是 null）。
      * 影片階段因為別的原因失敗、照片有抓到 → ok:true，影片的錯誤降級成一條 warning。
      * 影片階段因為別的原因失敗、照片也沒有 → 維持影片階段原本的 error / hint。
      * 影片成功、照片階段沒抓到東西或失敗 → 維持成功而且不出聲；只有 yt-dlp 自己說「貼文裡有幾格是照片」
        （也就是照片確實該有）時才補一條 warning。照片階段絕不會把成功的影片下載變成失敗。
    """
    video_ok = bool(env.get("ok"))
    vfiles = list(env.get("files") or [])
    fail_kind = ctx.get("fail_kind")
    info = {"ran": False, "engine": None, "found": 0, "error": None, "note": None, "elapsed_sec": None}
    env["photo_pass"] = info

    if not video_ok and not vfiles:
        if _cookie_failure_kind(ctx.get("blob") or ""):
            info["note"] = "cookie 來源本身讀不到，照片階段用的是同一份 cookie，已略過。"
            return
        if site == "instagram" and fail_kind != "no_video" and not (o["cookies"] or o["cookies_from_browser"]):
            # 未登入時 IG 的照片是靠 yt-dlp 同一個公開介面拿的；它剛剛才因為別的原因失敗
            # （需要登入、限流、貼文不存在…），再問一次只會多打幾次 IG。
            info["note"] = "未登入時 IG 的照片與影片走的是 yt-dlp 同一個公開介面，它剛剛已經失敗，不再重複請求。"
            return

    penv = get_photos()
    seen = {os.path.normcase(os.path.abspath(f["path"])) for f in vfiles}
    pfiles = [f for f in (penv.get("files") or [])
              if os.path.normcase(os.path.abspath(f["path"])) not in seen]
    info.update(ran=True, engine=penv.get("engine"), found=len(pfiles),
                error=None if pfiles else (penv.get("error") or "沒有找到照片。"),
                elapsed_sec=penv.get("elapsed_sec"))
    partial = ctx.get("partial") or {}

    if pfiles:
        env["files"] = vfiles + pfiles
        # 「只有照片、已略過重試」「若要連照片一起下載請改用 images」在照片已經抓到之後都是雜訊
        drop = set(ctx.get("noise") or [])
        if partial.get("photo_items"):
            drop.add(partial.get("warning"))
        env["warnings"] = [w for w in env["warnings"] if w not in drop]
        if partial.get("photo_items") and partial.get("other_errors"):
            env["warnings"].append(partial["base"])
        elif partial.get("photo_items"):
            env["log_tail"] = None          # 只剩「照片那幾格沒有影片」的訊息，照片已經抓到了
        for w in penv.get("warnings") or []:
            if w not in env["warnings"]:
                env["warnings"].append("照片：" + w)
        for key in ("title", "uploader", "site"):
            if not env.get(key) and penv.get(key):
                env[key] = penv[key]
        if not video_ok:
            video_error, video_hint = env.get("error"), env.get("hint")
            env["ok"], env["error"], env["hint"] = True, None, None
            if fail_kind is None:
                env["warnings"].append(
                    f"影片的部分下載失敗（{video_error}），只下載到貼文裡的 {len(pfiles)} 張照片。"
                    + (f"關於影片：{video_hint}" if video_hint else ""))
            else:
                env["log_tail"] = None      # 純照片貼文：yt-dlp 的「沒有影片」不是錯誤
        return

    photo_error = info["error"]
    photo_hint = penv.get("hint") or ""
    if video_ok:
        if partial.get("photo_items"):
            env["warnings"] = [w for w in env["warnings"] if w != partial.get("warning")]
            env["warnings"].append(
                partial["base"] + f"已自動嘗試下載貼文裡的照片，但沒有成功：{photo_error}" + photo_hint)
        return
    if fail_kind:
        head = {
            "no_video": "這則貼文沒有影片（yt-dlp 只下載影片）",
            "fb_photo_url": "這是 Facebook 的照片／貼文網址，yt-dlp 只支援影片",
        }.get(fail_kind, "yt-dlp 抓不到這則 Facebook 貼文的影片（純照片貼文實測就是這個反應）")
        env["hint"] = f"{head}；已自動改抓貼文裡的照片，但也沒有成功：{photo_error}" + photo_hint
        # 照片也沒有 → 「只有照片」這個說法不成立（例如純文字貼文），改成中性的描述
        env["warnings"] = [_NO_VIDEO_NO_PHOTO_NOTE if w == _NO_VIDEO_SKIP_NOTE else w for w in env["warnings"]]


def _count_media(env: dict) -> None:
    counts = {"images": 0, "videos": 0, "other": 0, "existing": 0}
    for f in env.get("files") or []:
        counts[{"image": "images", "video": "videos"}.get(f.get("kind"), "other")] += 1
        if f.get("existing"):
            counts["existing"] += 1
    env["media_counts"] = counts


def _note_cleanup(env: dict, removed: list[str]) -> None:
    if removed:
        env["warnings"].append(
            f"已清除本次下載失敗留下的 {len(removed)} 個暫存殘檔："
            + "、".join(Path(p).name for p in removed[:3])
            + ("…" if len(removed) > 3 else ""))


def _dedupe(items: list[str]) -> list[str]:
    seen, result = set(), []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def _parse_meta(lines: list[str]) -> dict:
    """解析 metadata print-to-file（只取第一筆，清單下載時代表第一個項目）。"""
    if not lines:
        return {}
    parts = lines[0].split(_META_SEP)
    while len(parts) < 7:
        parts.append("")

    def _as_int(text: str) -> int | None:
        try:
            return int(float(text)) if text.strip() else None
        except Exception:
            return None

    return {
        "title": parts[0].strip() or None,
        "uploader": parts[1].strip() or None,
        "duration": _as_int(parts[2]),
        "site": (parts[3].strip() or "").lower() or None,
        "webpage_url": parts[4].strip() or None,
        "width": _as_int(parts[5]),
        "height": _as_int(parts[6]),
    }


# -------------------------------------------------------------- images ---
#
# 照片引擎：gallery-dl.exe。yt-dlp 只抓影片——IG 輪播裡的照片會被略過，X / FB 的照片根本不支援。
#
# 實測（gallery-dl 1.32.14，2026-09-30，未登入）：
#   * X 單篇推文（多張照片、影片）、FB 照片網址與 FB 貼文網址（多圖）：免登入可抓。
#   * IG 單篇貼文網址（/p/、/reel/）：gallery-dl 一律呼叫 /api/v1/media/<id>/info/，未登入會被導到
#     登入頁（"HTTP redirect to login page"）。但 yt-dlp 的 IG 抽取器走公開介面，未登入也拿得到每一格的
#     原始尺寸圖片網址（與 gallery-dl 登入後抓到的網址逐字相同），所以這種情況自動改用 yt-dlp 備援。
#
# 可攜原則：--config-ignore（不讀使用者自己的 gallery-dl 設定檔）、cache.file=null（不在
# %APPDATA%\gallery-dl 建立快取資料庫）、cookies-update=false（不回寫使用者的 cookies.txt）。

_IMG_TEMP_RESERVE = 10          # gallery-dl 下載中的暫存檔只多一個 ".part"
_IMG_TAIL_RESERVE = 35          # 檔名裡 "_<貼文ID，最長約 20>_<序號>.<副檔名>" 的固定成本
_IMG_DEFAULT_MAX_FILES = 100
_IMG_MAX_FILES_LIMIT = 10000
_IMG_TIMEOUT_SEC = 1800

# --- 整批下載（images --all / download_all=true）---
# IG 某個帳號的所有貼文、自己的珍藏（全部或某個珍藏分類）。一定要登入 cookie。
# 抓到的檔案放進輸出資料夾底下以帳號／珍藏分類命名的子資料夾；不設檔案數上限、不設逾時；
# 每個檔案下載完之後隨機等待一段時間（常態分佈，見 _pace_args），降低被判定為機器人的機率。
# 另外 gallery-dl 對 IG 的 API 請求（翻頁）本來就有內建的 6～12 秒隨機間隔，這裡不去動它。
_BULK_SLEEP_DEFAULT = {"mean": 2.0, "min": 0.0, "max": 4.0}
# instagram.com/<第一段> 不是帳號的那些路徑
_IG_NOT_USER = {"p", "reel", "reels", "tv", "explore", "stories", "accounts", "direct", "about",
                "developer", "legal", "api", "web", "graphql", "challenge", "share", "s", "ar"}
_IG_HANDLE_RE = re.compile(r"^@?([A-Za-z0-9_.]{1,30})$")
_IG_BULK_RE = re.compile(
    r"^https?://(?:www\.|m\.)?instagram\.com/([A-Za-z0-9_.]{1,30})"
    r"(?:/(posts|reels|tagged|saved)(?:/([^/?#]+)(?:/([^/?#]+))?)?)?/?(?:[?#].*)?$", re.IGNORECASE)

_IMAGE_EXTS = {"jpg", "jpeg", "jfif", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff"}
_VIDEO_EXTS = {"mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "ts", "3gp"}
_VIDEO_SITE_HOSTS = ("youtube.com", "youtu.be", "vimeo.com", "bilibili.com", "b23.tv",
                     "tiktok.com", "twitch.tv", "dailymotion.com", "nicovideo.jp")
# gallery-dl 的 subcategory 屬於「帳號頁／清單」而不是單篇貼文的那些
_LISTING_SUBCATEGORIES = {
    "user", "posts", "reels", "tagged", "stories", "highlights", "saved", "tag", "collection",
    "timeline", "media", "tweets", "replies", "likes", "bookmark", "list", "search", "photos",
    "albums", "followed", "following", "community",
}

# 每個檔案下載完（after）或因已存在而略過（skip）時，gallery-dl 印一行到暫存檔。
# 欄位：路徑、站台、子類別、帳號、貼文 ID、FB 的 set_id、副檔名、貼文內文（!j = JSON 字串，不會換行）。
# 不存在的欄位 gallery-dl 會印成字串 None。內文放最後一欄，解析時用 maxsplit 防萬一。
_GDL_META_FMT = _META_SEP.join([
    "{_path}",
    "{category}",
    "{subcategory}",
    "{username|author[name]|user[name]}",
    "{post_shortcode|tweet_id|post_id|id}",
    "{set_id}",
    "{extension}",
    "{description|content|caption|title!j}",
])

_WIN_BAD_CHARS_RE = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
_IG_POST_RE = re.compile(
    r"^https?://(?:www\.|m\.)?instagram\.com/(?:[^/?#]+/)?(?:p|reels?|tv)/([A-Za-z0-9_-]+)",
    re.IGNORECASE)
_X_STATUS_RE = re.compile(
    r"^https?://(?:(?:www|mobile)\.)?(?:x|twitter|fxtwitter|vxtwitter)\.com/[^/?#]+/status(?:es)?/(\d+)",
    re.IGNORECASE)
_FB_PHOTOS_PATH_RE = re.compile(
    r"^https?://(?:[a-z0-9-]+\.)?facebook\.com/[^/?#]+/photos/(?:[^/?#]+/)?(\d{6,})/?(?:[?#].*)?$",
    re.IGNORECASE)
_FB_PCB_RE = re.compile(r"[?&]set=pcb\.(\d+)", re.IGNORECASE)
_FB_STORY_PHP_RE = re.compile(
    r"^https?://(?:[a-z0-9-]+\.)?facebook\.com/story\.php/?\?(.+)$", re.IGNORECASE)
_FB_SHARE_POST_RE = re.compile(
    r"^https?://(?:[a-z0-9-]+\.)?facebook\.com/share/p/[A-Za-z0-9_-]+", re.IGNORECASE)
# gallery-dl 會當成「單篇貼文／單張照片」處理的 FB 網址（FacebookPhotoExtractor / FacebookSetExtractor）。
# 影片模式的照片階段只接受這些：相片牆、相簿清單、個人檔案一律不抓。
_FB_SINGLE_POST_RE = re.compile(
    r"^https?://(?:[a-z0-9-]+\.)?facebook\.com/(?:"
    r"photo(?:\.php)?/?\?(?:[^#]*&)?fbid=\d+"
    r"|permalink\.php\?"
    r"|(?:[^/?#]+/){1,3}(?:posts|permalink)/[^/?#]+"
    r")", re.IGNORECASE)

# --- 「只抓照片」模式（影片模式的照片階段用）---
# gallery-dl 的 --filter 在下載前逐檔求值：副檔名是影片的直接略過（不會佔用頻寬），所以不會重抓
# yt-dlp 已經下載的影片；序號 {num} 不受影響，檔名與 images 指令抓到的完全相同。
# 另外用 abort() 擋住「帳號頁／相片牆」類的抽取器：照片階段是使用者沒有明講就自動跑的，
# 絕不能因為網址長得像貼文就把整個帳號的照片抓下來。
_PHOTO_PASS_VIDEO_EXTS = tuple(sorted(_VIDEO_EXTS | {"f4v", "wmv", "mpg", "mpeg", "ogv", "m3u8", "mpd", "m4s"}))
_PHOTO_PASS_ABORT_SUBCATEGORIES = tuple(sorted(
    (_LISTING_SUBCATEGORIES - {"stories", "highlights"}) | {"avatar", "info", "stories-tray"}))
_PHOTO_PASS_FILTER = (f"abort() if subcategory in {_PHOTO_PASS_ABORT_SUBCATEGORIES!r} "
                      f"else (extension or '').lower() not in {_PHOTO_PASS_VIDEO_EXTS!r}")
_PHOTO_PASS_TIMEOUT_SEC = 600
_GDL_LOGIN_KEYS = (
    "redirect to login page", "accounts/login", "authrequired", "authorizationerror",
    "login required", "needed to access", "login to view", "log in to", "sign in",
    "checkpoint required", "private account", "this account is private", "protected tweets",
)


def _ig_bulk_target(url: str) -> tuple[dict | None, str | None]:
    """
    整批下載時解析 IG 網址，回傳 (目標, 錯誤)。目標 = {url, folder, label}；不是 IG 的帳號／珍藏網址
    時兩者都是 None（照一般網址處理，只是不設檔案數上限）。

      instagram.com/<帳號>/                     → 該帳號的所有貼文        → 子資料夾 <帳號>
      instagram.com/<帳號>/reels/、/tagged/     → Reels／被標註的貼文     → <帳號>、<帳號>_tagged
      instagram.com/<自己>/saved/               → 自己的全部珍藏          → <自己>_saved
      instagram.com/<自己>/saved/<分類>/<ID>/   → 某個珍藏分類            → <自己>_saved_<分類>
    """
    match = _IG_BULK_RE.match(url or "")
    if not match or match.group(1).lower() in _IG_NOT_USER:
        return None, None
    user, kind, name, cid = match.group(1), (match.group(2) or "posts").lower(), match.group(3), match.group(4)
    base = f"https://www.instagram.com/{user}"
    if kind != "saved":
        folder = f"{user}_tagged" if kind == "tagged" else user
        label = {"posts": "所有貼文", "reels": "所有 Reels", "tagged": "被標註的貼文"}[kind]
        return {"url": f"{base}/{kind}/", "folder": folder, "label": f"@{user} 的{label}"}, None
    if not name or name.lower() == "all-posts":
        return {"url": f"{base}/saved/", "folder": f"{user}_saved", "label": f"@{user} 的全部珍藏"}, None
    if not cid or not cid.isdigit():
        return None, ("珍藏分類的網址要包含分類的數字 ID，例如 "
                      "https://www.instagram.com/<你的帳號>/saved/<分類名稱>/<一串數字>/。")
    title = urllib.parse.unquote(name)
    return {"url": f"{base}/saved/{name}/{cid}/",
            "folder": _safe_component(f"{user}_saved_{title}", 80),
            "label": f"@{user} 的珍藏分類「{title}」"}, None


def _bulk_sleep_cfg(profiles: dict) -> dict:
    """整批下載時每個檔案之間的等待秒數設定（config\\profiles.json 的 bulk_sleep；壞值用預設）。"""
    cfg = dict(_BULK_SLEEP_DEFAULT)
    user_cfg = profiles.get("bulk_sleep")
    if isinstance(user_cfg, dict):
        for key in cfg:
            try:
                cfg[key] = max(0.0, float(user_cfg[key]))
            except (KeyError, TypeError, ValueError):
                pass
    if not cfg["min"] <= cfg["mean"] <= cfg["max"]:
        cfg = dict(_BULK_SLEEP_DEFAULT)
    return cfg


def _pace_args(cfg: dict) -> list[str]:
    """
    讓 gallery-dl 在「每個檔案下載完之後」隨機等待：常態分佈，平均 mean 秒，標準差取 (max-min)/6
    （±3 個標準差剛好落在 min～max，約 68% 落在平均 ±1 個標準差內），超出範圍的夾回 min／max。

    gallery-dl 內建的 --sleep 只支援固定值或均勻分佈，所以改用它的 python 後處理器在 after 事件
    （檔案下載完成）執行一段運算式；已存在而略過的檔案不會觸發，重跑時不會白等。
    運算式裡不能有雙引號與 %：GUI 是經由 cmd.exe 啟動 gallery-dl 的。
    """
    if cfg["max"] <= 0:
        return []
    sigma = (cfg["max"] - cfg["min"]) / 6.0
    expr = ("__import__('time').sleep(min({max:.3f},max({min:.3f},"
            "__import__('random').gauss({mean:.3f},{sigma:.3f}))))").format(sigma=sigma, **cfg)
    return ["-P", "python", "-O", "event=after", "-O", "expression=" + expr]


def _site_from_url(url: str) -> str | None:
    host = (urllib.parse.urlsplit(url or "").hostname or "").lower()
    if not host:
        return None
    for name, keys in (("instagram", ("instagram.com",)),
                       ("twitter", ("x.com", "twitter.com")),
                       ("facebook", ("facebook.com", "fb.com", "fb.watch"))):
        if any(host == k or host.endswith("." + k) for k in keys):
            return name
    return None


def _is_video_site(url: str) -> bool:
    host = (urllib.parse.urlsplit(url or "").hostname or "").lower()
    return any(host == h or host.endswith("." + h) for h in _VIDEO_SITE_HOSTS)


def _url_post_token(url: str) -> str | None:
    """網址裡代表這則貼文的 ID（清殘檔時用來比對檔名，拿不到就不清）。"""
    for regex in (_IG_POST_RE, _X_STATUS_RE):
        match = regex.match(url or "")
        if match:
            return match.group(1)
    match = re.search(r"[?&]fbid=(\d{6,})", url or "")
    return match.group(1) if match else None


def _normalize_image_url(url: str) -> tuple[str, list[str]]:
    """
    修正會讓 gallery-dl 抓錯範圍的網址，回傳 (網址, 警告)。

    實測：facebook.com/<粉專>/photos/<照片ID>/ 會被 gallery-dl 當成「整個粉專的相片牆」
    （FacebookPhotosExtractor），一路往下抓整個粉專的照片。這裡改寫成單張照片網址。
    """
    notes: list[str] = []
    match = _FB_PHOTOS_PATH_RE.match(url)
    if match:
        fixed = f"https://www.facebook.com/photo/?fbid={match.group(1)}"
        notes.append(f"已把 Facebook 照片網址改寫成 {fixed}（原網址會被當成整個粉專的相片牆）。")
        url = fixed
    # 實測（gallery-dl 1.32.14）：facebook.com/story.php?story_fbid=…&id=… 會被當成名叫 "story.php" 的
    # 個人檔案（FacebookUserExtractor → 相片牆），而 permalink.php 同樣的參數才是單篇貼文。
    match = _FB_STORY_PHP_RE.match(url)
    if match:
        query = urllib.parse.parse_qs(match.group(1).split("#", 1)[0])
        story_id = (query.get("story_fbid") or [""])[0]
        owner_id = (query.get("id") or [""])[0]
        if story_id and owner_id:
            fixed = ("https://www.facebook.com/permalink.php?"
                     + urllib.parse.urlencode({"story_fbid": story_id, "id": owner_id}))
            notes.append(f"已把 Facebook 貼文網址改寫成 {fixed}（story.php 會被 gallery-dl 當成個人檔案）。")
            url = fixed
    pcb = _FB_PCB_RE.search(url)
    if pcb and "/media/set" not in url.lower():
        notes.append("這張 Facebook 照片屬於一則多圖貼文，本次只下載這一張；要整則貼文請改用 "
                     f"https://www.facebook.com/media/set/?set=pcb.{pcb.group(1)} 或貼文本身的網址。")
    return url, notes


_BROWSER_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
               "(KHTML, like Gecko) Chrome/131.0 Safari/537.36")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):   # 不自動跟轉址：我們只要 Location
        return None


def _resolve_fb_share(url: str, timeout: int = 15) -> str | None:
    """
    facebook.com/share/p/<代碼>/ 是 FB「分享 → 複製連結」給的轉址短網址，gallery-dl 與 yt-dlp 都不認得。
    用一次不帶 cookie 的請求讀它的 Location，轉到貼文／照片本身的網址就回傳，否則回傳 None
    （轉到登入頁、代碼無效、被擋……一律當成解析不了，由呼叫端照原網址處理）。最多跟 3 層。
    """
    opener = urllib.request.build_opener(_NoRedirect)
    current = url
    for _ in range(3):
        try:
            req = urllib.request.Request(current, headers={"User-Agent": _BROWSER_UA,
                                                           "Accept": "text/html,*/*;q=0.8"})
            with opener.open(req, timeout=timeout):
                return None                      # 200：沒有轉址
        except urllib.error.HTTPError as exc:
            if exc.code not in (301, 302, 303, 307, 308):
                return None
            location = exc.headers.get("Location") if exc.headers else None
            if not location:
                return None
            current = urllib.parse.urljoin(current, location)
        except Exception:
            return None
        host = _host_of(current)
        if not (host == "facebook.com" or host.endswith(".facebook.com")):
            return None
        path = urllib.parse.urlsplit(current).path.lower()
        if path.startswith(("/login", "/checkpoint", "/unsupportedbrowser")):
            return None
        if not _FB_SHARE_POST_RE.match(current) and "/share/" not in path:
            return current
    return None


def _image_name_budget(out_dir: Path) -> tuple[int, list[str]]:
    """依輸出資料夾長度算出檔名可用的字元數（Windows MAX_PATH=260，LongPathsEnabled=0）。"""
    if os.name != "nt":
        return 150, []
    dir_len = len(str(out_dir))
    budget = _MAX_PATH - _IMG_TEMP_RESERVE - (dir_len + 1)
    warnings: list[str] = []
    if budget < _MIN_NAME_BUDGET:
        warnings.append(
            f"輸出資料夾路徑已經有 {dir_len} 個字元，逼近 Windows 的 260 字元上限："
            "檔名只能留最短的長度，仍有可能下載失敗，建議改用較短的輸出資料夾（例如 D:\\dl）。")
        budget = _MIN_NAME_BUDGET
    return min(budget, 150), warnings


# gallery-dl 的 IG 抽取器裡，項目是「限時動態」的子類別（網址 /stories/<帳號>/、/stories/highlights/<ID>/、
# /<帳號>/highlights/、/stories/me/）
_IG_STORY_SUBCATEGORIES = ("stories", "highlights", "stories-tray")


def _image_filename_args(budget: int) -> list[str]:
    """
    各站台的檔名樣板：<帳號>_<貼文ID>_<序號>.<副檔名>；
    IG 限時動態是 <帳號>_story_<日期>_<該則的代碼>.<副檔名>。
    必須用 extractor.<站台>.filename 設定，不能用 -f：-f 是設在最上層，
    gallery-dl 的設定查找是「最上層優先」，會把每個站台的設定都蓋掉（實測）。
    """
    user_cap = max(8, min(40, budget - _IMG_TAIL_RESERVE))
    generic_cap = max(16, min(120, budget - 30))
    formats = {
        # IG 的帳號最長 30 字；貼文代碼約 11 字
        "instagram": f"{{username[:{user_cap}]}}_{{post_shortcode|shortcode}}_{{num}}.{{extension}}",
        # X 用原作者（author），轉推時 user 會是轉推的人
        "twitter": f"{{author[name][:{user_cap}]}}_{{tweet_id}}_{{num}}.{{extension}}",
        # FB 的 username 是粉專顯示名稱（可能很長、含空白）；id 是照片 ID
        "facebook": f"{{username[:{user_cap}]}}_{{id}}_{{num}}.{{extension}}",
    }
    args: list[str] = []
    for category, fmt in formats.items():
        args += ["-o", f"extractor.{category}.filename={fmt}"]
    # IG 限時動態／精選動態（實測 gallery-dl 1.32.14）：post_shortcode 是「帳號 ID」換算出來的（每個帳號固定，
    # 例如 natgeo 永遠是 DAK8），num 是當下的排列位置——照上面的樣板，隔天的第一則限時動態會和今天的撞名
    # 而被當成「已存在」略過。改用每一則自己的日期與代碼（shortcode，由 media_id 換算，固定不變）。
    # 子類別層級的設定（extractor.instagram.stories.*）會蓋過站台層級的，一般貼文的檔名不受影響。
    # {date!s:.10} = 日期字串的前 10 個字（YYYY-MM-DD）；刻意不用 {date:%Y%m%d}：GUI 是經由 cmd.exe 啟動
    # gallery-dl 的，%Y% 這種寫法有機會被當成環境變數展開。
    story_fmt = f"{{username[:{user_cap}]}}_story_{{date!s:.10}}_{{shortcode}}.{{extension}}"
    for subcategory in _IG_STORY_SUBCATEGORIES:
        args += ["-o", f"extractor.instagram.{subcategory}.filename={story_fmt}"]
    # 其他 gallery-dl 支援的站台：<站台>_<原始檔名>.<副檔名>
    args += ["-o", f"extractor.filename={{category}}_{{filename[:{generic_cap}]}}.{{extension}}"]
    return args


def _safe_component(text, limit: int) -> str:
    """把任意字串變成 Windows 可用的檔名片段。"""
    s = _WIN_BAD_CHARS_RE.sub("_", str(text or "")).strip()
    s = s[:max(1, limit)].rstrip(" .")
    return s or "_"


def _sniff_media(path: Path) -> str:
    """看檔頭判斷實際內容：'image' / 'video' / 'html'（錯誤頁）/ 'unknown'。"""
    try:
        with open(path, "rb") as fh:
            head = fh.read(64)
    except Exception:
        return "unknown"
    if (head.startswith(b"\xff\xd8\xff") or head.startswith(b"\x89PNG\r\n\x1a\n")
            or head[:6] in (b"GIF87a", b"GIF89a")
            or (head[:4] == b"RIFF" and head[8:12] == b"WEBP")
            or head[:4] in (b"II*\x00", b"MM\x00*")):
        return "image"
    if head[4:8] == b"ftyp":
        brand = head[8:12].lower()
        if brand in (b"heic", b"heix", b"hevc", b"heim", b"heis", b"mif1", b"msf1", b"avif", b"avis"):
            return "image"
        return "video"
    if head.startswith(b"\x1a\x45\xdf\xa3") or head.startswith(b"FLV") or (
            head[:4] == b"RIFF" and head[8:11] == b"AVI"):
        return "video"
    text = head.lstrip().lower()
    if text.startswith((b"<!doctype", b"<html", b"<?xml", b"<head", b"{", b"[")) or b"<html" in text:
        return "html"
    return "unknown"


def _media_kind(path: Path, sniffed: str) -> str:
    if sniffed in ("image", "video"):
        return sniffed
    ext = path.suffix.lstrip(".").lower()
    if ext in _IMAGE_EXTS:
        return "image"
    if ext in _VIDEO_EXTS:
        return "video"
    return "other"


def _parse_gdl_meta(lines: list[str], downloaded: bool) -> list[dict]:
    rows: list[dict] = []
    for line in lines:
        parts = line.split(_META_SEP, 7)
        while len(parts) < 8:
            parts.append("None")

        def _v(text: str):
            text = (text or "").strip()
            return None if text in ("", "None") else text

        desc = _v(parts[7])
        if desc and desc.startswith('"'):
            try:
                desc = json.loads(desc)
            except Exception:
                pass
        rows.append({
            "path": parts[0].strip(),
            "site": _v(parts[1]),
            "subcategory": _v(parts[2]),
            "uploader": _v(parts[3]),
            "post_id": _v(parts[4]),
            "set_id": _v(parts[5]),
            "ext": _v(parts[6]),
            "description": desc if isinstance(desc, str) else None,
            "downloaded": downloaded,
        })
    return rows


def _stdout_paths(stdout: str, out_dir: Path) -> list[tuple[str, bool]]:
    """
    gallery-dl 的 stdout：下載完成的檔案印路徑，已存在而略過的印 "# 路徑"。
    只當成輔助來源（主要看 --Print-to-file），而且之後一律再到磁碟上確認。
    """
    found: list[tuple[str, bool]] = []
    for raw in (stdout or "").splitlines():
        line = raw.strip()
        skipped = line.startswith("# ")
        if skipped:
            line = line[2:].strip()
        if not line or not os.path.isabs(line):
            continue
        try:
            if Path(line).resolve().is_relative_to(out_dir):
                found.append((line, not skipped))
        except Exception:
            continue
    return found


def _collect_media_files(candidates: list[tuple[str, bool]], out_dir: Path) -> tuple[list[dict], list[str]]:
    """
    以磁碟為準整理出結果檔案：必須存在、非空、而且不是 HTML 錯誤頁。
    candidates：(路徑, 是否為本次新下載)。回傳 (files, warnings)。
    本次新下載、位於輸出資料夾內、內容卻是 HTML 的檔案會被刪除（那是錯誤頁，不是照片）。
    """
    files: list[dict] = []
    warnings: list[str] = []
    seen: set[str] = set()
    missing = empty = 0
    for raw, downloaded in candidates:
        p = Path(raw)
        if not p.is_absolute():
            p = out_dir / p
        key = os.path.normcase(os.path.abspath(str(p)))
        if key in seen:
            continue
        seen.add(key)
        try:
            if not p.is_file():
                missing += 1
                continue
            size = p.stat().st_size
        except Exception:
            missing += 1
            continue
        if size <= 0:
            empty += 1
            continue
        sniffed = _sniff_media(p)
        if sniffed == "html":
            note = f"{p.name} 的內容是網頁（HTML 錯誤頁）而不是照片或影片，已排除"
            try:
                if downloaded and p.resolve().is_relative_to(out_dir):
                    p.unlink()
                    note += "並刪除"
            except Exception:
                pass
            warnings.append(note + "。")
            continue
        entry = _file_entry(str(p))
        entry["kind"] = _media_kind(p, sniffed)
        entry["existing"] = not downloaded
        files.append(entry)
    if missing:
        warnings.append(f"有 {missing} 個回報的檔案實際上不存在，已從結果中排除。")
    if empty:
        warnings.append(f"有 {empty} 個檔案是 0 位元組，已從結果中排除。")
    return files, warnings


def _list_part_files(out_dir: Path) -> set[str]:
    try:
        return {p.name for p in out_dir.iterdir() if p.name.endswith(".part")}
    except Exception:
        return set()


def _cleanup_image_partials(out_dir: Path, before: set[str], token: str | None,
                            since: float) -> list[str]:
    """
    清掉本次 gallery-dl 失敗留下的 .part。保守規則：
      只看輸出資料夾這一層、副檔名是 .part、執行前不存在、執行期間才寫入、
      而且檔名含有這則貼文的 ID（拿不到 ID 就完全不清）。
    """
    removed: list[str] = []
    if not token:
        return removed
    try:
        items = list(out_dir.iterdir())
    except Exception:
        return removed
    for p in items:
        name = p.name
        if not name.endswith(".part") or name in before or token not in name:
            continue
        try:
            if p.is_file() and p.stat().st_mtime >= since - 2:
                p.unlink()
                removed.append(str(p))
        except Exception:
            pass
    return removed


_GDL_COOKIE_ISSUE_RE = re.compile(r"\[(?:warning|error)\]\s*cookies:\s*(.+)$", re.IGNORECASE)


def _gdl_cookie_issue(stderr: str) -> str | None:
    """
    gallery-dl 載入 cookie 失敗時只印一行 warning 就照樣「未登入」繼續跑（實測：
    cookies.txt 不存在、瀏覽器名稱不認得都是這樣）。一定要撈出來，否則使用者以為有帶到 cookie。
    """
    for line in (stderr or "").splitlines():
        match = _GDL_COOKIE_ISSUE_RE.search(line.strip())
        if match:
            return match.group(1).strip()[:300]
    return None


def _gdl_compact_error(stderr: str, stdout: str = "", rc: int | None = None) -> str:
    """
    gallery-dl 的錯誤行長這樣：[instagram][error] HTTP redirect to login page (...)
    stdout 只有檔案路徑，不能拿來當錯誤訊息。實測 gallery-dl 也可能「沒印任何錯誤卻回傳非零」
    （例如列舉 IG 帳號頁時，內部一個 debug 等級的 401 就讓結束代碼變成 4）。
    """
    rows = [ln.strip() for ln in (stderr or "").splitlines() if ln.strip()]
    errors = [ln for ln in rows if "][error]" in ln.lower()]
    if not errors:
        errors = [ln for ln in rows if "][warning]" in ln.lower()]
    if not errors:
        code = f"（結束代碼 {rc}）" if rc is not None else ""
        return f"gallery-dl 執行失敗{code}，但沒有輸出錯誤訊息。"
    msg = errors[-1]
    # 「請加 --verbose 回報 bug」那一大段對使用者沒幫助
    msg = re.sub(r"\.?\s*Please run gallery-dl again with the --verbose flag.*$", "", msg, flags=re.I)
    msg = re.sub(r"\s+", " ", msg).strip()
    return msg[:500]


def build_image_hint(stderr: str, stdout: str = "", has_cookies: bool = False,
                     url: str = "", cookie_issue: str | None = None,
                     login_browser: bool = False) -> str | None:
    """
    images 指令（gallery-dl，必要時加 yt-dlp 備援）失敗時的建議。
    has_cookies：本次「實際生效」的 cookie（載入失敗的不算）。帶了 cookie 就不再叫人加 cookie。
    login_browser：生效的 cookie 來自登入瀏覽器 → 仍被要求登入時，多半是登入瀏覽器沒登入該網站。
    """
    login_browser = bool(login_browser and has_cookies)
    blob = (stderr or "") + "\n" + (stdout or "")
    low = blob.lower()
    site = _site_from_url(url)

    # 最優先：cookie 根本沒載入成功（gallery-dl 只印 warning 就當作未登入繼續跑）
    if cookie_issue:
        source_like = re.search(r"unsupported browser|no such file|errno 2|not found|netscape|invalid|format",
                                cookie_issue, re.IGNORECASE)
        return ("cookie 沒有載入成功（" + cookie_issue + "），所以本次其實是「未登入」："
                + _cookie_failure_hint("source" if source_like else "db", cookie_issue))
    cookie_kind = _cookie_failure_kind(blob)
    if cookie_kind:
        return _cookie_failure_hint(cookie_kind, blob)

    if "unsupported url" in low:
        if not re.match(r"^https?://", url or "", re.IGNORECASE):
            return "網址格式不正確：請貼完整的貼文網址（以 https:// 開頭）。"
        if _is_video_site(url):
            return ("這是影片網站的網址，照片引擎（gallery-dl）不處理：請改用 video / audio 指令"
                    "（agent 工具 mdl_download_video / mdl_download_audio）。")
        return ("gallery-dl 不支援這個網站或這種網址格式：請貼「單篇貼文」的網址——"
                "IG：instagram.com/p/<代碼>/；X：x.com/<帳號>/status/<數字>；"
                "FB：facebook.com/photo/?fbid=<數字> 或 facebook.com/<粉專>/posts/<ID>。"
                "如果要的是影片，請改用 video 指令。")

    # 路徑超過 260 字元時 gallery-dl 開檔失敗後會嘗試建資料夾，最後浮出的是 WinError 183（實測）
    path_keys = ("unable to open for writing", "no such file or directory", "filename too long",
                 "file name too long", "path too long", "errno 2", "errno 36", "errno 28",
                 "no space left", "winerror 206", "winerror 183", "winerror 3]")
    if any(k in low for k in path_keys):
        return ("輸出路徑可能過長（Windows 上限 260 字元）或磁碟空間不足："
                "請改用較短的輸出資料夾路徑（例如 D:\\dl），或清出磁碟空間。")

    rate_limited = "429" in low or "too many requests" in low or "rate limit" in low or "rate-limit" in low
    login_wall = any(k in low for k in _GDL_LOGIN_KEYS) or "empty media response" in low

    if site == "instagram" and (login_wall or rate_limited):
        head = ("Instagram 不給這個連線看這則貼文（gallery-dl 與 yt-dlp 備援都失敗）。"
                "IG 對「需要登入」「貼文不存在／已刪除」「被限流」回的是同一種反應，所以原因可能是："
                "私人帳號、限制級／地區限制內容、網址打錯或貼文已刪除，或短時間內抓太多被限流。")
        if login_browser:
            return head + _LB_NOT_LOGGED_IN_TIP + "若是被限流，等 10～30 分鐘再試。"
        if has_cookies:
            return (head + "本次已經帶了 cookie：請在同一個瀏覽器實際打開這個網址確認看得到；"
                    "看得到的話多半是 cookie 過期，重新登入並重新匯出 cookies.txt 後再試，或等 10～30 分鐘。")
        return (head + "請先在瀏覽器（未登入）打開這個網址確認；若必須登入才看得到："
                + _login_browser_tip(images=True) + "若是被限流，等 10～30 分鐘再試。")

    if rate_limited:
        if has_cookies:
            return "被網站限流（HTTP 429）：請等 10～30 分鐘再試（已帶 cookie，換參數沒有用）。"
        return f"被網站限流（HTTP 429）：請等 10～30 分鐘再試，或{_LB_SHORT_TIP}。"

    if login_wall:
        if login_browser:
            return _LB_NOT_LOGGED_IN_TIP
        if has_cookies:
            return ("本次已經帶了 cookie 卻仍被要求登入：cookie 可能已過期，或該帳號無權觀看這則貼文。"
                    "請在同一個瀏覽器實際打開這個網址確認看得到，必要時重新登入並重新匯出 cookies.txt。")
        return "這則貼文需要登入才能看：" + _login_browser_tip(images=True)

    # X：推文不存在／已刪除時，gallery-dl 1.32.14 丟的是 KeyError 'result'（實測），不是 404
    if site == "twitter" and ("keyerror - 'result'" in low or "'unavailable'" in low
                              or "tweet unavailable" in low or "nsfw" in low):
        if login_browser:
            return ("推文不存在、已刪除，或需要登入才看得到（受保護帳號／敏感內容）：請確認網址能在瀏覽器打開；"
                    "若要登入才看得到，登入瀏覽器多半還沒登入 X，請執行「登入瀏覽器.bat」登入後再試。")
        if has_cookies:
            return "推文不存在、已刪除，或這個帳號看不到（例如受保護帳號）：請確認網址能在瀏覽器打開。"
        return ("推文不存在、已刪除，或屬於受保護帳號／敏感內容而需要登入：請先確認網址在瀏覽器打得開；"
                "若要登入才看得到：" + _login_browser_tip(images=True))

    if "404" in low or "not found" in low or "notfounderror" in low or "does not exist" in low:
        return "網址無效、貼文已刪除或設為不公開：請確認網址是否正確、能不能在瀏覽器開啟。"

    if "403" in low or "forbidden" in low:
        if has_cookies:
            return "被網站拒絕（HTTP 403）：請稍後再試；已帶 cookie 的話多半是 cookie 過期，請重新匯出。"
        return f"被網站拒絕（HTTP 403）：請稍後再試，或{_LB_SHORT_TIP}。"

    if any(k in low for k in ("timed out", "timeout", "connectionerror", "connection aborted",
                              "connection reset", "name resolution", "getaddrinfo", "ssl")):
        return "網路連線問題：請確認網路或代理設定後重試。"

    if "unexpected error" in low or "keyerror" in low or "typeerror" in low or "extractor" in low:
        return ("gallery-dl 的抽取器可能已失效（網站改版）：請先跑 mdl.bat update（會一併更新 gallery-dl）"
                "再試；仍失敗請到 https://codeberg.org/mikf/gallery-dl/issues 查詢。")
    return None


def _ext_from_url(url: str, default: str = "jpg") -> str:
    path = urllib.parse.urlsplit(url or "").path
    ext = os.path.splitext(path)[1].lstrip(".").lower()
    return ext if ext and len(ext) <= 5 and ext.isalnum() else default


def _http_download(url: str, dest: Path, headers: dict, timeout: int = 30,
                   retries: int = 3) -> tuple[bool, str | None]:
    """用標準函式庫下載單一檔案：先寫 .part，完成才改名；4xx（429 除外）不重試。"""
    part = Path(str(dest) + ".part")
    last_err = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as resp, open(part, "wb") as fh:
                shutil.copyfileobj(resp, fh, 64 * 1024)
            os.replace(part, dest)
            return True, None
        except Exception as exc:
            last_err = f"{type(exc).__name__}: {exc}"
            try:
                part.unlink()
            except Exception:
                pass
            if isinstance(exc, urllib.error.HTTPError) and 400 <= exc.code < 500 and exc.code != 429:
                break
            time.sleep(1 + attempt)
    return False, last_err


_IG_SIZED_STP_RE = re.compile(r"(?:^|_)(?:[sp]\d+x\d+|c\d+\.\d+)")


def _best_ig_image_url(entry: dict) -> str | None:
    """
    從 yt-dlp 的 thumbnails 裡挑原始尺寸的那張。
    實測：stp 參數沒有尺寸／裁切標記（_s1080x1080、_p640x640、c0.171.1440.1440a）的那一個
    就是原圖，網址與 gallery-dl 登入後抓到的逐字相同；yt-dlp 也把它排在最後。
    """
    thumbs = [t for t in (entry.get("thumbnails") or []) if isinstance(t, dict) and t.get("url")]
    if not thumbs:
        return entry.get("thumbnail") or None

    def _is_original(u: str) -> bool:
        match = re.search(r"[?&]stp=([^&]+)", u)
        if not match:
            return True
        return not _IG_SIZED_STP_RE.search(urllib.parse.unquote(match.group(1)))

    originals = [t for t in thumbs if _is_original(t["url"])]
    return (originals or thumbs)[-1]["url"]


def _ig_fallback_ytdlp(url: str, out_dir: Path, o: dict, budget: int, limit: int,
                       echo: bool, images_only: bool = False) -> dict:
    """
    IG 單篇貼文的備援：yt-dlp -J 取得整則貼文（輪播每一格），
    照片直接下載原圖網址，影片那幾格交給 yt-dlp 下載（沿用 video 的格式與合併設定）。
    檔名與 gallery-dl 相同：<帳號>_<貼文代碼>_<序號>.<副檔名>，兩個引擎互相認得已下載的檔案。
    images_only=True（影片模式的照片階段）：影片那幾格整個跳過——不下載、也不列入結果，
    因為 yt-dlp 的影片階段已經抓過了；序號仍然照輪播的位置算。
    """
    res: dict = {"candidates": [], "attempts": 0, "warnings": [], "error": None,
                 "stdout": "", "stderr": "", "meta": {}}
    exe = find_ytdlp()
    if exe is None:
        res["error"] = "找不到 yt-dlp，無法改用備援。"
        return res

    profiles = load_profiles()
    base = [str(exe)] + list(profiles.get("common", [])) + ["-J", "--ignore-no-formats-error", "--yes-playlist"]
    base += _cookie_args(o)
    rc, out, err = run_cmd(base + [url], timeout=300)
    res["attempts"] = 1
    if (rc != 0 or not out.strip()) and not _skip_retry_reason(err, out):
        rc2, out2, err2 = run_cmd(base + ["--impersonate", "chrome", url], timeout=300)
        res["attempts"] = 2
        if rc2 == 0 and out2.strip():
            rc, out, err = rc2, out2, err2
        elif not _impersonate_unsupported(err2):
            err = err2 or err
    res["stdout"], res["stderr"] = out, err
    if rc != 0 or not out.strip():
        res["error"] = compact_error(err, out)
        return res
    try:
        data = json.loads(out.strip().lstrip("\ufeff"))
    except Exception as exc:
        res["error"] = f"無法解析 yt-dlp 的 JSON 輸出：{exc}"
        return res

    is_playlist = data.get("_type") == "playlist"
    entries = [e for e in ((data.get("entries") or []) if is_playlist else [data]) if isinstance(e, dict)]
    match = _IG_POST_RE.match(url)
    shortcode = data.get("id") or (match.group(1) if match else "post")
    user = (data.get("channel") or data.get("uploader_id")
            or next((e.get("channel") for e in entries if e.get("channel")), None) or "instagram")
    user_s = _safe_component(user, max(8, min(40, budget - _IMG_TAIL_RESERVE)))
    code_s = _safe_component(shortcode, 40)
    res["meta"] = {"site": "instagram", "uploader": user, "post_id": shortcode,
                   "description": data.get("description")}

    headers = {"User-Agent": _BROWSER_UA}
    headers.update({str(k): str(v) for k, v in (data.get("http_headers") or {}).items()})

    video_items: list[int] = []
    for n, entry in enumerate(entries, 1):
        if n > limit:
            res["warnings"].append(f"已達 max_files={limit} 的上限，其餘 {len(entries) - limit} 格未下載。")
            break
        if entry.get("formats"):
            if images_only:
                continue
            existing = [out_dir / f"{user_s}_{code_s}_{n}.{ext}" for ext in ("mp4", "webm", "mkv")]
            done = next((p for p in existing if p.is_file() and p.stat().st_size > 0), None)
            if done:
                res["candidates"].append((str(done), False))
            else:
                video_items.append(n)
            continue
        img_url = _best_ig_image_url(entry)
        if not img_url:
            res["warnings"].append(f"第 {n} 格找不到圖片網址，已略過。")
            continue
        dest = out_dir / f"{user_s}_{code_s}_{n}.{_ext_from_url(img_url)}"
        if dest.is_file() and dest.stat().st_size > 0:
            res["candidates"].append((str(dest), False))
            continue
        if echo:
            print(f"[mdl] 下載第 {n} 格照片 → {dest.name}", flush=True)
        ok, dl_err = _http_download(img_url, dest, headers)
        if ok:
            res["candidates"].append((str(dest), True))
        else:
            res["warnings"].append(f"第 {n} 格照片下載失敗：{dl_err}")

    if video_items:
        vopts = dict(o)
        vopts.update({"playlist": is_playlist, "quality": "best", "clip": None, "subs": None,
                      "extra_args": [], "name": f"{user_s}_{code_s}_%(playlist_index|1)d.%(ext)s"})
        try:
            args, vwarn = build_download_args("mp4", vopts, out_dir, profiles)
        except OptionError as exc:
            res["warnings"].append(f"影片那幾格無法下載：{exc}")
            return res
        res["warnings"].extend(w for w in vwarn if w not in res["warnings"])
        if is_playlist:
            args += ["--playlist-items", ",".join(str(i) for i in video_items)]
        path_file = _new_tempfile(".paths.txt")
        args += ["--print-to-file", "after_move:filepath", path_file]
        try:
            vrc, vout, verr, vatt, vretry = _run_with_retry([str(exe)] + args, url, echo, echo)
            reported = _dedupe(_read_lines(path_file))
        finally:
            _cleanup(path_file)
        res["attempts"] += vatt
        res["warnings"].extend(vretry)
        got = [p for p in reported if Path(p).is_file()]
        res["candidates"].extend((p, True) for p in got)
        if len(got) < len(video_items):
            removed = _cleanup_partials(vout, verr, out_dir, got)
            res["warnings"].append(
                f"輪播中有 {len(video_items) - len(got)} 格影片下載失敗：{compact_error(verr, vout)}"
                + (f"（已清除 {len(removed)} 個暫存殘檔）" if removed else ""))
            res["stderr"] += "\n" + verr

    # 照片與影片是分兩批下載的，依檔名結尾的序號排回輪播順序
    def _order(item: tuple[str, bool]) -> int:
        match = re.search(r"_(\d+)\.[A-Za-z0-9]+$", item[0])
        return int(match.group(1)) if match else 10 ** 6

    res["candidates"].sort(key=_order)
    return res


def download_images(url: str, out_dir: str | None = None, cookies_file: str | None = None,
                    cookies_from_browser: str | None = None, name: str | None = None,
                    max_files: int | None = None, use_login_browser: bool = False, **opts) -> dict:
    """
    下載 IG / FB / X（及其他 gallery-dl 支援站台）貼文裡的所有媒體：照片，以及混合輪播裡的影片。
    一則貼文 = 整則貼文。回傳統一信封，files 每筆多了 kind（image / video / other）與 existing。

    參數：
      out_dir              輸出資料夾（預設 <root>\\downloads；也接受 out）
      cookies_file         Netscape 格式 cookies.txt（也接受 cookies）
      cookies_from_browser 從瀏覽器讀 cookie，例如 chrome / edge / firefox
      name                 覆寫檔名樣板（gallery-dl 格式字串，例如 "{category}_{id}.{extension}"）
      max_files            最多下載幾個檔案（預設 100）；防止誤貼帳號頁把整個帳號抓下來
      download_all         整批下載：網址是 IG 帳號頁／珍藏／珍藏分類（或直接給 @帳號）時抓全部貼文，
                           不設檔案數上限（有給 max_files 才設）、放進子資料夾、每個檔案之間隨機等待；
                           IG 一定要帶登入 cookie
      use_login_browser    用登入瀏覽器的 cookie（與 cookies_file / cookies_from_browser 互斥）
      extra_args           原樣附加給 gallery-dl 的參數（逃生口）
      _images_only         內部用（影片模式的照片階段）：只抓照片，影片在下載前就濾掉；只接受單篇貼文

    有 cookie（例如登入瀏覽器已登入 IG）時，IG 貼文照常走 gallery-dl；只有 gallery-dl 撞到登入牆
    （沒 cookie，或 cookie 其實沒登入）時才改用 yt-dlp 的公開介面備援，備援也會帶同一份 cookie。
    """
    url = str(url or "").strip()
    download_all = _truthy(opts.get("download_all")) and not opts.get("_images_only")
    if download_all and _IG_HANDLE_RE.match(url):
        url = f"https://www.instagram.com/{_IG_HANDLE_RE.match(url).group(1)}/"   # 只給帳號（@natgeo）
    if _truthy(use_login_browser):
        raw = dict(opts, out_dir=out_dir, cookies_file=cookies_file,
                   cookies_from_browser=cookies_from_browser, name=name, max_files=max_files)
        return _with_login_browser("images", url, [url], raw,
                                   lambda o2: download_images(url, **o2))
    images_only = bool(opts.pop("_images_only", False))
    opts.pop("download_all", None)
    merged = dict(opts)
    merged["out_dir"] = out_dir or opts.get("out_dir") or opts.get("out")
    merged["cookies"] = cookies_file or opts.get("cookies")
    merged["cookies_from_browser"] = cookies_from_browser or opts.get("cookies_from_browser")
    merged["name"] = name or opts.get("name")
    o = _norm_opts(merged)

    env = _envelope("images", url, engine=None, post_id=None,
                    media_counts={"images": 0, "videos": 0, "other": 0, "existing": 0},
                    cookie_source=_static_cookie_source(o), download_all=download_all, pace=None)
    started = time.time()

    if not url:
        return _fail(env, "沒有提供網址。", "請提供 IG / FB / X 單篇貼文的網址。")
    if not re.match(r"^https?://", url, re.IGNORECASE):
        if re.match(r"^(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+/\S*$", url, re.IGNORECASE):
            url = "https://" + url
            env["url"] = url
            env["warnings"].append("網址沒有 https://，已自動補上。")
        else:
            return _fail(env, f"網址格式不正確：{url!r}",
                         "請貼完整的貼文網址（以 https:// 開頭），例如 https://www.instagram.com/p/XXXXXXXXXXX/。")

    # 整批下載沒給 max_files → 不設上限（limit = None）
    limit: int | None = None
    if max_files is not None or not download_all:
        try:
            limit = int(max_files if max_files is not None else _IMG_DEFAULT_MAX_FILES)
        except (TypeError, ValueError):
            limit = 0
        if not 1 <= limit <= _IMG_MAX_FILES_LIMIT:
            return _fail(env, f"max_files 必須是 1～{_IMG_MAX_FILES_LIMIT} 的整數，收到 {max_files!r}。",
                         "請檢查參數值；可用選項見 mdl.py images --help。")

    bulk = None
    if download_all:
        bulk, bulk_error = _ig_bulk_target(url)
        if bulk_error:
            return _fail(env, bulk_error, "請在登入瀏覽器打開那個珍藏分類，複製網址列的網址再貼上來"
                                          "（mdl.bat browser tabs 可以列出目前分頁的網址）。")
        if bulk and not _has_cookie_opts(o):
            return _fail(env, f"整批下載 {bulk['label']} 需要登入 Instagram（IG 不讓未登入者列舉帳號或珍藏）。",
                         _login_browser_tip(images=True))

    # 只抓照片 + IG 單篇貼文 + 沒有 cookie：gallery-dl 的 IG 單篇貼文介面未登入一定撞登入牆（見本區開頭），
    # 直接走 yt-dlp 的公開介面，少打一次 IG、省約 2 秒。（images 指令維持原樣：先試 gallery-dl。）
    skip_gdl = bool(images_only and _IG_POST_RE.match(url)
                    and not (o["cookies"] or o["cookies_from_browser"]))

    exe = find_gallery_dl()
    if exe is None and not skip_gdl:
        return _fail(env,
                     f"找不到 gallery-dl：{BIN_DIR / 'gallery-dl.exe'} 不存在，PATH 上也沒有 gallery-dl。",
                     "請重跑「首次設定.bat」（會下載 bin\\gallery-dl.exe）；影片下載不受影響。")

    cookie_path = None
    if o["cookies"]:
        cookie_path = Path(str(o["cookies"])).expanduser()
        if not cookie_path.is_file():
            return _fail(env, f"找不到 cookies 檔：{o['cookies']}", _cookie_failure_hint("source", ""))
        cookie_path = cookie_path.resolve()

    try:
        target = _resolve_out_dir(o)
    except Exception as exc:
        return _fail(env, f"無法建立輸出資料夾：{exc}", "請改用 --out 指定一個可寫入的資料夾。")
    if bulk:
        try:
            target = target / bulk["folder"]
            target.mkdir(parents=True, exist_ok=True)
        except Exception as exc:
            return _fail(env, f"無法建立輸出資料夾：{exc}", "請改用 --out 指定一個可寫入的資料夾。")
    env["output_dir"] = str(target)

    fetch_url = bulk["url"] if bulk else url
    if _FB_SHARE_POST_RE.match(url):
        resolved = _resolve_fb_share(url)
        if resolved:
            fetch_url = resolved
            if not images_only:
                env["warnings"].append(f"已把 Facebook 分享網址解析成 {resolved}。")
    fetch_url, notes = _normalize_image_url(fetch_url)
    if images_only:
        # 改寫網址只是實作細節；「這張照片屬於一則多圖貼文」那種有後續動作的才留著
        notes = [n for n in notes if not n.startswith("已把 Facebook")]
    env["warnings"].extend(notes)
    if images_only and _site_from_url(fetch_url) == "facebook" and not _FB_SINGLE_POST_RE.match(fetch_url):
        env["elapsed_sec"] = round(time.time() - started, 2)
        return _fail(env, "這個 Facebook 網址不是單篇貼文或單張照片（可能是相片牆、相簿或解析不了的分享網址），"
                          "照片階段不處理。",
                     "要抓整個相片牆或相簿請改用 images 指令（mdl.bat images \"<網址>\"，"
                     "agent：mdl_download_images；最多下載 max_files 個檔案）。")
    budget, budget_warn = _image_name_budget(target)
    env["warnings"].extend(budget_warn)

    meta_after = _new_tempfile(".after.txt")
    meta_skip = _new_tempfile(".skip.txt")
    cmd = [
        str(exe), "--config-ignore", "--no-colors",
        "-o", "cache.file=null",
        "-o", "cookies-update=false",
        "-o", "output.stdout.encoding=utf-8",
        "-o", "output.stderr.encoding=utf-8",
        # X 被限流時 gallery-dl 預設會「等到解除」（可能卡 15 分鐘），改成直接報錯
        "-o", "extractor.twitter.ratelimit=abort",
        # gallery-dl 在 Windows 預設用 \\?\ 長路徑寫檔：超過 260 字元也「寫得進去」，但本機
        # LongPathsEnabled=0，檔總管、Python 與大多數程式都打不開那個檔（實測我們自己也驗證不到）。
        # 關掉之後改成明確失敗，由 hint 建議改用較短的資料夾，與 video 指令的行為一致。
        "-o", "path-extended=false",
        "--http-timeout", "30", "-R", "4",
        "-D", str(target),
    ]
    if limit is not None:
        cmd += ["--range", f"1-{limit}"]
    if download_all:
        pace_cfg = _bulk_sleep_cfg(load_profiles())
        pace = _pace_args(pace_cfg)
        cmd += pace
        env["pace"] = pace_cfg if pace else None
    cmd += ["-f", str(o["name"])] if o["name"] else _image_filename_args(budget)
    cmd += ["--Print-to-file", "after:" + _GDL_META_FMT, meta_after,
            "--Print-to-file", "skip:" + _GDL_META_FMT, meta_skip]
    if cookie_path:
        cmd += ["--cookies", str(cookie_path)]
    if o["cookies_from_browser"]:
        cmd += ["--cookies-from-browser", str(o["cookies_from_browser"])]
    if images_only:
        # IG / X 的影片網址與照片在同一個 API 回應裡，靠 --filter 濾掉就不會下載。
        # 不要對 IG 加 extractor.instagram.videos=false：實測（gallery-dl 1.32.14，2026-10-06）限時動態裡
        # 只要有影片，整個抽取就會以 KeyError 'width' 失敗，連照片都拿不到。
        # FB 的影片要另外開影片頁才拿得到網址，直接關掉省請求。
        cmd += ["-o", "extractor.facebook.videos=false", "--filter", _PHOTO_PASS_FILTER]
    cmd += [str(a) for a in o["extra_args"]]
    cmd.append(fetch_url)

    echo = (not o["json_mode"]) and (not o["quiet"])
    if echo and download_all:
        what = bulk["label"] if bulk else fetch_url
        cap = f"最多 {limit} 個檔案" if limit is not None else "不設檔案數上限"
        print(f"[mdl] 整批下載：{what} → {target}（{cap}）", flush=True)
        if env["pace"]:
            print("[mdl] 每個檔案下載完會隨機等待 {min:g}～{max:g} 秒（常態分佈，平均 {mean:g} 秒）；"
                  "已下載過的檔案會略過。中途按 Ctrl+C 停止後，重跑同一個指令即可接續。".format(**env["pace"]),
                  flush=True)
    token = _url_post_token(fetch_url)
    parts_before = _list_part_files(target)
    run_started = time.time()
    rc, out, err, rows = 1, "", "", []
    try:
        if not skip_gdl:
            rc, out, err = run_cmd(cmd, echo_stdout=echo, echo_stderr=echo,
                                   timeout=(_PHOTO_PASS_TIMEOUT_SEC if images_only
                                            else None if download_all else _IMG_TIMEOUT_SEC))
            rows = (_parse_gdl_meta(_read_lines(meta_after), True)
                    + _parse_gdl_meta(_read_lines(meta_skip), False))
    finally:
        _cleanup(meta_after, meta_skip)
    env["attempts"] = 0 if skip_gdl else 1
    env["engine"] = "yt-dlp" if skip_gdl else "gallery-dl"

    cookie_issue = _gdl_cookie_issue(err)
    if cookie_issue:
        env["warnings"].append(f"cookie 沒有載入成功，本次等於「未登入」：{cookie_issue}")
    has_cookies = _has_cookie_opts(o) and not cookie_issue

    candidates = [(r["path"], r["downloaded"]) for r in rows if r.get("path")]
    candidates += _stdout_paths(out, target)
    files, file_warn = _collect_media_files(candidates, target)
    env["warnings"].extend(file_warn)
    first = next((r for r in rows if r.get("path")), {})
    meta = {"site": first.get("site"), "uploader": first.get("uploader"),
            "post_id": first.get("set_id") if first.get("subcategory") == "set" else first.get("post_id"),
            "description": first.get("description"), "subcategory": first.get("subcategory")}
    hint_err, hint_out = err, out
    error_text = _gdl_compact_error(err, out, rc) if (rc != 0 and not skip_gdl) else None

    # IG 單篇貼文被登入牆擋住 → yt-dlp 備援（見本區開頭的說明）
    if not files and _IG_POST_RE.match(fetch_url) and (skip_gdl or any(
            k in (err + "\n" + out).lower() for k in _GDL_LOGIN_KEYS)):
        if echo and not skip_gdl:
            print("[mdl] gallery-dl 的 IG 單篇貼文介面需要登入，改用 yt-dlp 的公開介面…", flush=True)
        fb = _ig_fallback_ytdlp(fetch_url, target, o, budget, limit or _IMG_MAX_FILES_LIMIT, echo,
                                images_only=images_only)
        env["attempts"] += fb["attempts"]
        fb_files, fb_warn = _collect_media_files(fb["candidates"], target)
        if fb_files:
            env["engine"] = "yt-dlp"
            if not images_only:
                env["warnings"].append("gallery-dl 的 IG 單篇貼文介面需要登入（"
                                       + (error_text or "登入牆") + "），已改用 yt-dlp 的公開介面抓取。")
            files = fb_files
            meta = dict(fb["meta"])
            rc, error_text = 0, None
        env["warnings"].extend(fb["warnings"] + fb_warn)
        if not fb_files and images_only and not fb["error"] and not any("失敗" in w for w in fb["warnings"]):
            # 只抓照片：yt-dlp 讀得到這則貼文，只是裡面沒有照片（全部都是影片）→ 不是錯誤
            env["engine"] = "yt-dlp"
            rc, error_text, err, out = 0, None, "", ""
        elif not fb_files:
            fb_error = (fb["error"] or next((w for w in fb["warnings"] if "失敗" in w), None)
                        or "yt-dlp 備援也沒有產出任何檔案。")
            # yt-dlp 的 IG 錯誤後面接一大段「怎麼傳 cookie／請回報 bug」，詳細內容已在 log_tail
            fb_error = re.split(r"\s+(?:Check if this post|Otherwise, if)|;\s*please report",
                                fb_error, maxsplit=1)[0].strip()[:240]
            error_text = (fb_error if skip_gdl
                          else f"{error_text or 'gallery-dl 失敗'}；yt-dlp 備援：{fb_error}")
            # 備援裡逐格下載的失敗原因（例如路徑過長的 Errno 2）只記在 warnings，也要納入 hint 判讀
            hint_err = err + "\n" + fb["stderr"] + "\n" + "\n".join(fb["warnings"])
            hint_out = out + "\n" + fb["stdout"]

    env["files"] = files
    env["elapsed_sec"] = round(time.time() - started, 2)
    env["site"] = meta.get("site") or _site_from_url(fetch_url)
    env["uploader"] = meta.get("uploader")
    env["post_id"] = meta.get("post_id") or token
    desc = (meta.get("description") or "").strip()
    env["title"] = (desc.splitlines()[0][:200] if desc else None)
    counts = env["media_counts"]
    for f in files:
        key = {"image": "images", "video": "videos"}.get(f.get("kind"), "other")
        counts[key] += 1
        if f.get("existing"):
            counts["existing"] += 1

    # 判斷成敗一律以「磁碟上真的有非空的照片／影片」為準
    if files:
        if rc != 0:
            env["log_tail"] = _log_tail(err)
            env["warnings"].append(
                f"gallery-dl 回報有項目失敗（{error_text}），其餘 {len(files)} 個檔案已下載。")
        if counts["existing"] == len(files):
            env["warnings"].append(
                f"全部 {len(files)} 個檔案先前已經下載過，這次沒有重新下載（檔案仍在，已列入 files）。")
        elif counts["existing"]:
            env["warnings"].append(f"其中 {counts['existing']} 個檔案先前已經下載過，沿用既有檔案。")
        if limit is not None and len(files) >= limit and not any("max_files=" in w for w in env["warnings"]):
            env["warnings"].append(
                f"已達 max_files={limit} 的上限，可能還有更多檔案沒下載；需要的話請調高 max_files（--max-files）。")
        if meta.get("subcategory") in _LISTING_SUBCATEGORIES and not download_all and not (
                images_only and meta.get("subcategory") in ("stories", "highlights")):
            env["warnings"].append(
                f"這個網址看起來是帳號頁／相簿清單（{meta.get('subcategory')}），不是單篇貼文；"
                f"最多只下載前 {limit} 個檔案。")
        return env

    removed = _cleanup_image_partials(target, parts_before, token, run_started)
    _note_cleanup(env, removed)
    if rc == 0 and not error_text and images_only:
        return _fail(env, "這則貼文裡沒有照片。", None)
    if rc == 0 and not error_text:
        return _fail(env, "這個網址沒有可下載的照片或影片（gallery-dl 執行成功，但沒有產出任何檔案）。",
                     "可能是純文字貼文，或網址指向的不是貼文本身；請確認網址，要影片請改用 video 指令。",
                     err)
    return _fail(env, error_text or _gdl_compact_error(err, out, rc),
                 build_image_hint(hint_err, hint_out, has_cookies, fetch_url, cookie_issue,
                                  login_browser=o["login_browser_used"]),
                 hint_err)


# --------------------------------------------------------------- batch ---

def expand_sources(sources: list[str]) -> tuple[list[str], list[str]]:
    """
    把來源展開成 URL 清單。
    來源可以是 URL，或一個 .txt 檔路徑（每行一個 URL，# 開頭略過）。
    回傳 (urls, warnings)。
    """
    urls: list[str] = []
    warnings: list[str] = []
    for src in sources:
        s = str(src).strip()
        if not s:
            continue
        looks_url = s.lower().startswith(("http://", "https://"))
        if not looks_url and Path(s).is_file():
            try:
                with open(s, "r", encoding="utf-8-sig", errors="replace") as fh:
                    for raw in fh:
                        line = raw.strip()
                        if not line or line.startswith("#"):
                            continue
                        urls.append(line)
            except Exception as exc:
                warnings.append(f"讀取清單檔失敗（{s}）：{exc}")
        else:
            urls.append(s)
    return _dedupe(urls), warnings


def batch_download(urls: list[str], mode: str = "mp4", **opts) -> dict:
    """
    逐一下載多個 URL；單筆失敗不影響其他筆。
    use_login_browser=True 時只從登入瀏覽器匯出「一次」cookie，整批共用同一個暫存檔。
    mode=mp4 時每一筆都和 download() 一樣：IG / FB / X 貼文的照片會一併下載（include_photos=False 可關閉），
    頂層的 media_counts 是各筆的加總。
    """
    if _truthy(opts.get("use_login_browser")):
        expanded, _ = expand_sources(list(urls or []))
        if expanded:
            return _with_login_browser("batch", None, expanded, opts,
                                       lambda o2: batch_download(urls, mode=mode, **o2))
        opts = {k: v for k, v in opts.items() if k != "use_login_browser"}   # 空清單：照常回報錯誤
    o = _norm_opts(opts)
    env = _envelope("batch", cookie_source=_static_cookie_source(o))
    started = time.time()

    expanded, warns = expand_sources(list(urls or []))
    env["warnings"].extend(warns)

    if not expanded:
        return _fail(env, "沒有可下載的 URL（來源是空的，或 .txt 清單檔裡沒有有效網址）。",
                     "請提供至少一個 http(s) 網址，或一個每行一個網址的 .txt 檔。")

    results: list[dict] = []
    all_files: list[dict] = []
    for index, url in enumerate(expanded, 1):
        if (not o["json_mode"]) and (not o["quiet"]):
            print(f"\n[mdl] ({index}/{len(expanded)}) {url}", flush=True)
        try:
            item = download(url, mode=mode, **opts)
        except Exception as exc:  # 絕不讓單筆例外中斷整批
            item = _fail(_envelope("video" if mode == "mp4" else "audio", url),
                         f"未預期的例外：{exc}", None)
        results.append(item)
        all_files.extend(item.get("files") or [])

    ok_count = sum(1 for r in results if r.get("ok"))
    fail_count = len(results) - ok_count

    env["results"] = results
    env["files"] = all_files
    env["stats"] = {"total": len(results), "ok": ok_count, "failed": fail_count}
    if mode == "mp4":
        env["media_counts"] = {
            key: sum(int((r.get("media_counts") or {}).get(key) or 0) for r in results)
            for key in ("images", "videos", "other", "existing")}
    env["attempts"] = sum(int(r.get("attempts") or 0) for r in results)
    env["elapsed_sec"] = round(time.time() - started, 2)
    env["output_dir"] = next((r.get("output_dir") for r in results if r.get("output_dir")), None)
    env["ok"] = ok_count > 0

    if fail_count:
        env["warnings"].append(f"{fail_count} 筆失敗、{ok_count} 筆成功，詳見 results。")
        if env["ok"]:
            # 頂層 ok:true 時不要把個別項目的 hint 搬上來，否則會出現
            # 「成功，但影片已被移除」這種自相矛盾的組合。個別 hint 留在 results 裡。
            env["error"] = None
            env["hint"] = (f"{fail_count} 筆失敗（共 {len(results)} 筆），"
                           "各筆的原因與建議請看 results 陣列裡的 error / hint。")
        else:
            env["error"] = next((r.get("error") for r in results if not r.get("ok")), None)
            env["hint"] = next((r.get("hint") for r in results if not r.get("ok")), None)
            env["log_tail"] = next((r.get("log_tail") for r in results if r.get("log_tail")), None)

    return env


# -------------------------------------------------------------- doctor ---

def _probe_version(exe: Path | None, args: list[str]) -> tuple[str | None, str | None]:
    """跑 <exe> <args> 取版本字串；回傳 (version, error)。"""
    if exe is None:
        return None, "not found"
    rc, out, err = run_cmd([str(exe)] + args, timeout=30)
    if rc != 0:
        return None, compact_error(err, out)
    first = (out or err or "").strip().splitlines()
    return (first[0].strip() if first else None), None


def doctor(**opts) -> dict:
    """環境自我檢查：執行檔、版本、輸出資料夾可寫、Python 版本、設定檔。"""
    env = _envelope("doctor")
    started = time.time()
    checks: dict = {}

    # --- Python ---
    checks["python"] = {
        "version": sys.version.split()[0],
        "executable": sys.executable,
        "ok": sys.version_info >= (3, 10),
    }
    if not checks["python"]["ok"]:
        env["warnings"].append("Python 版本低於 3.10，可能無法正常運作。")

    # --- 專案路徑 ---
    checks["root"] = {"path": str(ROOT), "exists": ROOT.is_dir()}
    checks["config"] = {
        "path": str(CONFIG_PATH),
        "exists": CONFIG_PATH.is_file(),
        "loaded": False,
    }
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
            json.load(fh)
        checks["config"]["loaded"] = True
    except Exception as exc:
        if CONFIG_PATH.is_file():
            env["warnings"].append(f"profiles.json 無法解析（改用內建預設值）：{exc}")
        else:
            env["warnings"].append("找不到 config\\profiles.json，改用內建預設值。")

    # --- yt-dlp ---
    ytdlp = find_ytdlp()
    version, verr = _probe_version(ytdlp, ["--version"])
    checks["yt_dlp"] = {
        "path": str(ytdlp) if ytdlp else None,
        "found": ytdlp is not None,
        "in_bin": bool(ytdlp and BIN_DIR in ytdlp.parents),
        "version": version,
        "error": verr,
        "ok": ytdlp is not None and version is not None,
    }

    # --- ffmpeg / ffprobe ---
    ffmpeg = find_ffmpeg()
    ff_version, ff_err = _probe_version(ffmpeg, ["-version"])
    checks["ffmpeg"] = {
        "path": str(ffmpeg) if ffmpeg else None,
        "found": ffmpeg is not None,
        "version": ff_version,
        "error": ff_err,
        "ok": ffmpeg is not None and ff_version is not None,
    }
    ffprobe = find_ffprobe()
    checks["ffprobe"] = {"path": str(ffprobe) if ffprobe else None, "found": ffprobe is not None}

    # --- gallery-dl（images 指令：IG / FB / X 貼文照片）---
    gdl = find_gallery_dl()
    gdl_version, gdl_err = _probe_version(gdl, ["--version"])
    checks["gallery_dl"] = {
        "path": str(gdl) if gdl else None,
        "found": gdl is not None,
        "in_bin": bool(gdl and BIN_DIR in gdl.parents),
        "version": gdl_version,
        "error": gdl_err,
        "ok": gdl is not None and gdl_version is not None,
    }
    if not checks["gallery_dl"]["ok"]:
        env["warnings"].append(
            "找不到可用的 gallery-dl：images 指令（下載 IG / FB / X 貼文照片）無法使用，影片下載不受影響。"
            "請重跑「首次設定.bat」下載 bin\\gallery-dl.exe。")

    # --- 登入瀏覽器（--login-browser / use_login_browser 的 cookie 來源）---
    # 只跑快速的 status（不加 -Probe）：瀏覽器沒開時不會去讀 cookie，logged_in 會是 null（未知）。
    if os.name == "nt":
        lb = run_browser_ps1("status")
        checks["login_browser"] = {
            "ok": bool(lb.get("ok")),
            "script": str(BROWSER_PS1),
            "browser": lb.get("browser"),
            "version": lb.get("version"),
            "profile": lb.get("profile"),
            "profile_exists": lb.get("profile_exists"),
            "sync_folder": lb.get("sync_folder"),
            "running": lb.get("running"),
            "port": lb.get("port"),
            "logged_in": lb.get("logged_in"),
            "error": lb.get("error"),
            "hint": lb.get("hint"),
        }
        if not lb.get("ok"):
            env["warnings"].append(
                f"登入瀏覽器無法使用（{lb.get('error')}）：{lb.get('hint') or ''}"
                "（只影響 --login-browser，一般下載不受影響）")
        elif lb.get("sync_folder"):
            env["warnings"].append(
                f"登入瀏覽器的設定檔位於 {lb.get('sync_folder')} 同步資料夾內（{lb.get('profile')}）："
                "登入 session 會被同步，而且同步程式可能鎖住 cookie 資料庫；請把 MDL_BROWSER_PROFILE 改到本機資料夾。")
    else:
        checks["login_browser"] = {"ok": False, "error": "只支援 Windows", "hint": None}

    if not checks["ffmpeg"]["ok"]:
        env["warnings"].append(
            "找不到可用的 ffmpeg：無法合併高畫質影音軌、無法轉 mp3。" + SETUP_HINT)
    if not checks["ffprobe"]["found"]:
        env["warnings"].append("找不到 ffprobe，部分後處理（例如精確片段擷取）可能受影響。")

    # --- 輸出資料夾可寫 ---
    out_dir = Path(opts.get("out_dir") or opts.get("out") or DEFAULT_OUT_DIR)
    writable, werr = False, None
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        probe = out_dir / ".mdl_write_test.tmp"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        writable = True
    except Exception as exc:
        werr = str(exc)
        env["warnings"].append(f"輸出資料夾不可寫：{out_dir}（{exc}）")
    checks["output_dir"] = {"path": str(out_dir), "writable": writable, "error": werr}
    env["output_dir"] = str(out_dir)

    env["checks"] = checks
    env["elapsed_sec"] = round(time.time() - started, 2)
    env["attempts"] = 1

    if not checks["yt_dlp"]["found"]:
        return _fail(env,
                     f"找不到 yt-dlp：{BIN_DIR / 'yt-dlp.exe'} 不存在，PATH 上也沒有 yt-dlp。",
                     SETUP_HINT)
    if not checks["yt_dlp"]["ok"]:
        return _fail(env,
                     f"yt-dlp 存在但無法執行：{checks['yt_dlp']['error']}",
                     "檔案可能仍在下載中或被防毒鎖定；請稍候再試，或重跑「首次設定.bat」。")
    if not writable:
        return _fail(env, f"輸出資料夾無法寫入：{out_dir}",
                     "請用 --out 指定其他資料夾，或檢查資料夾權限。")
    return env


# -------------------------------------------------------------- update ---

def update(json_mode: bool = False, quiet: bool = False) -> dict:
    """執行 yt-dlp -U 自我更新；有 gallery-dl 的話一併執行 gallery-dl --update。"""
    env = _envelope("update")
    started = time.time()

    exe = _ytdlp_or_fail(env)
    if exe is None:
        return env

    echo = (not json_mode) and (not quiet)
    rc, out, err = run_cmd([str(exe), "-U"], echo_stdout=echo, echo_stderr=echo)
    env["attempts"] = 1
    env["elapsed_sec"] = round(time.time() - started, 2)
    env["message"] = (out or err or "").strip()[-2000:] or None

    if rc != 0:
        return _fail(env, compact_error(err, out),
                     "若 yt-dlp.exe 被防毒或其他程式鎖定會更新失敗；"
                     "請關閉所有下載後重試，或重跑「首次設定.bat」。", err)

    version, _ = _probe_version(exe, ["--version"])
    env["version"] = version

    # 順便更新 gallery-dl（images 指令用）；失敗只記警告，不影響 yt-dlp 的更新結果
    gdl = find_gallery_dl()
    env["gallery_dl_version"] = None
    if gdl is not None:
        grc, gout, gerr = run_cmd([str(gdl), "--update"], echo_stdout=echo, echo_stderr=echo, timeout=600)
        env["gallery_dl_message"] = (gout or gerr or "").strip()[-1000:] or None
        if grc != 0:
            env["warnings"].append(
                "gallery-dl 更新失敗（" + _gdl_compact_error(gerr, gout, grc)
                + "）；可重跑「首次設定.bat」-Force 重新下載，或到 https://codeberg.org/mikf/gallery-dl/releases 手動下載。")
        env["gallery_dl_version"], _ = _probe_version(gdl, ["--version"])
    else:
        env["warnings"].append("找不到 gallery-dl（images 指令用），略過；請重跑「首次設定.bat」。")
    return env


# ==========================================================================
# 6. Agent 介面（TOOL_SCHEMAS / call_tool）
# ==========================================================================

_QUALITY_ENUM = DEFAULT_PROFILES["quality_choices"]
_AUDIO_QUALITY_ENUM = DEFAULT_PROFILES["audio_quality_choices"]
_BROWSER_ENUM = ["chrome", "edge", "firefox", "brave", "opera", "vivaldi", "chromium", "safari"]

_COMMON_DL_PROPS = {
    "out_dir": {
        "type": "string",
        "description": "輸出資料夾絕對路徑；省略則用 <專案>\\downloads。",
    },
    "playlist": {
        "type": "boolean",
        "description": "true 時下載整個播放清單/頻道；預設 false 只下載單支影片。",
        "default": False,
    },
    "clip": {
        "type": "string",
        "description": "只擷取某個時間區段，格式 START-END，例如 00:01:00-00:02:30。需要 ffmpeg。",
    },
    "cookies_from_browser": {
        "type": "string",
        "enum": _BROWSER_ENUM,
        "description": ("從使用者自己的瀏覽器讀 cookies，用於私人/會員/年齡限制內容。"
                        "Chrome/Edge 開著時通常讀不到（資料庫被鎖、新版加密），優先改用 use_login_browser；"
                        "firefox 較不受影響。不能與 use_login_browser 同時使用。"),
    },
    "include_photos": {
        "type": "boolean",
        "default": True,
        "description": ("影片下載時，貼文裡的照片要不要一併下載（預設 true）。只對 Instagram（/p/ 貼文；帶 cookie 時"
                        "還有 /stories/ 限時動態）、X（/<帳號>/status/<數字>）、Facebook（貼文／照片網址）有作用："
                        "影片照常由 yt-dlp 下載，照片另外補抓（檔名 <帳號>_<貼文ID>_<序號>.<副檔名>，同一個輸出資料夾，"
                        "不會重複下載影片），所以回傳的 files 可能同時有 kind=video 與 kind=image，純照片貼文也會是 "
                        "ok:true。其他網站（YouTube 等）、以及 IG Reel／FB 影片網址完全不受影響。"
                        "只想要影片、不要照片時帶 false。"),
    },
    "use_login_browser": {
        "type": "boolean",
        "default": False,
        "description": ("用「登入瀏覽器」的 cookie：那是本工具專用的 Chrome/Edge 視窗（獨立設定檔），使用者事先在裡面"
                        "登入過 IG / FB / X 等網站。公開內容不需要；內容需要登入（私人帳號、限時動態、帳號頁、"
                        "會員／年齡限制），或上一次呼叫的 hint 說需要登入／cookie 時，帶 true 重試。使用者平常的 Chrome "
                        "不必關。與 cookies_from_browser / cookies_file 互斥。結果的 cookie_source 說明匯出方式"
                        "（mode: live = 視窗開著、headless = 臨時無頭）；若 warnings 說登入瀏覽器沒登入該網站，"
                        "請用 mdl_login_browser action=open 開那個網站，請使用者本人登入後再試。"),
    },
}

TOOL_SCHEMAS: list[dict] = [
    {
        "name": "mdl_info",
        "description": (
            "查詢一支影片的資訊而不下載：標題、上傳者、長度、上傳日期、站台、縮圖、"
            "是否直播、觀看數、最高可用解析度。下載前想先確認內容或畫質時使用。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "影片網址（YouTube、Bilibili、X、IG… 等 yt-dlp 支援的站台）。"},
                "cookies_from_browser": _COMMON_DL_PROPS["cookies_from_browser"],
                "use_login_browser": _COMMON_DL_PROPS["use_login_browser"],
            },
            "required": ["url"],
        },
    },
    {
        "name": "mdl_download_video",
        "description": (
            "下載影片並輸出 mp4（自動合併最佳畫質與音質）。使用者說「下載這部影片/存成 mp4/"
            "抓下來看」時用這個。可指定畫質上限、輸出資料夾、時間區段、字幕。"
            "網址是 Instagram / Facebook / X 的單篇貼文時，貼文裡的照片也會自動一併下載"
            "（include_photos，預設 true）：不必先判斷貼文是影片還是照片，直接用這個工具即可——"
            "混合輪播會得到影片 + 照片，純照片貼文會得到照片而且 ok:true。"
            "回傳的 files 每筆有 kind（video / image / other），media_counts 統計影片與照片各幾個，"
            "photo_pass 說明照片階段有沒有跑（null = 這個網址不適用或已關閉）、用哪個引擎、找到幾張。"
            "照片階段失敗絕不會讓已成功的影片下載變成失敗。"
            "只想要影片就帶 include_photos=false；想用 gallery-dl 抓「整則貼文」（含影片、可設 max_files、"
            "帳號頁）才需要 mdl_download_images。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "影片網址。"},
                "quality": {
                    "type": "string",
                    "enum": _QUALITY_ENUM,
                    "default": "best",
                    "description": "畫質上限；best 表示不限制，其餘為最高高度（像素）。",
                },
                "subs": {
                    "type": "string",
                    "description": "要一併下載並內嵌的字幕語言，逗號分隔，例如 zh-TW,en。",
                },
                "include_photos": _COMMON_DL_PROPS["include_photos"],
                "out_dir": _COMMON_DL_PROPS["out_dir"],
                "playlist": _COMMON_DL_PROPS["playlist"],
                "clip": _COMMON_DL_PROPS["clip"],
                "cookies_from_browser": _COMMON_DL_PROPS["cookies_from_browser"],
                "use_login_browser": _COMMON_DL_PROPS["use_login_browser"],
            },
            "required": ["url"],
        },
    },
    {
        "name": "mdl_download_audio",
        "description": (
            "只抽取音訊並轉成 mp3（含封面與 metadata）。使用者說「只要音樂/轉 mp3/"
            "抓音檔/做成 podcast」時用這個。需要 ffmpeg。輸出資料夾裡既有的檔案（例如同名的影片）"
            "不會被動到；同名的 mp3 已經存在時不重新下載（files[].existing=true）。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "影片或音訊網址。"},
                "audio_quality": {
                    "type": "string",
                    "enum": _AUDIO_QUALITY_ENUM,
                    "default": "0",
                    "description": "mp3 品質；0 = VBR 最佳，其餘為固定位元率。",
                },
                "out_dir": _COMMON_DL_PROPS["out_dir"],
                "playlist": _COMMON_DL_PROPS["playlist"],
                "clip": _COMMON_DL_PROPS["clip"],
                "cookies_from_browser": _COMMON_DL_PROPS["cookies_from_browser"],
                "use_login_browser": _COMMON_DL_PROPS["use_login_browser"],
            },
            "required": ["url"],
        },
    },
    {
        "name": "mdl_list_formats",
        "description": (
            "列出某個網址所有可下載的格式（format_id、副檔名、解析度、fps、編碼、檔案大小）。"
            "需要挑特定畫質或確認某解析度是否存在時使用。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "影片網址。"},
                "cookies_from_browser": _COMMON_DL_PROPS["cookies_from_browser"],
                "use_login_browser": _COMMON_DL_PROPS["use_login_browser"],
            },
            "required": ["url"],
        },
    },
    {
        "name": "mdl_batch_download",
        "description": (
            "一次下載多個網址（或一個每行一個網址的 .txt 清單檔）。單筆失敗不會中斷其他筆，"
            "回傳每筆結果與成功/失敗統計。mode=mp4 時每一筆的行為與 mdl_download_video 相同："
            "IG / FB / X 貼文的照片會一併下載（include_photos，預設 true），純照片貼文也算成功；"
            "每筆結果有自己的 files（含 kind）、media_counts、photo_pass，頂層 media_counts 是加總。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "urls": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "網址清單；也可以放一個 .txt 檔的路徑（每行一個網址，# 開頭為註解）。",
                },
                "mode": {
                    "type": "string",
                    "enum": ["mp4", "mp3"],
                    "default": "mp4",
                    "description": "mp4 = 影片，mp3 = 只要音訊。",
                },
                "quality": {
                    "type": "string",
                    "enum": _QUALITY_ENUM,
                    "default": "best",
                    "description": "mode=mp4 時的畫質上限。",
                },
                "audio_quality": {
                    "type": "string",
                    "enum": _AUDIO_QUALITY_ENUM,
                    "default": "0",
                    "description": "mode=mp3 時的音質。",
                },
                "include_photos": _COMMON_DL_PROPS["include_photos"],
                "out_dir": _COMMON_DL_PROPS["out_dir"],
                "cookies_from_browser": _COMMON_DL_PROPS["cookies_from_browser"],
                "use_login_browser": _COMMON_DL_PROPS["use_login_browser"],
            },
            "required": ["urls"],
        },
    },
    {
        "name": "mdl_download_images",
        "description": (
            "下載 Instagram / Facebook / X（Twitter）貼文裡的照片——一次抓整則貼文：多張照片的輪播全部下載，"
            "混合輪播裡的影片也一起下載（全部交給 gallery-dl，影片不能選畫質）。"
            "注意：mdl_download_video 對 IG / FB / X 貼文已經會自動把照片一併下載，一般情況直接用它就好；"
            "這個工具用在使用者明確只要「存照片／下載圖片」、要抓帳號頁或相簿（搭配 max_files），"
            "或 mdl_download_video 的照片階段沒抓到照片時。"
            "回傳的 files 每筆有 kind（image / video / other）與 existing（先前已下載過）；"
            "media_counts 統計張數。公開貼文免登入（IG 單篇貼文未登入時會自動改用 yt-dlp 的公開介面，"
            "engine 欄位會是 yt-dlp）；需要登入時帶 use_login_browser=true（建議），或 cookies_file"
            "（Netscape 格式 cookies.txt）／cookies_from_browser。請給單篇貼文網址，帳號頁最多只抓 max_files 個檔案"
            "（除非帶 download_all=true 整批下載，見下方參數說明）。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": ("單篇貼文網址，例如 https://www.instagram.com/p/XXXX/、"
                                    "https://x.com/<帳號>/status/<數字>、https://www.facebook.com/<粉專>/posts/<ID>、"
                                    "https://www.facebook.com/photo/?fbid=<數字>。"),
                },
                "out_dir": _COMMON_DL_PROPS["out_dir"],
                "cookies_file": {
                    "type": "string",
                    "description": "Netscape 格式 cookies.txt 的路徑；網站要求登入時使用。",
                },
                "cookies_from_browser": _COMMON_DL_PROPS["cookies_from_browser"],
                "use_login_browser": _COMMON_DL_PROPS["use_login_browser"],
                "max_files": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": _IMG_MAX_FILES_LIMIT,
                    "default": _IMG_DEFAULT_MAX_FILES,
                    "description": ("最多下載幾個檔案（防止誤貼帳號頁時把整個帳號抓下來）；預設 100，"
                                    "除非 download_all=true（整批下載沒給時不設上限）。"),
                },
                "download_all": {
                    "type": "boolean",
                    "default": False,
                    "description": (
                        "整批下載：url 是 IG 帳號頁 instagram.com/<帳號>/（或直接給 @帳號）、自己的珍藏 "
                        "instagram.com/<自己的帳號>/saved/，或珍藏分類 instagram.com/<自己的帳號>/saved/<分類名稱>/<數字ID>/ "
                        "時，下載全部貼文的照片與影片；必須同時帶 use_login_browser=true（或其他 cookie）；"
                        "檔案存到輸出資料夾底下以帳號／分類命名的子資料夾；不設檔案數上限（有給 max_files 才設）；"
                        "每個檔案之間隨機等待（常態分佈 0～4 秒、平均 2 秒），所以很慢，可能跑數十分鐘以上；"
                        "已下載過的檔案會略過，可重跑接續。"
                    ),
                },
            },
            "required": ["url"],
        },
    },
    {
        "name": "mdl_doctor",
        "description": (
            "環境自我檢查：yt-dlp、gallery-dl（照片用）與 ffmpeg 是否就緒及其版本、輸出資料夾能不能寫、"
            "Python 版本、設定檔是否可讀、登入瀏覽器狀態。下載一直失敗時先跑這個確認環境。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "out_dir": _COMMON_DL_PROPS["out_dir"],
            },
            "required": [],
        },
    },
    {
        "name": "mdl_login_browser",
        "description": (
            "管理「登入瀏覽器」：本工具專用的 Chrome/Edge 視窗（獨立設定檔，不會碰使用者自己的 Chrome）。"
            "下載工具帶 use_login_browser=true 時就用這個視窗的 cookie。"
            "action=status：是否開著、設定檔是否存在、instagram / facebook / x 是否已登入"
            "（視窗開著才讀得到，否則 logged_in 為 null；probe=true 會在關著時用無頭模式實際檢查，多花 2~5 秒）。"
            "action=open：開啟視窗（已開則開新分頁到 url），讓使用者登入網站或瀏覽要下載的內容；"
            "登入必須由使用者本人在視窗中完成。"
            "action=tabs：列出目前開著的分頁（url、title），likely_current_url 多半是使用者正在看的那頁，"
            "可以直接拿來下載。action=close：關閉登入瀏覽器。"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": list(BROWSER_ACTIONS),
                    "default": "status",
                    "description": "status / open / tabs / close。",
                },
                "url": {
                    "type": "string",
                    "description": "action=open 時要開的網址（http/https），例如 https://www.instagram.com/。",
                },
                "probe": {
                    "type": "boolean",
                    "default": False,
                    "description": "action=status 且視窗沒開時，用無頭模式實際讀 cookie 判斷登入狀態。",
                },
            },
            "required": ["action"],
        },
    },
]


def call_tool(name: str, args: dict) -> dict:
    """
    Agent / MCP server 的統一入口。永遠回傳 dict，絕不拋例外。
    """
    try:
        args = dict(args or {})
        args.setdefault("json_mode", True)  # agent 呼叫一律不輸出進度到 stdout

        if name == "mdl_info":
            return get_info(args.get("url", ""), **_strip(args, "url"))
        if name == "mdl_download_video":
            return download(args.get("url", ""), mode="mp4", **_strip(args, "url", "mode"))
        if name == "mdl_download_audio":
            return download(args.get("url", ""), mode="mp3", **_strip(args, "url", "mode"))
        if name == "mdl_list_formats":
            return list_formats(args.get("url", ""), json_mode=True, **_strip(args, "url", "json_mode"))
        if name == "mdl_batch_download":
            urls = args.get("urls") or []
            if isinstance(urls, str):
                urls = [urls]
            return batch_download(urls, mode=args.get("mode", "mp4"), **_strip(args, "urls", "mode"))
        if name == "mdl_download_images":
            return download_images(args.get("url", ""), **_strip(args, "url"))
        if name == "mdl_doctor":
            return doctor(**_strip(args, "json_mode"))
        if name == "mdl_login_browser":
            return login_browser(**_strip(args, "json_mode"))

        return {"ok": False, "error": f"unknown tool: {name}"}
    except Exception as exc:
        return _fail(_envelope(str(name)), f"{type(exc).__name__}: {exc}",
                     "這是 mdl.py 內部錯誤，請檢查傳入的參數。")


def _strip(args: dict, *keys: str) -> dict:
    """移除已當成位置參數使用的鍵，其餘原樣傳給函式。"""
    return {k: v for k, v in args.items() if k not in keys}


# ==========================================================================
# 7. CLI
# ==========================================================================

def _add_shared_download_opts(parser: argparse.ArgumentParser, profiles: dict) -> None:
    parser.add_argument("--out", dest="out_dir", default=None,
                        help="輸出資料夾（預設 <root>\\downloads，不存在會自動建立）")
    parser.add_argument("--quality", default="best",
                        choices=profiles.get("quality_choices", _QUALITY_ENUM),
                        help="影片畫質上限（video/batch mp4 用）")
    parser.add_argument("--audio-quality", dest="audio_quality", default="0",
                        choices=profiles.get("audio_quality_choices", _AUDIO_QUALITY_ENUM),
                        help="mp3 音質（audio/batch mp3 用，預設 0 = 最佳）")
    parser.add_argument("--playlist", action="store_true",
                        help="下載整個播放清單（預設只抓單支）")
    parser.add_argument("--clip", default=None,
                        help="只擷取區段，例如 00:01:00-00:02:30")
    parser.add_argument("--subs", default=None,
                        help="下載並內嵌字幕語言，例如 zh-TW,en")
    parser.add_argument("--cookies-from-browser", dest="cookies_from_browser", default=None,
                        help="從瀏覽器讀 cookies，例如 chrome")
    parser.add_argument("--cookies", default=None, help="cookies.txt 檔路徑")
    _add_login_browser_flag(parser)
    parser.add_argument("--name", default=None, help="覆寫輸出檔名樣板（yt-dlp -o 語法）")
    parser.add_argument("--extra-arg", dest="extra_args", action="append", default=[],
                        help="原樣附加給 yt-dlp 的參數（可重複）")


def _add_login_browser_flag(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--login-browser", dest="use_login_browser", action="store_true",
                        help="用登入瀏覽器的 cookie（先用「登入瀏覽器.bat」登入過；平常用的 Chrome 不必關）" + "；與 --cookies / --cookies-from-browser 互斥")


def _add_no_photos_flag(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--no-photos", dest="no_photos", action="store_true",
                        help="只下載影片：IG / FB / X 貼文裡的照片不要一併下載（預設會一併下載；只影響 mp4 模式）")


def build_parser(profiles: dict) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mdl.py",
        description="免安裝影音下載器核心引擎（yt-dlp 包裝）。所有子指令都支援 --json。",
    )
    parser.add_argument("--json", dest="json_global", action="store_true",
                        help="以 JSON 輸出（也可放在子指令後面）")

    # 每個子指令共用的輸出旗標
    io_parent = argparse.ArgumentParser(add_help=False)
    io_parent.add_argument("--json", dest="json_local", action="store_true", help="以 JSON 輸出")
    io_parent.add_argument("--quiet", action="store_true", help="不要輸出進度")

    sub = parser.add_subparsers(dest="command", metavar="<command>")

    p_info = sub.add_parser("info", parents=[io_parent], help="查詢影片資訊（不下載）")
    p_info.add_argument("url")
    p_info.add_argument("--cookies-from-browser", dest="cookies_from_browser", default=None)
    p_info.add_argument("--cookies", default=None)
    _add_login_browser_flag(p_info)

    p_video = sub.add_parser(
        "video", parents=[io_parent],
        help="下載影片為 mp4（IG / FB / X 貼文的照片會一併下載，--no-photos 可關閉）")
    p_video.add_argument("url")
    _add_shared_download_opts(p_video, profiles)
    _add_no_photos_flag(p_video)

    p_audio = sub.add_parser("audio", parents=[io_parent], help="下載音訊為 mp3")
    p_audio.add_argument("url")
    _add_shared_download_opts(p_audio, profiles)

    p_fmt = sub.add_parser("formats", parents=[io_parent], help="列出可用格式")
    p_fmt.add_argument("url")
    p_fmt.add_argument("--cookies-from-browser", dest="cookies_from_browser", default=None)
    p_fmt.add_argument("--cookies", default=None)
    _add_login_browser_flag(p_fmt)

    p_batch = sub.add_parser("batch", parents=[io_parent],
                             help="批次下載多個 URL 或一個 .txt 清單檔")
    p_batch.add_argument("sources", nargs="+", help="多個 URL，或一個每行一個 URL 的 .txt 路徑")
    p_batch.add_argument("--mode", choices=["mp4", "mp3"], default="mp4", help="下載模式（預設 mp4）")
    _add_shared_download_opts(p_batch, profiles)
    _add_no_photos_flag(p_batch)

    p_img = sub.add_parser(
        "images", parents=[io_parent],
        help="下載 IG / FB / X 貼文的照片（整則貼文，輪播裡的影片也一起抓；gallery-dl）")
    p_img.add_argument("url", help="單篇貼文網址")
    p_img.add_argument("--out", dest="out_dir", default=None,
                       help="輸出資料夾（預設 <root>\\downloads，不存在會自動建立）")
    p_img.add_argument("--cookies", default=None, help="cookies.txt 檔路徑（Netscape 格式）")
    p_img.add_argument("--cookies-from-browser", dest="cookies_from_browser", default=None,
                       help="從瀏覽器讀 cookies，例如 chrome")
    _add_login_browser_flag(p_img)
    p_img.add_argument("--name", default=None,
                       help="覆寫檔名樣板（gallery-dl 格式字串，例如 \"{category}_{id}.{extension}\"）")
    p_img.add_argument("--max-files", dest="max_files", type=int, default=None,
                       help=f"最多下載幾個檔案（預設 {_IMG_DEFAULT_MAX_FILES}；加了 --all 時預設不設上限）")
    p_img.add_argument("--all", dest="download_all", action="store_true",
                       help="整批下載：IG 帳號頁（或直接給 @帳號）的所有貼文、自己的珍藏 "
                            "instagram.com/<帳號>/saved/、珍藏分類 .../saved/<分類>/<ID>/。要登入 cookie；"
                            "存到以帳號／分類命名的子資料夾，每個檔案之間隨機等待（常態分佈，預設 0～4 秒、平均 2 秒）")
    p_img.add_argument("--extra-arg", dest="extra_args", action="append", default=[],
                       help="原樣附加給 gallery-dl 的參數（可重複）")

    p_br = sub.add_parser("browser", parents=[io_parent],
                          help="登入瀏覽器：status / open / tabs / close（tools\\browser.ps1）")
    p_br.add_argument("browser_action", nargs="?", default="status", choices=BROWSER_ACTIONS,
                      help="status（預設）/ open / tabs / close")
    p_br.add_argument("--url", default=None, help="open 時要開的網址")
    p_br.add_argument("--probe", action="store_true",
                      help="status：視窗沒開時也用無頭模式實際檢查登入狀態（多 2~5 秒）")

    sub.add_parser("update", parents=[io_parent], help="更新 yt-dlp 與 gallery-dl")

    p_doctor = sub.add_parser("doctor", parents=[io_parent], help="環境自我檢查")
    p_doctor.add_argument("--out", dest="out_dir", default=None, help="要檢查的輸出資料夾")

    sub.add_parser("schema", parents=[io_parent], help="印出給 LLM agent 用的工具定義 JSON")

    p_tool = sub.add_parser("tool", parents=[io_parent], help="agent 呼叫入口（只輸出一份 JSON）")
    p_tool.add_argument("tool_name")
    p_tool.add_argument("payload", nargs="?", default="{}",
                        help="JSON 字串；用 - 代表從 stdin 讀取")

    return parser


def _opts_from_args(args: argparse.Namespace, json_mode: bool) -> dict:
    """把 argparse 結果轉成核心函式吃的 opts。"""
    return {
        "out_dir": getattr(args, "out_dir", None),
        "quality": getattr(args, "quality", "best"),
        "audio_quality": getattr(args, "audio_quality", "0"),
        "playlist": getattr(args, "playlist", False),
        "clip": getattr(args, "clip", None),
        "subs": getattr(args, "subs", None),
        "cookies_from_browser": getattr(args, "cookies_from_browser", None),
        "cookies": getattr(args, "cookies", None),
        "use_login_browser": getattr(args, "use_login_browser", False),
        "include_photos": not getattr(args, "no_photos", False),
        "name": getattr(args, "name", None),
        "extra_args": getattr(args, "extra_args", []) or [],
        "quiet": getattr(args, "quiet", False),
        "json_mode": json_mode,
    }


def _print_human(env: dict) -> None:
    """非 --json 模式的人類可讀摘要。"""
    action = env.get("action")

    if action == "info":
        info = env.get("info") or {}
        rows = [
            ("標題", info.get("title")),
            ("上傳者", info.get("uploader")),
            ("長度(秒)", info.get("duration")),
            ("上傳日期", info.get("upload_date")),
            ("站台", info.get("site")),
            ("最高解析度", info.get("max_resolution")),
            ("觀看數", info.get("view_count")),
            ("直播中", info.get("is_live")),
            ("網址", info.get("webpage_url")),
        ]
        for key, value in rows:
            print(f"{key:<10}: {value if value is not None else '-'}")
    elif action == "formats":
        formats = env.get("formats") or []
        if formats:
            print(f"{'ID':<14}{'EXT':<6}{'解析度':<14}{'FPS':<6}{'大小':<12}VCODEC/ACODEC")
            for f in formats:
                size = f.get("filesize")
                size_txt = f"{size/1048576:.1f}MB" if isinstance(size, int) else "-"
                print(f"{str(f.get('format_id') or '-'):<14}{str(f.get('ext') or '-'):<6}"
                      f"{str(f.get('resolution') or '-'):<14}{str(f.get('fps') or '-'):<6}"
                      f"{size_txt:<12}{f.get('vcodec')}/{f.get('acodec')}")
    elif action == "doctor":
        checks = env.get("checks") or {}
        for key, value in checks.items():
            print(f"[{key}] {json.dumps(value, ensure_ascii=False)}")
    elif action == "login_browser":
        _print_login_browser(env)
    elif action == "batch":
        stats = env.get("stats") or {}
        print(f"\n批次完成：共 {stats.get('total')} 筆，成功 {stats.get('ok')}、失敗 {stats.get('failed')}")
        for item in env.get("results") or []:
            mark = "OK  " if item.get("ok") else "FAIL"
            first = (item.get("files") or [{}])[0].get("name") if item.get("files") else None
            print(f"  {mark} {item.get('url')} -> {first or item.get('error') or '-'}")
    else:
        kind_label = {"image": "照片", "video": "影片", "other": "其他"}
        counts = env.get("media_counts") or {}
        # 影片模式只有在真的一併抓到照片時才標示種類（一般影片下載的輸出維持原樣）
        show_kind = action == "images" or bool(counts.get("images"))
        for f in env.get("files") or []:
            size = f.get("size")
            size_txt = f"{size/1048576:.1f}MB" if isinstance(size, int) else "?"
            tags = []
            if f.get("kind") and show_kind:
                tags.append(kind_label.get(f["kind"], f["kind"]))
            if f.get("existing"):
                tags.append("先前已下載")
            tag_txt = f"[{'/'.join(tags)}] " if tags else ""
            print(f"完成：{tag_txt}{f.get('path')}（{size_txt}）")
        if action == "images" and env.get("files"):
            c = env.get("media_counts") or {}
            print(f"共 {len(env['files'])} 個檔案：照片 {c.get('images', 0)}、影片 {c.get('videos', 0)}"
                  f"（引擎：{env.get('engine')}）")
        elif action == "video" and counts.get("images"):
            print(f"共 {len(env['files'])} 個檔案：影片 {counts.get('videos', 0)}、照片 {counts.get('images', 0)}"
                  "（貼文裡的照片已一併下載；不要照片可加 --no-photos）")
        if env.get("elapsed_sec") is not None:
            print(f"耗時 {env['elapsed_sec']}s，嘗試 {env.get('attempts')} 次")

    src = env.get("cookie_source")
    if isinstance(src, dict) and src.get("type") == "login_browser" and src.get("mode"):
        doms = "、".join(src.get("domains") or []) or "全部網域"
        print(f"cookie 來源：登入瀏覽器（{src.get('mode')}，{src.get('browser')}，{doms} 共 {src.get('count')} 顆）")

    for warn in env.get("warnings") or []:
        print(f"[警告] {warn}", file=sys.stderr)
    if not env.get("ok"):
        print(f"[錯誤] {env.get('error')}", file=sys.stderr)
        if env.get("hint"):
            print(f"[建議] {env['hint']}", file=sys.stderr)
        for line in env.get("log_tail") or []:
            print(f"    | {line}", file=sys.stderr)


def _print_login_browser(env: dict) -> None:
    act = env.get("browser_action")
    if not env.get("ok"):
        return
    if act == "status":
        logged = env.get("logged_in")
        logged_txt = ("、".join(f"{k}={'已登入' if v else '未登入'}" for k, v in logged.items())
                      if isinstance(logged, dict) else "未知（視窗沒開；加 --probe 可檢查）")
        rows = [
            ("瀏覽器", f"{env.get('browser') or '-'} {env.get('version') or ''}".strip()),
            ("設定檔", env.get("profile")),
            ("設定檔已建立", env.get("profile_exists")),
            ("執行中", f"是（port {env.get('port')}）" if env.get("running") else "否"),
            ("登入狀態", logged_txt),
        ]
        for key, value in rows:
            print(f"{key:<8}: {value if value is not None else '-'}")
        if env.get("hint"):
            print(f"[建議] {env['hint']}")
    elif act == "tabs":
        if not env.get("running"):
            print("登入瀏覽器沒有開著。")
        for t in env.get("tabs") or []:
            print(f"- {t.get('title') or '(無標題)'}")
            print(f"  {t.get('url')}")
    elif act == "open":
        mode = {"launched": "已啟動登入瀏覽器", "new_tab": "已在登入瀏覽器開新分頁",
                "already_running": "登入瀏覽器已經開著"}.get(env.get("mode"), env.get("mode"))
        print(f"{mode}" + (f"：{env.get('url')}" if env.get("url") else ""))
    elif act == "close":
        print("已關閉登入瀏覽器。" if env.get("was_running") else "登入瀏覽器本來就沒開。")


def _emit(env: dict, json_mode: bool) -> int:
    if json_mode:
        # 機器讀的輸出一律純 ASCII（中文轉成 \u 跳脫）：Windows 上 subprocess(text=True)、
        # PowerShell 預設用 cp950 讀子程序輸出，UTF-8 中文路徑會把 JSON 的跳脫字元吃壞。
        print(json.dumps(env, indent=2))
    else:
        _print_human(env)
    return 0 if env.get("ok") else 1


def main(argv: list[str] | None = None) -> int:
    # Windows 主控台預設 cp950，中文標題會爆；用 try/except 保護
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

    profiles = load_profiles()
    parser = build_parser(profiles)
    args = parser.parse_args(argv)

    if not getattr(args, "command", None):
        parser.print_help()
        return 0

    json_mode = bool(getattr(args, "json_local", False) or getattr(args, "json_global", False))
    cmd = args.command

    try:
        if cmd == "schema":
            print(json.dumps(TOOL_SCHEMAS, indent=2))
            return 0

        if cmd == "tool":
            payload = args.payload
            if payload == "-":
                payload = sys.stdin.read()
            # PowerShell 管線常帶 UTF-8 BOM，先清掉再解析
            payload = (payload or "{}").lstrip("﻿").strip() or "{}"
            try:
                tool_args = json.loads(payload)
            except Exception as exc:
                print(json.dumps({"ok": False, "error": f"payload 不是合法 JSON：{exc}"},
                                 indent=2))
                return 1
            if not isinstance(tool_args, dict):
                print(json.dumps({"ok": False, "error": "payload 必須是 JSON 物件。"},
                                 indent=2))
                return 1
            result = call_tool(args.tool_name, tool_args)
            print(json.dumps(result, indent=2))
            return 0 if result.get("ok") else 1

        if cmd == "doctor":
            return _emit(doctor(out_dir=getattr(args, "out_dir", None)), json_mode)

        if cmd == "browser":
            return _emit(login_browser(args.browser_action, url=args.url, probe=args.probe), json_mode)

        if cmd == "update":
            return _emit(update(json_mode=json_mode, quiet=getattr(args, "quiet", False)), json_mode)

        if cmd == "info":
            opts = _opts_from_args(args, json_mode)
            return _emit(get_info(args.url, **opts), json_mode)

        if cmd == "formats":
            opts = _opts_from_args(args, json_mode)
            opts.pop("json_mode", None)
            return _emit(list_formats(args.url, json_mode=json_mode, **opts), json_mode)

        if cmd in ("video", "audio"):
            opts = _opts_from_args(args, json_mode)
            mode = "mp4" if cmd == "video" else "mp3"
            return _emit(download(args.url, mode=mode, **opts), json_mode)

        if cmd == "batch":
            opts = _opts_from_args(args, json_mode)
            return _emit(batch_download(args.sources, mode=args.mode, **opts), json_mode)

        if cmd == "images":
            return _emit(download_images(
                args.url,
                out_dir=args.out_dir,
                cookies_file=args.cookies,
                cookies_from_browser=args.cookies_from_browser,
                name=args.name,
                max_files=args.max_files,
                download_all=args.download_all,
                use_login_browser=args.use_login_browser,
                extra_args=args.extra_args or [],
                quiet=getattr(args, "quiet", False),
                json_mode=json_mode,
            ), json_mode)

        parser.print_help()
        return 0

    except KeyboardInterrupt:
        env = _fail(_envelope(cmd), "使用者中斷（Ctrl+C）。", None)
        return _emit(env, json_mode)
    except Exception as exc:
        env = _fail(_envelope(cmd), f"{type(exc).__name__}: {exc}",
                    "這是 mdl.py 內部錯誤，請把這段訊息回報給開發者。")
        return _emit(env, json_mode)


if __name__ == "__main__":
    sys.exit(main())
