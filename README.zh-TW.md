# 影音下載器（免安裝）

[English](README.md) | **繁體中文**

> ## ⚠️ 免責聲明（請先閱讀）
>
> - 本工具**僅供下載你自己擁有、或已取得授權的內容**（例如備份自己上傳的影片、離線觀看已獲授權的素材、或著作權法容許的合理使用範圍）。
> - YouTube、Instagram、Facebook、X 等各平台的**服務條款多半禁止未經授權的下載行為**；是否使用、如何使用，責任完全在你。
> - 影音、照片的**著作權屬於權利人**。下載不等於取得授權，請勿散布他人受著作權保護的內容，也不要用於商業用途。
> - 「登入瀏覽器／cookie 匯入」功能**只應用在你自己的帳號**。cookie 等同登入憑證，**請勿分享、上傳或提交到任何公開地方**。
> - 使用者須**自行承擔一切法律責任**；本工具的作者與貢獻者不對使用者的任何行為或後果負責。不確定某個用途合不合法，就不要下載。

一個放在資料夾裡就能用的 Windows 影音下載工具。底層是 [yt-dlp](https://github.com/yt-dlp/yt-dlp)（影片／音訊）+ [gallery-dl](https://codeberg.org/mikf/gallery-dl)（IG / FB / X 貼文照片）+ [ffmpeg](https://ffmpeg.org/)，執行檔都下載到專案的 `bin\` 資料夾裡，**不寫登錄檔、不裝到系統、不需要管理員權限**。整包資料夾複製到別台電腦或隨身碟就能繼續用；不想要了直接刪掉整個資料夾即可（登入瀏覽器的設定檔另外放在 `%LOCALAPPDATA%\影音下載器\`，見〈登入瀏覽器〉）。

提供三種用法：**雙擊 GUI**、**命令列**、**給 AI agent 呼叫**。需要登入的內容（私人帳號、限時動態、會員影片…）用**登入瀏覽器**取得 cookie，平常用的 Chrome 不必關。

---

## 快速開始

1. 把整個 zip 解壓縮到任何一個你有寫入權限的資料夾（例如 `D:\工具\影音下載器`）。
2. 雙擊 **`首次設定.bat`** —— 它會自動下載 `yt-dlp.exe`、`gallery-dl.exe`、`ffmpeg.exe` 到 `bin\`（gallery-dl 已把發行搬到 Codeberg，所以從 Codeberg 下載，失敗才退回 GitHub）。需要網路，第一次大約要跑一兩分鐘。**這一步不是選配**：實測 YouTube 目前已經不再提供「影音已合併」的格式，沒有 ffmpeg 就完全抓不到 YouTube（詳見〈疑難排解〉）。
3. 雙擊 **`影音下載器.bat`** —— 開啟圖形介面，貼網址就能下載。

> 只有第 2 步需要網路以外的等待，而且**只需要做一次**。之後想更新 yt-dlp / gallery-dl 就在命令列跑 `mdl.bat update`（兩個都會更新），或重跑 `首次設定.bat`。
>
> 要下載需要登入的內容時，再多做一步：雙擊 **`登入瀏覽器.bat`**，在跳出來的視窗登入該網站一次（見〈登入瀏覽器〉）。

GUI 不需要安裝 Python（它是 PowerShell WinForms 寫的）。**命令列與 agent 介接**（`mdl.bat` / `src\mdl.py` / MCP）才需要系統上有 Python 3.8 以上（實測過 3.10 與 3.12）。

---

## 資料夾結構

```
影音下載器\
├─ 影音下載器.bat            雙擊開 GUI
├─ 首次設定.bat              下載 bin\yt-dlp.exe + gallery-dl.exe + ffmpeg.exe
├─ 登入瀏覽器.bat            開啟登入瀏覽器（登入 IG / FB / X 等網站用）
├─ mdl.bat                   命令列轉發器 → src\mdl.py
├─ README.md                 本說明
├─ bin\                      yt-dlp.exe / gallery-dl.exe / ffmpeg.exe / ffprobe.exe（首次設定後才有）
├─ config\
│   └─ profiles.json         GUI 與引擎共用的 yt-dlp 參數
├─ src\
│   ├─ mdl.py                核心引擎 + CLI + agent 工具 API（純標準函式庫）
│   ├─ mcp_server.py         MCP stdio server
│   └─ example_agent_use.py  直接 import 使用的範例
├─ tools\
│   ├─ setup.ps1             首次設定的實作
│   ├─ gui.ps1               GUI 的實作
│   └─ browser.ps1           登入瀏覽器（開視窗、透過 CDP 匯出 cookie）
└─ downloads\                預設輸出資料夾

%LOCALAPPDATA%\影音下載器\    （不在專案裡）
├─ browser\                  登入瀏覽器的設定檔（含登入 session，不要分享）
└─ browser_state.json        登入瀏覽器目前的 port / PID
```

`config\profiles.json` 是 GUI 和引擎**共用**的設定，改一次兩邊同時生效（畫質清單、輸出檔名樣板、重試次數等都在裡面）。整批下載（見〈整批下載 IG 帳號／珍藏〉）的隨機等待時間 `bulk_sleep` 也在這裡。

---

## GUI 使用說明

雙擊 `影音下載器.bat` 之後，視窗由上到下是：

1. **貼網址** —— 可以一次貼多行，一行一個網址，會依序處理。播放清單網址也可以直接貼。
2. **選模式** —— 「**MP4 影片**」、「**MP3 音樂**」（只要聲音）或「**圖片 (IG/FB/X)**」（見下方〈圖片模式〉）。
3. **選畫質／音質**（與模式同一列）—— 影片模式用「畫質」：`best` / `2160` / `1440` / `1080` / `720` / `480` / `360`，選 `1080` 的意思是「不超過 1080p 的最佳畫質」，來源沒那麼高就自動取最高的。音樂模式用「音質」：`0 (最佳)` / `320K` / `256K` / `192K` / `128K`。用不到的那一個會變灰。
4. **選輸出資料夾** —— 預設是專案底下的 `downloads\`，按「瀏覽」可以改到任何地方。
5. **勾選項**（同一列，三個；圖片模式多一個，見下表最後一列）：

   | 勾選項 | 適用模式 | 作用 |
   | --- | --- | --- |
   | **下載整個播放清單** | 影片、音樂 | 網址是播放清單時整份下載，存到以清單名稱命名的子資料夾；不勾就只抓網址指到的那一支。 |
   | **嵌入字幕(自動選中英)** | 影片 | 把字幕嵌進 mp4。字幕檔只是過程中的暫存，不會留在資料夾裡，資料夾裡原本就有的同名字幕檔也不會被動到（見〈MP3 音樂與字幕：不會動到資料夾裡既有的檔案〉）。 |
   | **貼文照片一併下載** | 影片（預設勾選） | 貼 IG / FB / X 的貼文網址時，影片下載完自動把同一則貼文的照片也抓下來，詳見下一節。 |
   | **整個帳號／珍藏 (IG)** | 圖片 | 貼帳號頁（`instagram.com/<帳號>/`，或 `…/reels/`、`…/tagged/`）或自己的珍藏網址時，整批下載，不受每則 100 個檔案的上限。需要同時勾選「使用登入瀏覽器的 cookie」。詳見〈整批下載 IG 帳號／珍藏〉。 |

6. **Cookie**（需要登入的內容才用得到，各佔一列）—— 「**用瀏覽器 Cookie**」＋瀏覽器選單自成一列（舊做法）；它的下一列是**登入瀏覽器**（建議做法），見〈登入瀏覽器（需要登入的內容）〉。兩者只能擇一。
7. **按「開始下載」** —— 進度與訊息顯示在下方的日誌；同一列還有「停止」、「開啟資料夾」、「更新 yt-dlp」、「現在設定」（重跑首次設定）、「清除日誌」。

模式、畫質／音質、輸出資料夾與各勾選項都會記在 `config\gui_settings.json`，下次開啟沿用。

### 「貼文照片一併下載」（MP4 影片模式）

預設勾選，而且**只在「MP4 影片」模式有作用**（其他模式會變灰）。勾選時，貼社群**貼文**網址不必先想「這則是影片還是照片」：影片照常由 yt-dlp 下載（畫質設定照舊），接著自動把同一則貼文的**照片**也抓到同一個資料夾；只有照片的貼文也算成功，不必切到圖片模式。

| 網站 | 會補抓照片的網址 | 不受影響（只抓影片，和以前完全一樣） |
| --- | --- | --- |
| Instagram | 貼文 `/p/<代碼>/`；限時動態 `/stories/<帳號>/`（要登入，所以只有勾了 cookie 時才補抓） | Reel：`/reel/`、`/reels/`、`/tv/` |
| X（Twitter） | 推文 `/<帳號>/status/<數字>` | 其他 |
| Facebook | 貼文／照片網址：`/posts/`、`/permalink`、`story.php`、`/photo`、`/photos/<ID>` | `/videos/`、`/watch`、`/reel/`、`fb.watch` |
| YouTube 等其他網站 | —— | 全部（完全不會呼叫 gallery-dl） |

- **FB 的分享短網址 `facebook.com/share/p/…` 在 GUI 不支援補抓照片**（日誌會說明）：請在瀏覽器打開那個連結，等它跳到貼文本身之後，複製網址列的網址再貼上來。（命令列的 `mdl.bat video` 會自己解析這種短網址。）
- 照片的檔名與圖片模式相同（`<帳號>_<貼文ID>_<序號>.<副檔名>`），已經下載過的不會重抓；影片不會被重複下載。
- **取消勾選**就只抓影片：這時只有照片的貼文會失敗，日誌會建議勾回這個選項或改用圖片模式。
- 找不到 `bin\gallery-dl.exe` 時不會補抓（日誌會提醒重跑「首次設定.bat」），影片照常下載。

## 圖形介面：圖片與登入瀏覽器

### 圖片模式（IG / FB / X 貼文）
在格式選「**圖片 (IG/FB/X)**」，貼上**單篇貼文**網址（可多行），按「開始下載」。整則貼文的照片都會下載，輪播裡的影片也會一起抓；畫質／音質／字幕／播放清單在這個模式下不適用。

- 引擎是 `bin\gallery-dl.exe`（首次設定會下載），參數與 `mdl.bat images` 相同：不讀你自己的 gallery-dl 設定、不留快取；每則最多 100 個檔案（防止誤貼帳號頁把整個帳號抓下來；除非勾選「整個帳號／珍藏 (IG)」，見〈整批下載 IG 帳號／珍藏〉）。
- 檔名：`<帳號>_<貼文ID>_<序號>.<副檔名>`，已下載過的檔案不會重抓，日誌會標「已存在」。IG **限時動態／精選動態**是 `<帳號>_story_<日期>_<該則的代碼>.<副檔名>`（例如 `natgeo_story_2026-10-05_DeHSGl8xx4D.jpg`）：每一則有自己固定的名字，隔天的新限時動態不會和舊的撞名。
- 支援的網址：IG `instagram.com/p/<代碼>/`、`/reel/…`；X `x.com/<帳號>/status/<數字>`；FB `facebook.com/photo/?fbid=<數字>`、`facebook.com/<粉專>/posts/<ID>`。`facebook.com/<粉專>/photos/<ID>/` 會自動改寫成單張照片網址（否則會被當成整個粉專相片牆）。
- **Instagram 未登入**：gallery-dl 會被導到登入頁，GUI 自動改用 yt-dlp 的公開介面抓同一則貼文（照片直接下載原圖、影片交給 yt-dlp），日誌會註明「已改用 yt-dlp」。私人帳號或限制級內容仍需登入，見下方登入瀏覽器。
- 結果以磁碟為準：只列出確實存在、非 0 位元組、而且真的是圖片／影片的檔案（抓到錯誤網頁會自動排除）。
- **「MP4 影片」模式也會順便抓貼文照片**：由「**貼文照片一併下載**」勾選框控制，預設勾選，見上方〈「貼文照片一併下載」（MP4 影片模式）〉。什麼時候還是用圖片模式：想讓 gallery-dl 抓整則貼文（輪播裡的影片也交給它）、或要抓相簿／相片牆（每則最多 100 個檔案，除非勾選「整個帳號／珍藏 (IG)」）。
- 要整批下載整個 IG 帳號或自己的珍藏：勾選「**整個帳號／珍藏 (IG)**」（需要登入），見〈整批下載 IG 帳號／珍藏〉。

### 登入瀏覽器（需要登入的內容）
勾選項的下面有兩列和 cookie 有關。上面一列是舊做法「**用瀏覽器 Cookie**」＋瀏覽器選單（chrome / edge / firefox / brave）：直接讀你本機瀏覽器的 cookie，Chrome／Edge 開著時通常會失敗。它的下面一列就是登入瀏覽器：

| 控制項 | 作用 |
| --- | --- |
| **開啟登入瀏覽器** | 開一個專用的 Chrome／Edge 視窗（獨立設定檔，放在 `%LOCALAPPDATA%\影音下載器\browser`）。在裡面登入 IG / FB / X，只需登入一次。**你平常用的 Chrome 完全不受影響，可以照常開著。** 網址欄有網址時會直接開那個網址；已經開著就開新分頁。 |
| **抓目前分頁網址** | 把登入瀏覽器目前開著的網頁網址加進網址欄；有多個分頁時會列出來讓你選（最近使用的在上面，可多選）。 |
| **使用登入瀏覽器的 cookie** | 勾選後，每次下載前自動從登入瀏覽器匯出 cookie 給 yt-dlp／gallery-dl 使用（暫存檔，下載完立即刪除）。登入瀏覽器沒開也可以（會在背景讀取，多花約 2～5 秒）。 |
| 登入狀態 | 例如 `登入狀態：IG ✔ FB ✖ X ?`（✔ 已登入、✖ 未登入、? 未知）。登入瀏覽器沒開時顯示「未開啟」。點一下可重新整理。 |

- 這是**建議的登入方式**：上一列的舊做法「用瀏覽器 Cookie」在 Chrome／Edge 開著時通常會失敗（`Could not copy Chrome cookie database`）。兩個選項只能擇一，勾了一個另一個會自動取消。
- 勾選了但該網站沒登入時，日誌會警告「本次等同未登入」，公開內容照樣能下載。
- 匯出失敗時會顯示原因並停止本次工作；可先按「開啟登入瀏覽器」確認能開，或取消勾選以未登入狀態下載。
- 登入瀏覽器的設定檔含有你的登入狀態，不要分享或上傳。
- 圖片模式與這個勾選框的狀態會記在 `config\gui_settings.json`，下次開啟沿用。

### MP3 音樂與字幕：不會動到資料夾裡既有的檔案

**MP3 音樂模式**（GUI 的「MP3 音樂」、`mdl.bat audio`、`batch --mode mp3`、agent 的 `mdl_download_audio` 都一樣）下載時，會先在輸出資料夾底下建立一個隱藏的暫存資料夾 `.mdltmp-xxxxxx`，轉檔前的來源檔與封面圖只放在裡面；轉好的 mp3 搬到輸出資料夾之後，暫存資料夾整個刪除（下載失敗、按「停止」、關閉視窗也一樣會刪）。所以：

- 輸出資料夾只會多出 `<標題> [<ID>].mp3`，不會留下中間檔或封面圖。
- **同名的既有檔案不會被刪除或改寫**——例如先前用影片模式下載的同一支影片 `<標題> [<ID>].mp4`、同名的圖片或字幕檔。
- 同名的 mp3 已經存在 → 直接略過，不重新下載、也不重寫那個檔案（GUI 日誌顯示「已存在，略過」；命令列／agent 的結果 `files` 該筆 `existing: true`）。播放清單只會下載還沒有的那幾首。
- 按「停止」不會留下續傳用的中間檔，下次是重新下載（音訊檔通常很小）。

**MP4 影片模式勾了「嵌入字幕」**時，字幕檔同樣只寫在輸出資料夾底下的隱藏暫存資料夾 `.mdltmp-subs`（下載結束、裡面沒有續傳檔時自動刪除），所以資料夾裡原本就有的同名字幕檔（`<標題> [<ID>].<語言>.srt` / `.vtt`，例如先前用命令列 `--subs` 另存的）不會被覆寫或刪除。

---

## 登入瀏覽器（需要登入的內容）

私人帳號、限時動態、IG 帳號頁、會員／年齡限制影片、Vimeo 這類內容要帶登入 cookie 才抓得到。本工具的做法是**登入瀏覽器**：用你電腦上已安裝的 Chrome（沒有就用 Edge）開一個**專用的、獨立設定檔的視窗**，你在裡面登入需要的網站一次，之後下載時加 `--login-browser`（agent：`use_login_browser: true`），工具就從這個視窗把 cookie 拿出來用。

**為什麼不直接讀你平常的 Chrome？** `--cookies-from-browser chrome` 在 Chrome 開著時會失敗（cookie 資料庫被鎖住：`Could not copy Chrome cookie database`），新版 Chrome 的 app-bound 加密也讓外部程式解不開 cookie。登入瀏覽器由瀏覽器自己透過 Chrome DevTools Protocol 交出 cookie，所以：

- **你平常用的 Chrome 可以一直開著**，完全不會被碰到（不讀它的設定檔、也不會關掉它的任何行程）。
- 登入瀏覽器**開著**時直接從視窗拿（`cookie_source.mode = "live"`）；**關著**時會用同一個設定檔在背景開一個看不見的瀏覽器，拿完就關（`"headless"`，約 2～5 秒）。所以登入一次之後，視窗關掉也照樣能用。

**怎麼用：**

1. 雙擊 **`登入瀏覽器.bat`**（或 `mdl.bat browser open --url https://www.instagram.com/`），在跳出的視窗登入 IG / FB / X 等需要的網站。**每個網站只要登入一次**，登入狀態會保存在設定檔裡。
2. 下載時加 `--login-browser`：

```bat
mdl.bat video  "https://www.instagram.com/stories/某帳號/" --login-browser
mdl.bat images "https://www.instagram.com/p/XXXXXXXXX/" --login-browser
mdl.bat batch  urls.txt --login-browser          :: 整批只匯出一次 cookie
```

3. 其他管理指令：

```bat
mdl.bat browser status          :: 有沒有開著、設定檔在哪、各網站登入狀態（開著時才知道）
mdl.bat browser status --probe  :: 視窗關著也實際檢查登入狀態（多 2～5 秒）
mdl.bat browser tabs            :: 列出目前開著的分頁（第一個通常是你正在看的那頁）
mdl.bat browser close           :: 關閉登入瀏覽器
```

**設定檔在哪、注意事項：**

- 設定檔預設放在 **`%LOCALAPPDATA%\影音下載器\browser`**（本機，不在專案資料夾裡），裡面有你在登入瀏覽器登入的所有 session，**等同於帳號登入狀態，不要複製、分享或上傳**。刻意不放在專案資料夾，是因為專案可能在雲端同步資料夾（Synology Drive / OneDrive…）裡：session 會被同步出去，同步程式也會鎖住 cookie 資料庫（實測會讀到 0 顆 cookie、背景瀏覽器關閉卡很久）。要改位置請設環境變數 `MDL_BROWSER_PROFILE`。
- 不想用了：關掉登入瀏覽器，刪除整個 `%LOCALAPPDATA%\影音下載器\` 資料夾即可。
- **不要短時間大量下載。** IG / FB 會偵測自動化存取，抓太多有可能讓帳號被要求驗證或暫時限制；遇到限制就停手，並遵守平台的使用規範。
- 登入瀏覽器只在本機 `127.0.0.1` 開 debug port（預設 9227），而且只在視窗開著的期間存在；但這段期間本機上的其他程式也能操控它，所以不用時可以關掉。
- 每次下載都會把 cookie 匯出到一個新的暫存檔（只含該網站需要的網域；不認得的網站則匯出全部），下載完立刻刪除。結果 JSON 的 `cookie_source` 會寫出來源、模式（live / headless）、匯出數量與 `logged_in`（instagram / facebook / x 是否已登入），**不會包含任何 cookie 的值**。
- 如果登入瀏覽器**還沒登入**目標網站，下載照常進行（公開內容仍然抓得到），但 `warnings` 會提醒「登入瀏覽器還沒登入 Instagram」之類的訊息；若網站仍要求登入，`hint` 會請你到登入瀏覽器登入。
- `--login-browser` 與 `--cookies` / `--cookies-from-browser` 只能擇一，同時給會直接回報錯誤。

---

## 整批下載 IG 帳號／珍藏

圖片模式預設只抓**一則貼文**（每則最多 100 個檔案）。要把**整個帳號**（所有貼文、Reels、被標註的貼文）或**自己的珍藏**（全部，或某個分類）一次抓下來，用這一節的功能：命令列加 `--all`，或 GUI 勾選「**整個帳號／珍藏 (IG)**」。

這需要登入：沒有帶 cookie 會直接回報錯誤、不會連線。

| 要下載什麼 | 網址 | 存到哪個子資料夾 |
| --- | --- | --- |
| 某個帳號的所有貼文 | `https://www.instagram.com/<帳號>/`（也可以只打 `@帳號`） | `<輸出資料夾>\<帳號>\` |
| 某個帳號的 Reels／被標註的貼文 | `…/<帳號>/reels/`、`…/<帳號>/tagged/` | `<帳號>\`、`<帳號>_tagged\` |
| 自己的全部珍藏 | `https://www.instagram.com/<你的帳號>/saved/` | `<你的帳號>_saved\` |
| 自己的某個珍藏分類 | `https://www.instagram.com/<你的帳號>/saved/<分類名稱>/<數字ID>/` | `<你的帳號>_saved_<分類名稱>\` |

### 怎麼用

**GUI：**

1. 需要時先雙擊 **`登入瀏覽器.bat`** 登入 IG（見〈登入瀏覽器〉）。
2. 雙擊 **`影音下載器.bat`**，格式選「**圖片 (IG/FB/X)**」。
3. 貼上帳號或珍藏的網址。
4. 勾選「**整個帳號／珍藏 (IG)**」與「**使用登入瀏覽器的 cookie**」。
5. 按「**開始下載**」。要中斷就按「**停止**」。

**命令列：**

```bat
mdl.bat images "https://www.instagram.com/某帳號/" --all --login-browser
mdl.bat images "https://www.instagram.com/你的帳號/saved/" --all --login-browser
mdl.bat images "https://www.instagram.com/你的帳號/saved/旅行/1234567890/" --all --login-browser
```

整批下載很花時間，建議先用 `--max-files` 試跑幾個檔案，確認能抓、存到對的地方，再拿掉上限整批下載：

```bat
mdl.bat images "https://www.instagram.com/某帳號/" --all --login-browser --max-files 20
```

**珍藏分類的網址怎麼拿：** 在登入瀏覽器打開 IG → 個人檔案 →「已珍藏」→ 點進那個分類，複製網址列的網址。GUI 可以按「**抓目前分頁網址**」，命令列可以用 `mdl.bat browser tabs` 列出分頁。網址一定要有最後那串數字 ID。珍藏只能抓**登入的那個帳號自己的**。

### 與一般圖片模式的差別

- 不受每則 100 個檔案的上限。命令列仍可用 `--max-files N` 設上限。
- 沒有 30 分鐘逾時。
- 檔案存到上表的子資料夾。
- 檔名不變：`<貼文作者帳號>_<貼文代碼>_<序號>.<副檔名>`（珍藏裡是各貼文原作者的帳號）。
- 照片與影片都抓。

### 每個檔案之後的隨機等待

整批下載會在**每個檔案下載完之後**隨機等一段時間，放慢節奏、降低對平台伺服器的負擔（爬蟲禮貌）。等待秒數是**常態分佈**：平均 2 秒、標準差約 0.67 秒（±3 個標準差 = 0～4 秒），超出範圍的夾回 0 或 4 秒。大約 68% 落在 1.3～2.7 秒，95% 落在 0.7～3.3 秒。

- 參數在 `config\profiles.json` 的 **`bulk_sleep`**（`mean` / `min` / `max`，單位秒；預設 2.0 / 0.0 / 4.0），GUI 與命令列共用。
- 已下載過而略過的檔案**不會**等待。
- gallery-dl 對 IG 的 API 請求（每翻一頁貼文清單）本來就內建 6～12 秒的隨機間隔，本工具沒有更動。
- 所以整批下載很慢是正常的：粗估每個檔案 2～3 秒、再加翻頁時間，**1000 個檔案約一小時上下**。

實作上，gallery-dl 內建的 `--sleep` 只支援固定值或均勻分佈，所以本工具改用 gallery-dl 的 python 後處理器，在每個檔案下載完成時執行常態分佈的等待。

### 可以中斷、再接續

命令列按 `Ctrl+C`、GUI 按「停止」都能中斷。重跑同一個網址時，已下載的檔案會略過（但貼文清單仍會重新翻過一遍）。

### 風險提醒

- 放慢節奏**不代表可以無限制下載**。
- IG 對自動化存取很敏感，一次抓很大的帳號仍可能觸發「請驗證身分」、暫時限制或 HTTP 429。
- 建議：只備份你自己的帳號內容、一次不要排太多、被限流就停手，等幾個小時再試。

---

## 命令列用法

所有指令都透過根目錄的 `mdl.bat`（它只是轉發給 `src\mdl.py`，需要 Python 3.8+）。

### 常用範例

下載影片，畫質上限 1080p：

```bat
mdl.bat video "https://www.youtube.com/watch?v=XXXXXXXXXXX" --quality 1080
```

只要聲音，轉成 320K 的 MP3：

```bat
mdl.bat audio "https://www.youtube.com/watch?v=XXXXXXXXXXX" --audio-quality 320K
```

批次下載 —— 先開一個 `urls.txt`，一行一個網址：

```bat
mdl.bat batch urls.txt --mode mp3
```

只看資訊不下載（標題、長度、上傳者），輸出成 JSON：

```bat
mdl.bat info "https://www.youtube.com/watch?v=XXXXXXXXXXX" --json
```

列出這支影片有哪些畫質可以選：

```bat
mdl.bat formats "https://www.youtube.com/watch?v=XXXXXXXXXXX"
```

環境自我檢查（yt-dlp / ffmpeg 在不在、版本多少、輸出資料夾能不能寫）：

```bat
mdl.bat doctor
```

更新 yt-dlp 到最新版（**下載失敗時第一個該跑的指令**）：

```bat
mdl.bat update
```

指定輸出資料夾：

```bat
mdl.bat video "https://..." --out "D:\我的影片"
```

IG / FB / X 的**貼文**直接用 `video` 就好 —— 影片照常下載（可選畫質），貼文裡的**照片也會自動一併下載**，純照片貼文也算成功（見下方〈影片模式會順便抓貼文照片〉）：

```bat
mdl.bat video "https://www.instagram.com/p/XXXXXXXXX/"
mdl.bat video "https://x.com/某帳號/status/1234567890"
mdl.bat video "https://www.instagram.com/p/XXXXXXXXX/" --no-photos   :: 只要影片，不要照片
```

用 gallery-dl 抓**整則貼文**（照片 + 輪播裡的影片都交給 gallery-dl；帳號頁、相簿也用這個）：

```bat
mdl.bat images "https://www.instagram.com/p/XXXXXXXXX/"
mdl.bat images "https://x.com/某帳號/status/1234567890"
```

需要登入的內容，用登入瀏覽器的 cookie（先雙擊 `登入瀏覽器.bat` 登入一次，見〈登入瀏覽器〉）：

```bat
mdl.bat video "https://www.instagram.com/stories/某帳號/" --login-browser
```

### 子指令

| 子指令 | 用途 | 範例 |
| --- | --- | --- |
| `info` | 只抓影片資訊，不下載 | `mdl.bat info "<url>" --json` |
| `video` | 下載影片（MP4）；IG / FB / X 貼文的照片也一併下載 | `mdl.bat video "<url>" --quality 1080` |
| `audio` | 下載音訊（MP3） | `mdl.bat audio "<url>" --audio-quality 320K` |
| `images` | 用 gallery-dl 下載整則貼文（照片 + 影片；IG / FB / X 等）；加 `--all` 可整批下載 IG 帳號／珍藏 | `mdl.bat images "<貼文網址>"` |
| `formats` | 列出可用的畫質／格式 | `mdl.bat formats "<url>"` |
| `batch` | 從文字檔批次下載 | `mdl.bat batch urls.txt --mode mp3` |
| `browser` | 登入瀏覽器：`status` / `open` / `tabs` / `close` | `mdl.bat browser open --url https://www.instagram.com/` |
| `update` | 更新 `bin\yt-dlp.exe` 與 `bin\gallery-dl.exe` | `mdl.bat update` |
| `doctor` | 環境自我檢查（含登入瀏覽器狀態） | `mdl.bat doctor` |
| `schema` | 印出 agent 工具的 JSON Schema | `mdl.bat schema` |
| `tool` | 用工具名 + JSON 參數呼叫 | `mdl.bat tool mdl_info "{\"url\":\"...\"}"` |

### 參數

| 參數 | 適用 | 說明 |
| --- | --- | --- |
| `--json` | 全部 | 輸出機器可讀的 JSON（給腳本／agent 用） |
| `--quality <值>` | `video`、`batch` | 畫質上限：`best` / `2160` / `1440` / `1080` / `720` / `480` / `360` |
| `--audio-quality <值>` | `audio`、`batch` | 音訊位元率：`0`（最佳）/ `320K` / `256K` / `192K` / `128K` |
| `--mode <mp4\|mp3>` | `batch` | 批次下載要影片還是只要聲音 |
| `--out <路徑>` | 下載類 | 輸出資料夾，預設 `downloads\` |
| `--login-browser` | `info` `video` `audio` `images` `formats` `batch` | 用登入瀏覽器的 cookie（**建議**；平常的 Chrome 不必關） |
| `--cookies-from-browser <瀏覽器>` | 同上 | 借用你自己瀏覽器的 cookie：`firefox` 等（Chrome / Edge 開著時通常讀不到） |
| `--cookies <cookies.txt>` | 同上 | Netscape 格式的 cookies.txt |
| `--no-photos` | `video`、`batch` | 只下載影片：IG / FB / X 貼文裡的照片不要一併下載（預設會一併下載） |
| `--all` | `images` | 整批下載 IG 帳號／珍藏（需要登入，搭配 `--login-browser`）；網址與存放位置見〈整批下載 IG 帳號／珍藏〉 |
| `--max-files <N>` | `images` | 最多下載幾個檔案（預設 100，防止誤貼帳號頁把整個帳號抓下來；加了 `--all` 時預設不設上限） |
| `--url <網址>` / `--probe` | `browser` | `open` 要開的網址／`status` 在視窗關著時也實際檢查登入狀態 |

> 三種 cookie 來源（`--login-browser`、`--cookies-from-browser`、`--cookies`）只能擇一。

> 各子指令實際支援的參數以 `mdl.bat <子指令> --help` 為準。

### 影片模式會順便抓貼文照片

不必自己判斷一則貼文「是影片還是照片」。`video`（以及 `batch --mode mp4`、agent 的 `mdl_download_video` / `mdl_batch_download`）遇到下列網址時，**影片照舊由 yt-dlp 下載**（畫質選擇、mp4 / h264 偏好都不變），接著自動用照片引擎把**貼文裡的照片**也抓到同一個資料夾：

| 網站 | 會加抓照片的網址 | 不會（純影片網址，行為與以前完全相同） |
| --- | --- | --- |
| Instagram | `/p/<代碼>/`；`/stories/…`（限時動態要登入，所以只有帶 cookie 時才加抓） | `/reel/`、`/reels/`、`/tv/` |
| X（Twitter） | `/<帳號>/status/<數字>` | 其他 |
| Facebook | 貼文／照片網址：`/posts/`、`/permalink`、`story.php`、`/photo`、`/photos/<ID>`、`/share/p/` | `/videos/`、`/watch`、`/reel/`、`fb.watch`、`/share/v/`、`/share/r/` |
| 其他網站（YouTube…） | —— | 全部：不會呼叫 gallery-dl，零改變 |

- **只抓照片，不會重抓影片**：影片在下載前就被濾掉（gallery-dl `--filter`；IG 未登入時走 yt-dlp 公開介面，同樣跳過影片那幾格），不浪費頻寬，也不會多出一份重複的影片。
- 照片檔名與 `images` 指令相同：`<帳號>_<貼文ID>_<序號>.<副檔名>`（IG 限時動態是 `<帳號>_story_<日期>_<該則的代碼>.<副檔名>`）；已下載過的不會重抓。影片的檔名維持 yt-dlp 的樣板。
- **結果以磁碟為準**：只要有任何檔案就是 `ok:true`。純照片貼文（yt-dlp 回報「沒有影片」）→ 成功、`error` / `hint` 都是 `null`；影片因為別的原因失敗但照片有抓到 → 成功，影片的錯誤降級成一條 `warnings`；影片成功而照片沒抓到 → 照樣成功，而且不出聲（細節記在結果的 `photo_pass`）。照片階段**絕不會**把成功的影片下載變成失敗。
- cookie 沿用同一份（`--cookies` / `--cookies-from-browser` / `--login-browser`；登入瀏覽器整次只匯出一次）。
- 多花的時間：IG `/p/` 多一次 yt-dlp 查詢（約 3～5 秒；已登入時改成一次 gallery-dl，約 2 秒）、X 多一次 gallery-dl（約 2 秒）、FB 多一次 gallery-dl（約 5 秒）、IG 限時動態約 10～15 秒（gallery-dl 對 IG 會刻意放慢請求），另加照片本身的下載時間。
- 不要照片：加 **`--no-photos`**（agent：`include_photos: false`），行為就和以前一模一樣。
- **什麼時候還是用 `images`**：想讓 gallery-dl 抓整則貼文（影片也交給它、不挑畫質）、要抓帳號頁／相簿／相片牆（搭配 `--max-files`）、要用 gallery-dl 的檔名樣板或 `--extra-arg`，或 `video` 的照片階段沒抓到時。

---

## 給 AI agent 用

引擎 `src\mdl.py` 一開始就是為了給 agent 呼叫而設計的：所有工具**回傳統一的 JSON 信封、不拋例外**，成功失敗都看 `ok` 欄位。

### 可用的工具（8 個）

| 工具名 | 說明 |
| --- | --- |
| `mdl_info` | 取得影片資訊（標題／長度／上傳者），不下載 |
| `mdl_download_video` | 下載影片（MP4）；IG / FB / X 貼文的照片也一併下載（`include_photos`，預設 `true`） |
| `mdl_download_audio` | 下載音訊（MP3） |
| `mdl_download_images` | 用 gallery-dl 下載 IG / FB / X 整則貼文（照片 + 輪播裡的影片）；帳號頁／相簿也用這個。整個帳號或珍藏加 `download_all: true`（要搭配 `use_login_browser: true`，見下方） |
| `mdl_list_formats` | 列出可用的畫質／格式 |
| `mdl_batch_download` | 批次下載多個網址（`mode=mp4` 時同樣支援 `include_photos`） |
| `mdl_doctor` | 環境自我檢查（含登入瀏覽器狀態） |
| `mdl_login_browser` | 登入瀏覽器：`action` = `status` / `open`（可帶 `url`）/ `tabs` / `close` |

除了 `mdl_doctor` 與 `mdl_login_browser`，每個下載／查詢工具都有 **`use_login_browser`**（boolean）：公開內容不用帶；內容需要登入，或上一次呼叫的 `hint` 說需要登入／cookie 時，帶 `true` 重試。它和 `cookies_from_browser`／`cookies_file` 互斥。

`mdl_download_video` 與 `mdl_batch_download` 另有 **`include_photos`**（boolean，預設 `true`）：網址是 IG / FB / X 的貼文時，影片下載完會自動把貼文裡的照片也抓下來，所以 agent 不必先判斷貼文類型，一律呼叫 `mdl_download_video` 即可——回傳的 `files` 可能同時有 `kind: "video"` 與 `kind: "image"`，純照片貼文也是 `ok:true`。只要影片時帶 `false`。適用的網址見〈影片模式會順便抓貼文照片〉。

`mdl_download_images` 的 **`download_all`**（boolean，不帶就是 `false`）：`true` 時整批下載 IG 帳號或珍藏（網址與子資料夾見〈整批下載 IG 帳號／珍藏〉）。**必須同時帶 `use_login_browser: true`**，沒有 cookie 會直接回報錯誤。不帶時行為和以前一樣。

`mdl_login_browser` 的典型用法：

- `{"action":"status"}` → `running`、`profile_exists`、`logged_in`（`{"instagram":…, "facebook":…, "x":…}`，視窗沒開時是 `null`，帶 `"probe": true` 可在關著時實際檢查）。
- `{"action":"open","url":"https://www.instagram.com/"}` → 開視窗（已開就開新分頁）讓**使用者本人**登入；agent 不能也不該替使用者輸入密碼。
- `{"action":"tabs"}` → 目前分頁清單與 `likely_current_url`（最近使用的分頁，通常就是使用者正在看的那頁），可以直接拿來下載：「幫我下載我現在在看的這則貼文」。

### 統一的 JSON 輸出信封

```json
{
  "ok": true,
  "action": "video",
  "url": "https://www.youtube.com/watch?v=XXXXXXXXXXX",
  "site": "youtube",
  "title": "範例影片標題",
  "duration": 213,
  "uploader": "某某頻道",
  "files": [
    {
      "path": "E:\\...\\downloads\\範例影片標題 [XXXXXXXXXXX].mp4",
      "name": "範例影片標題 [XXXXXXXXXXX].mp4",
      "size": 18273645,
      "ext": "mp4"
    }
  ],
  "output_dir": "E:\\...\\downloads",
  "elapsed_sec": 12.3,
  "attempts": 1,
  "warnings": [],
  "error": null,
  "hint": null
}
```

失敗時 `ok` 是 `false`，`error` 放錯誤訊息，`hint` 放「接下來可以怎麼做」的建議（例如「先跑 update」或「這個內容需要 cookie」）。

幾個判讀規則：

- **`ok` 以「磁碟上真的有檔案」為準。** 只要 `files` 非空就是 `ok:true`，即使 yt-dlp 回傳了非零 exit code（例如 IG 輪播貼文裡的照片沒有影片可抓）；反過來說，yt-dlp 說成功但檔案不存在（例如缺 ffmpeg 沒合併）仍然是 `ok:false`。影片模式下，照片階段抓到的照片也算數：純照片貼文是 `ok:true`。
- **部分失敗會降級成 `warnings` 裡的一條訊息**，`error` 維持 `null`。
- **`mdl_batch_download` 的頂層 `hint` 只講整體**（例如「1 筆失敗，詳見 results」）；每一筆自己的 `error` / `hint` 在 `results` 陣列裡。
- **判定失敗時會自動清掉該次下載留下的殘檔**（`.part` / `.ytdl` / `.fNNN.` 分軌暫存檔），不會在輸出資料夾留下一堆沒用的半成品。
- **`mdl_download_audio`（以及 `mode=mp3` 的批次）不會動到輸出資料夾裡既有的檔案**：下載與轉檔都在輸出資料夾底下這次才建立的暫存資料夾 `.mdltmp-xxxxxx` 裡進行，只有轉好的 mp3 會搬出來，暫存資料夾隨後刪除（成功或失敗都一樣）。`files` 每筆有 `existing`：`true` 代表這個 mp3 先前就已經下載過，這次沒有重新下載也沒有改寫它（同時會有一條 `warnings` 說明）；同名的影片（`<標題> [<ID>].mp4`）等其他檔案完全不受影響。詳見〈MP3 音樂與字幕：不會動到資料夾裡既有的檔案〉。
- **`cookie_source`** 說明本次用了哪種 cookie：`null`（沒有）、`{"type":"cookies_file"}`、`{"type":"browser","browser":"firefox"}`，或登入瀏覽器的 `{"type":"login_browser","mode":"live"|"headless","browser":"chrome","count":6,"total":16,"domains":["instagram.com"],"logged_in":{...}}`（`domains: null` 表示匯出全部網域）。不會包含 cookie 的值。
- `mdl_download_images` 的結果另有 `engine`（`gallery-dl` 或 IG 備援時的 `yt-dlp`）、`media_counts`，`files` 每筆有 `kind`（`image` / `video` / `other`）與 `existing`（先前已下載過）。另有 `download_all`（`true` / `false`）與 `pace`（整批下載時是 `{"mean":2.0,"min":0.0,"max":4.0}`，否則 `null`），見〈整批下載 IG 帳號／珍藏〉。
- **`mdl_download_video` 的結果**（音訊沒有下面這些欄位）：`files` 每筆都有 `kind`（影片是 `video`，照片階段抓到的是 `image`，照片另有 `existing`）；`media_counts` 是 `{"images":2,"videos":1,"other":0,"existing":0}` 這樣的統計；`photo_pass` 說明照片階段：`null` = 沒有這個階段（網址不適用，或 `include_photos:false`），否則是 `{"ran":true,"engine":"gallery-dl"|"yt-dlp","found":2,"error":null,"note":null,"elapsed_sec":3.9}`——`ran:false` 時 `note` 說明為什麼略過（例如 cookie 來源讀不到），`found:0` 時 `error` 是照片階段沒抓到的原因（影片成功時這不算失敗，也不會出現在 `warnings`）。`mdl_batch_download` 每筆結果各自有這些欄位，頂層 `media_counts` 是加總。

### 接法一：MCP server（推薦給 Claude Code / Claude Desktop）

`src\mcp_server.py` 是純標準函式庫寫的 MCP stdio server，不需要 `pip install` 任何東西。

**Claude Code：**

```bat
claude mcp add media-downloader --scope user -- python "<專案路徑>\src\mcp_server.py"
```

確認與移除：

```bat
claude mcp list
claude mcp get media-downloader
claude mcp remove media-downloader
```

**Claude Desktop：** 編輯 `%APPDATA%\Claude\claude_desktop_config.json`（注意 JSON 裡反斜線要寫兩個），存檔後**完全關閉再重開** Claude Desktop：

```json
{
  "mcpServers": {
    "media-downloader": {
      "command": "python",
      "args": ["<專案路徑>\\src\\mcp_server.py"]
    }
  }
}
```

掛好之後直接講人話就行：「幫我把這個網址存成 mp3：https://...」。

### 接法二：CLI + `--json`

任何語言都能用，開個 process 讀 stdout 就好：

```bat
mdl.bat info "https://..." --json
mdl.bat tool mdl_download_audio "{\"url\":\"https://...\",\"audio_quality\":\"320K\"}"
```

`tool` 子指令的形式是 `python src\mdl.py tool <工具名> <JSON字串>`，stdout 就是上面那個信封。

### 接法三：直接 import

```python
import sys
sys.path.insert(0, r"<專案路徑>\src")
import mdl

print(mdl.doctor())
info = mdl.get_info("https://...")
result = mdl.download("https://...", mode="mp3")
```

便利函式：`download(url, mode="mp4", **opts)`、`download_images(url, **opts)`、`get_info(url)`、`list_formats(url)`、`batch_download(urls, mode="mp4", **opts)`、`doctor()`、`login_browser(action="status", url=None, probe=False)`。下載／查詢函式都接受 `use_login_browser=True`。

要接 LLM function calling 的話，`mdl.TOOL_SCHEMAS` 已經是 Anthropic Messages API `tools=` 參數的格式（`name` / `description` / `input_schema`），可以原封不動丟進去，收到 `tool_use` 再用 `mdl.call_tool(name, input)` dispatch 回來。

完整可執行的範例在 **`src\example_agent_use.py`**：

```bat
python src\example_agent_use.py              :: 只跑唯讀示範（doctor / info）
python src\example_agent_use.py --download   :: 連下載示範一起跑
```

---

## 支援網站

底層是 yt-dlp，理論上它支援的 1800+ 個網站都能用。以下是**實測結果**（yt-dlp 2026.08.19）。

### 實測確認：免登入就能抓

| 網站 | 內容 |
| --- | --- |
| YouTube | 公開影片（**但一定要有 ffmpeg**，見下方） |
| Instagram | 公開的單篇貼文、Reel |
| Facebook | 公開粉專的影片 |
| X（Twitter） | 公開推文裡的原生影片 |
| archive.org | 公開項目 |

### 照片（`video` 的照片階段、`images` 指令／`mdl_download_images`）：實測免登入就能抓

yt-dlp 只抓影片，貼文裡的照片由 gallery-dl 負責（gallery-dl 1.32.14，2026-09-30 實測；`video` 會自動加跑這一段，見〈影片模式會順便抓貼文照片〉，2026-10-06 實測）：

| 網站 | 內容 | 備註 |
| --- | --- | --- |
| Instagram | 公開的單篇貼文（`/p/`、`/reel/`），含多張照片的輪播與混合輪播 | gallery-dl 的 IG 介面未登入會被導到登入頁，**本工具自動改用 yt-dlp 的公開介面**抓原圖（結果的 `engine` 會是 `yt-dlp`）；有登入 cookie 時照常走 gallery-dl |
| Facebook | 公開粉專的照片網址（`photo/?fbid=`、`photo.php?fbid=`）與多圖貼文 | `facebook.com/<粉專>/photos/<ID>/` 會自動改寫成單張照片網址（否則 gallery-dl 會抓整個粉專相片牆） |
| X（Twitter） | 公開推文裡的照片（多張）與影片 | |

檔名是 `<帳號>_<貼文ID>_<序號>.<副檔名>`；同一則貼文重抓時，已經下載過的檔案會沿用、不重複下載。帳號頁／標籤頁需要登入，而且最多只抓 `--max-files` 個檔案（要抓整個帳號請用 `--all`，見〈整批下載 IG 帳號／珍藏〉）。

IG **限時動態／精選動態**（`/stories/<帳號>/`、`/stories/highlights/<ID>/`，要登入）的檔名是 `<帳號>_story_<日期>_<該則的代碼>.<副檔名>`，例如 `natgeo_story_2026-10-05_DeHSGl8xx4D.jpg`（日期是該則發佈的 UTC 日期，代碼是 IG 給每一則的固定編號）。不沿用一般貼文的樣板是因為限時動態的「貼文 ID」其實是帳號的代碼（每個帳號固定，例如 natgeo 永遠是 `DAK8`）、序號又只是當下的排列位置：舊版因此把隔天的第一則限時動態當成「已存在」而略過（2026-10-06 修正，GUI 與命令列相同）。

### 實測確認：一定要登入（cookie）

| 網站／情況 | 實測到的錯誤 |
| --- | --- |
| **Vimeo（全部）** | `The web client only works when logged-in.` |
| Instagram 限時動態 | 需要登入才能存取 |
| Instagram 帳號頁列舉（`instagram.com/帳號/`） | `Unable to extract data`（訊息看起來像抽取器壞掉，但其實是不給未登入者列舉） |

> **Vimeo 很反直覺，值得單獨標註：** 即使那支影片在**沒登入的瀏覽器裡可以正常播放**，yt-dlp 2026.08.19 對 Vimeo 一律要求 cookies。所以碰到 Vimeo 請直接在登入瀏覽器登入 Vimeo、加 `--login-browser`，不用先懷疑網址或版本。

> **Instagram 帳號頁**（`instagram.com/nasa/`）跟**單篇貼文／Reel**（`instagram.com/p/XXXX/`、`instagram.com/reel/XXXX/`）是兩回事：前者要登入，後者公開內容不用。

### 其他一般需要 cookie 的情況

| 情況 | 例子 |
| --- | --- |
| 私人／非公開帳號 | 不公開的 IG 帳號、朋友限定的 FB 貼文 |
| 年齡限制 | YouTube 的年齡驗證影片 |
| 地區限制 | 需要特定地區帳號才看得到的內容 |
| 需要訂閱／付費 | 會員限定影片 |
| 平台要求登入才給看 | X 有時會對未登入者限流 |

### cookie 怎麼用

**首選：登入瀏覽器**（詳見上方〈登入瀏覽器〉）。雙擊 `登入瀏覽器.bat` 登入該網站一次，之後加 `--login-browser`：

```bat
mdl.bat video  "https://www.instagram.com/stories/某帳號/" --login-browser
mdl.bat images "https://x.com/someone/status/1234567890" --login-browser
mdl.bat audio  "https://www.youtube.com/watch?v=XXXXXXXXXXX" --login-browser
```

其他做法（三種來源只能擇一）：

```bat
mdl.bat video "https://..." --cookies-from-browser firefox
mdl.bat video "https://..." --cookies cookies.txt
```

注意事項：

- `--cookies-from-browser chrome` / `edge` 需要 **Chrome / Edge 完全關閉**才讀得到 cookie 資料庫（Windows 上瀏覽器開著會鎖住檔案），而且新版 Chrome 的加密常常讓 cookie 解不開——這正是登入瀏覽器存在的原因。Firefox 比較不受影響。
- `cookies.txt` 必須是 Netscape 格式（可用瀏覽器擴充套件匯出）。
- cookie 等同於你的登入狀態，**不要把 cookies.txt 或登入瀏覽器的設定檔分享出去**。
- 用得太兇有可能讓帳號被平台判定為異常（IG / FB 特別敏感），請避免大量下載，只在真的需要時才帶 cookie。

---

## 疑難排解

### 下載失敗 —— 先跑 `mdl.bat update`

**「前幾天還好好的，今天突然壞掉」這種情況，第一件事就是更新。** 各大平台常常改版，yt-dlp 跟著頻繁更新。

```bat
mdl.bat update
```

但要注意：**不是每個提到「請更新 yt-dlp」的訊息都真的需要更新**，見下面〈訊息叫我「更新 yt-dlp」，但 `update` 跑了沒用〉。

### HTTP 403 / 401

網址或簽章過期、或這個內容需要登入。先跑 `mdl.bat update`，還是不行就在登入瀏覽器登入該網站後加 `--login-browser`（見〈登入瀏覽器〉）。

### HTTP 429（太多請求）

被平台限流了。等 10 到 30 分鐘再試，不要短時間內狂抓。批次下載很多支時建議分批做。

### `Could not copy Chrome cookie database`（明明已經加了 cookie 參數）

**這不是「需要登入」，而是 cookie 根本沒讀到。** Windows 上瀏覽器只要還在跑就會鎖住 cookie 資料庫，yt-dlp 複製不了：

```
error: ERROR: Could not copy Chrome cookie database. See https://github.com/yt-dlp/yt-dlp/issues/7271 for more info
```

處理方式：

1. **改用登入瀏覽器（建議）**：雙擊 `登入瀏覽器.bat` 登入該網站一次，把 `--cookies-from-browser chrome` 換成 `--login-browser`。平常用的 Chrome 不必關，也不受新版加密影響。
2. 或者**完全關閉** Chrome／Edge，包含背景常駐行程（工作管理員裡不能剩下 `chrome.exe`），再重跑同一個指令（新版 Chrome 的 app-bound 加密仍可能讓 cookie 解不開）。
3. 或改用 `--cookies-from-browser firefox`，或用瀏覽器擴充套件把 cookie 匯出成 Netscape 格式的 `cookies.txt`，改用 `--cookies cookies.txt`。

同一類訊息還有 `could not find chrome cookies database`、`Failed to decrypt with DPAPI`、`failed to load cookies` 等，處理方式相同。這種錯誤發生在連網之前，所以 mdl.py 不會再用 `--impersonate` 重試一次（`attempts` 會是 1），直接回報原因。

如果是**已經帶了 cookie 卻仍被要求登入**，那才是 cookie 過期或該帳號看不到這個內容：請在同一個瀏覽器（同一個設定檔）實際打開那個網址確認看得到，必要時重新登入。用登入瀏覽器時最常見的原因是**登入瀏覽器根本還沒登入那個網站**——結果的 `warnings` 會寫「登入瀏覽器還沒登入 Instagram」，`cookie_source.logged_in` 也看得到。

### 登入瀏覽器相關的錯誤

| 訊息（`hint`） | 原因與處理 |
| --- | --- |
| 還沒有登入瀏覽器的設定檔 | 從來沒開過登入瀏覽器：雙擊 `登入瀏覽器.bat` 登入需要的網站一次。 |
| 設定檔正被一個「不是由本工具以 debug port 開啟」的視窗使用 | 有人用別的方式開了同一個設定檔：把那個登入瀏覽器視窗關掉（或 `mdl.bat browser close`），再用 `登入瀏覽器.bat` 重開。 |
| 連接埠 9227 被別的程式佔用 | 另一個程式佔了 debug port：`powershell -File tools\browser.ps1 -Action open -Port 9237` 換一個 port。 |
| 找不到已安裝的 Google Chrome 或 Microsoft Edge | 登入瀏覽器需要電腦上有 Chrome 或 Edge；沒有的話改用 `--cookies cookies.txt`。 |
| 匯出 0 顆 cookie／還沒登入某網站 | 不是錯誤：公開內容照樣下載，但要登入的內容會失敗。到登入瀏覽器登入該網站即可。 |

`mdl.bat doctor` 與 `mdl.bat browser status` 會顯示設定檔位置、瀏覽器版本、是否開著。

### 沒有 ffmpeg 就抓不到 YouTube（不是選配，是必要）

**實測（yt-dlp 2026.08.19）：YouTube 的「muxed（影音已合併）格式」數量是 0。** 也就是說，YouTube 一定得分別下載影像軌與聲音軌再用 ffmpeg 合併。

所以沒有 ffmpeg 的時候，**不是「畫質降到 720p」，而是 YouTube 一定失敗**。典型症狀是資料夾裡留下 `xxx.f395.mp4` 和 `xxx.f140.m4a` 兩個檔案，卻沒有最終的 mp4（本工具遇到這種情況會回報 `ok:false` 並自動清掉這兩個殘檔）。

修法就是把 ffmpeg 裝好：跑 `mdl.bat doctor` 看 `bin\ffmpeg.exe` 在不在，不在就重跑一次 **`首次設定.bat`**。如果公司網路擋下載，也可以自己去 [ffmpeg 官網](https://ffmpeg.org/download.html) 抓 Windows build，把 `ffmpeg.exe` 和 `ffprobe.exe` 手動放進 `bin\`。

MP3 轉檔、`--clip` 片段擷取、字幕內嵌同樣都需要 ffmpeg。

### 訊息叫我「更新 yt-dlp」，但 `update` 跑了沒用

有些錯誤訊息（例如 `Unable to extract data`、`No video formats found!`）長得像 yt-dlp 過舊，實際原因卻是別的：

- `instagram.com/帳號/` 這種帳號頁 → **需要登入**：在登入瀏覽器登入 IG，加 `--login-browser`。
- IG 輪播貼文裡的照片 → 那幾格本來就沒有影片，yt-dlp 會報錯但影片那格其實抓下來了。`video` 現在會自動把照片補抓回來（見〈影片模式會順便抓貼文照片〉）；加了 `--no-photos` 時才會只留影片，並在 `warnings` 說明略過了幾個項目。
- IG / X 純照片貼文（`There is no video in this post`、`No video could be found in this tweet`）、FB 照片網址／純照片貼文（`Unsupported URL`、`Cannot parse data`、HTTP 404）→ 不是壞掉，是沒有影片：`video` 會自動改抓照片並回報成功。如果仍然失敗，`hint` 會寫出照片也沒抓到的原因（多半是需要登入）。
- Vimeo → 一律需要 cookie（見〈支援網站〉）。

### 用「MP3 音樂」下載之後，同一個資料夾裡的影片不見了（已修正）

這是 2026-10-06 之前的版本的問題：先用影片模式下載一則 X／IG／FB 的影片，再用音樂模式下載同一個網址到同一個資料夾，那支 `.mp4` 會被刪掉，只剩 `.mp3`（GUI 還會顯示「已存在，略過」）。原因是這些網站的音訊來源檔副檔名也是 mp4，轉檔前的檔名 `<標題> [<ID>].mp4` 正好和既有的影片同名，yt-dlp 把它當成自己「已經下載好的中間檔」，轉出 mp3 之後就刪掉了。YouTube 的音訊是 m4a／webm，所以沒事。

現在音樂模式（GUI、`mdl.bat audio`、批次、agent）一律在專用的暫存資料夾裡下載與轉檔，只把轉好的 mp3 搬進輸出資料夾，既有的檔案一個都不會動（見〈MP3 音樂與字幕：不會動到資料夾裡既有的檔案〉）。已經被舊版刪掉的影片救不回來，重新用影片模式下載一次即可。

如果在輸出資料夾看到 `.mdltmp-` 開頭的隱藏資料夾：那是下載進行中的暫存；程式被強制結束（當機、工作管理員結束行程）時才會留下來，裡面只有沒做完的暫存檔，確定沒有下載在跑就可以直接刪除。

### IG 限時動態的照片被標成「已存在」而沒有下載（已修正）

2026-10-06 之前，限時動態的檔名是 `<帳號>_<帳號代碼>_<序號>`（例如 `natgeo_DAK8_1.jpg`），每天的第一則都叫同一個名字，於是新的限時動態被當成已經下載過。現在改成每一則各自固定的名字 `<帳號>_story_<日期>_<該則的代碼>.<副檔名>`。舊檔名的檔案不會被改名或刪除；還沒過期的限時動態下次會用新名字再下載一份。

### YouTube 開始少格式、或哪天突然抓不到（JavaScript runtime）

yt-dlp 2026.08 版起，在**沒有 JavaScript runtime** 的環境下抽取 YouTube 已被標記為 deprecated，會出現這則警告：

```
WARNING: [youtube] No supported JavaScript runtime could be found.
YouTube extraction without a JS runtime has been deprecated, and some formats may be missing.
```

實測狀況（2026-09-17）：**目前不影響使用**。在沒有 JS runtime 的情況下仍抓得到 4K、1080p h264、以及 53～69 種格式，本專案所有測試都正常通過。本工具預設帶了 `--no-warnings`，所以你平常看不到這則訊息。

但這是 YouTube 未來最可能先壞掉的地方。如果哪天發現**畫質選項變少**、或 YouTube 突然抓不到而 `mdl.bat update` 也救不回來，裝一個 JS runtime 通常就能解決：

1. 到 [deno.land](https://deno.land/) 下載 `deno.exe`（免安裝的單一執行檔），放進本專案的 `bin\` 資料夾。
2. 用 `--extra-arg` 指定它：

```bat
mdl.bat video "https://..." "--extra-arg=--js-runtimes" "--extra-arg=deno"
```

> 注意 `--extra-arg` 後面接的值如果本身以 `--` 開頭（像這裡的 `--js-runtimes`），**一定要用 `--extra-arg=值` 這種等號形式**。寫成 `--extra-arg "--js-runtimes"` 會被當成另一個選項而報錯。

詳情見 yt-dlp 的 [EJS 說明](https://github.com/yt-dlp/yt-dlp/wiki/EJS)。

### PowerShell 執行原則擋住 `.ps1`

症狀：雙擊 bat 之後出現「因為這個系統上已停用指令碼執行」之類的訊息。

專案裡的 `.bat` 已經用 `-ExecutionPolicy Bypass` 呼叫 PowerShell，正常情況不會遇到。如果公司有群組原則強制鎖住，請找 IT 處理 —— **不要為了跑這個工具去改全機器的執行原則**。

另一種可能是檔案被 Windows 標記為「從網路下載」。在 `.ps1` 或 `.zip` 上按右鍵 → 內容 → 勾選「解除封鎖」→ 確定。

### 防毒軟體把 `yt-dlp.exe` 當病毒刪掉

這是很常見的**誤判**（false positive）—— yt-dlp 是用 PyInstaller 打包的 Python 程式，這種打包方式常被啟發式掃描誤認。yt-dlp 專案本身有[說明這件事](https://github.com/yt-dlp/yt-dlp/wiki/FAQ)。

處理方式：把專案的 `bin\` 資料夾加進防毒軟體的排除清單，然後重跑 `首次設定.bat`。**只在你確認 exe 是從 yt-dlp 官方 GitHub 下載的情況下這麼做。**

### 檔名太長或有奇怪符號（Windows 260 字元上限）

Windows 預設的路徑上限是 **260 個字元**，而且 yt-dlp **下載途中**的暫存檔還會再加上很長的後綴（例如 `.fhls-audio-128000-Audio.mp4.part-Frag12.part`，約 45 字元）—— 所以常見的狀況是「最終檔名明明沒超過，下載到一半卻炸掉」。

引擎現在會依輸出資料夾的長度自動算預算，加上 `--trim-filenames` 並壓縮標題長度，一般深度的資料夾不會再遇到這個問題。

真的還是失敗時，訊息會長這樣：

```
"error": "ERROR: The downloaded file is empty"
"hint":  "輸出路徑可能過長（Windows 上限 260 字元…）或磁碟空間不足：請改用較短的輸出資料夾路徑"
```

此時把輸出資料夾換成短一點的路徑（例如 `D:\dl`）就好。

### 中文變亂碼

`mdl.bat` 走的是 Python + UTF-8，正常不會有事。如果是在舊版 `cmd.exe` 裡看到亂碼，先跑 `chcp 65001` 切成 UTF-8，或改用 Windows Terminal。

---

## 技術來源與致謝

本工具是下列開源專案的外殼與整合；這些外部程式都以**獨立執行檔**呼叫，**不隨本 repo 散布**，由「首次設定.bat」在執行時從官方來源下載到 `bin\`。

| 用途 | 專案 | 授權 |
|---|---|---|
| 影片／音訊下載 | [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Unlicense |
| IG／FB／X 貼文照片 | [gallery-dl](https://codeberg.org/mikf/gallery-dl) | GPL-2.0 |
| 合併影音、轉檔 | [FFmpeg](https://ffmpeg.org/)（下載自 [gyan.dev 建置的 GitHub 發行](https://github.com/GyanD/codexffmpeg)，失敗時改用 [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds)） | 依建置版本為 LGPL／GPL，見原專案 |
| 登入瀏覽器取 cookie | 你電腦上已安裝的 Chrome／Edge（經 Chrome DevTools Protocol） | 見原專案 |
| MCP 介接 | [Model Context Protocol](https://modelcontextprotocol.io/)（本工具以標準函式庫自行實作 stdio server，不依賴額外套件） | 見原專案 |

本 repo 只含自己的程式碼（PowerShell WinForms GUI、以 Python 標準函式庫寫的引擎與 MCP server）。

開發過程使用 [Claude Code](https://claude.com/claude-code)（Anthropic）協助。

## 作者

- 網站：https://shaoenstudio.com
- 聯絡信箱：shaoenstudio@gmail.com
- GitHub：[@shaoen901109](https://github.com/shaoen901109)

## 授權

MIT，見 [LICENSE](LICENSE)。
