# Media Downloader (portable, Windows)

**English** | [繁體中文](README.zh-TW.md)

> ## ⚠️ Disclaimer (read this first)
>
> - This tool is **only for downloading content that you own or are explicitly authorized to download** (for example backing up your own uploads, watching licensed material offline, or uses permitted by fair-use / copyright law in your jurisdiction).
> - The **terms of service of most platforms (YouTube, Instagram, Facebook, X, etc.) prohibit unauthorized downloading.** Whether and how you use this tool is entirely your own responsibility.
> - **Copyright belongs to the rights holders.** Downloading does not grant you any license. Do not redistribute other people's copyrighted content or use it commercially.
> - The **login browser / cookie import feature must only be used with your own accounts.** Cookies are equivalent to login credentials: **never share, upload, or commit them anywhere public.**
> - You bear **all legal responsibility** for how you use this tool. The author and contributors accept no liability for your actions or their consequences. If you are unsure whether a use is lawful, do not download.

> 📖 **Step-by-step tutorial (Traditional Chinese):** https://shao-en.com/blog/media-downloader-win-guide.html — not sure how to set it up? Hand the article to Claude or ChatGPT and let it walk you through.

A folder-based, no-install video/audio/photo downloader for Windows. It wraps [yt-dlp](https://github.com/yt-dlp/yt-dlp) (video/audio), [gallery-dl](https://codeberg.org/mikf/gallery-dl) (photos from IG / FB / X posts) and [FFmpeg](https://ffmpeg.org/). The executables are downloaded into the project's `bin\` folder: **no registry writes, no system install, no administrator rights.** Copy the folder to another PC or a USB stick and it keeps working; delete the folder to uninstall (the login-browser profile lives separately in `%LOCALAPPDATA%\影音下載器\`).

Three ways to use it: **GUI** (double-click), **command line**, and **AI agent / MCP**.

## Requirements

- Windows 10 / 11 with PowerShell 5.1 (built in). The GUI is PowerShell WinForms and needs no Python.
- Python 3.8+ (standard library only, no `pip install`) for the CLI (`mdl.bat` / `src\mdl.py`) and the MCP server.
- Internet access for the first-time setup.
- Optional: Chrome or Edge for the login browser.

## Install / first run

1. Unzip or clone the project anywhere you can write to.
2. Double-click **`首次設定.bat`** (first-time setup). It downloads `yt-dlp.exe`, `gallery-dl.exe`, `ffmpeg.exe` and `ffprobe.exe` into `bin\`:
   - yt-dlp from its GitHub releases;
   - gallery-dl from its Codeberg releases (falls back to GitHub);
   - FFmpeg from the gyan.dev builds published on GitHub (`GyanD/codexffmpeg`), falling back to `BtbN/FFmpeg-Builds`.

   This takes a minute or two and is only needed once. FFmpeg is **required**: YouTube no longer serves pre-merged formats, so nothing can be downloaded from it without FFmpeg. Update later with `mdl.bat update`.
3. Double-click **`影音下載器.bat`** to open the GUI, paste URLs, pick a mode and download.

The binaries are not shipped in this repo; they are fetched at run time from the upstream projects.

## GUI

Paste one or more URLs (one per line), choose a mode (MP4 video, MP3 audio, or images from IG / FB / X posts), choose quality, pick an output folder, and click download. Playlists work too. The GUI shares its yt-dlp options with the engine through `config\profiles.json`.

## Command line

```bat
mdl.bat video  "https://..."                  :: best-quality MP4
mdl.bat video  "https://..." --quality 1080   :: capped at 1080p
mdl.bat audio  "https://..." --audio-quality 320K
mdl.bat images "https://www.instagram.com/p/XXXXXXXXX/"
mdl.bat batch  urls.txt
mdl.bat info   "https://..." --json
mdl.bat update                                :: update yt-dlp and gallery-dl
```

Run `mdl.bat --help` for all sub-commands and options. Add `--json` to get a machine-readable result envelope. Bulk download of a whole Instagram account or your own saved posts is supported (`images --all`, requires the login browser), with a randomized wait between files; use it sparingly (see the risk notes in the Traditional Chinese README).

## MCP server / AI agents

`src\mcp_server.py` is a stdio MCP server written with the Python standard library only.

Claude Code:

```bat
claude mcp add media-downloader --scope user -- python "<path-to-project>\src\mcp_server.py"
```

Claude Desktop (`%APPDATA%\Claude\claude_desktop_config.json`, then fully restart the app):

```json
{
  "mcpServers": {
    "media-downloader": {
      "command": "python",
      "args": ["<path-to-project>\\src\\mcp_server.py"]
    }
  }
}
```

Other options: call `mdl.bat tool <name> <json>` and read the JSON envelope from stdout, or `import mdl` directly (`mdl.TOOL_SCHEMAS` is in the Anthropic Messages API `tools=` format; see `src\example_agent_use.py`).

## Cookies and the login browser

Some content (private accounts, stories, members-only or age-restricted videos) needs login cookies. The **login browser** (`登入瀏覽器.bat`, or `mdl.bat browser open --url https://www.instagram.com/`) opens a dedicated Chrome/Edge window with its own profile; you log in once, and later downloads with `--login-browser` (agent: `use_login_browser: true`) export the cookies from it through the Chrome DevTools Protocol. Your everyday browser is never touched.

Security notes:

- **Use this only with your own accounts.** Cookies are equivalent to a logged-in session: never share, upload, or commit them.
- The profile is stored in `%LOCALAPPDATA%\影音下載器\browser` (outside the project, on purpose, so cloud-sync folders do not copy your sessions). Delete that folder to remove all sessions.
- Exported cookie files are temporary and deleted right after each download; result JSON never contains cookie values.
- The debug port listens on `127.0.0.1` only while the window is open; close it when not in use.
- Avoid heavy downloading: IG / FB detect automation and may restrict accounts. If you get rate-limited, stop and follow the platform's rules.

## Configuration (`config\profiles.json`)

Shared by the GUI and the engine; edit once and both change. Main keys:

- `common`: yt-dlp options applied to every download (retries, concurrent fragments, timeouts, `--windows-filenames`, ...).
- `video` / `audio`: format selection, sort order, merge format (MP4), MP3 conversion and metadata embedding.
- `output_template` / `output_template_playlist`: output file naming.
- `quality_choices` / `audio_quality_choices`: the choices shown in the GUI and accepted by the CLI.
- `bulk_sleep`: `mean` / `min` / `max` seconds of random wait after each file in bulk downloads (set `max` to 0 to disable).

## Troubleshooting

Most failures are fixed by `mdl.bat update`. If PowerShell blocks the scripts, the `.bat` launchers already use `-ExecutionPolicy Bypass`. Antivirus software sometimes flags `yt-dlp.exe`; add `bin\` to its exclusions. More details (HTTP 403 / 429, cookie database errors, JavaScript runtime, long file names) are in the Traditional Chinese README.

## Credits

This project is a wrapper around these open-source programs. They are invoked as **separate executables** and are **not distributed with this repo**; setup downloads them from their official sources at run time.

| Purpose | Project | License |
|---|---|---|
| Video / audio download | [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Unlicense |
| Photos from IG / FB / X posts | [gallery-dl](https://codeberg.org/mikf/gallery-dl) | GPL-2.0 |
| Merging and conversion | [FFmpeg](https://ffmpeg.org/) (gyan.dev builds via [GyanD/codexffmpeg](https://github.com/GyanD/codexffmpeg), fallback [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds)) | LGPL / GPL depending on the build; see upstream |
| Cookie export | Chrome / Edge already installed on your PC (via Chrome DevTools Protocol) | see upstream |
| MCP integration | [Model Context Protocol](https://modelcontextprotocol.io/) (the stdio server is implemented with the standard library; no extra package) | see upstream |

This repo contains only its own code (PowerShell WinForms GUI, and the engine and MCP server written with the Python standard library).

Developed with the help of [Claude Code](https://claude.com/claude-code) (Anthropic).

## Author

- Website: https://shaoenstudio.com
- Email: shaoenstudio@gmail.com
- GitHub: [@shaoen901109](https://github.com/shaoen901109)

## License

MIT, see [LICENSE](LICENSE).
