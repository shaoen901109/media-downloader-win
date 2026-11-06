#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""media-downloader MCP server —— 把「免安裝影音下載器」掛給 AI agent 用。

這支程式是一個 **MCP stdio server**，只用 Python 標準函式庫實作
(JSON-RPC 2.0 over stdin/stdout，一行一則 JSON，沒有 Content-Length 標頭)。
它不自己做下載，所有事情都轉給同目錄的 ``mdl.py``：

    tools/list  ->  mdl.TOOL_SCHEMAS
    tools/call  ->  mdl.call_tool(name, arguments)

提供的工具
----------
    mdl_info             取得影片資訊（標題／長度／上傳者，不下載）
    mdl_download_video   下載影片（MP4）；IG / FB / X 貼文的照片也一併下載（include_photos，預設 true）
    mdl_download_audio   下載音訊（MP3）
    mdl_list_formats     列出可用的畫質／格式
    mdl_batch_download   批次下載多個網址（mode=mp4 時同樣支援 include_photos）
    mdl_download_images  用 gallery-dl 下載 IG / FB / X 整則貼文（照片 + 影片）
    mdl_doctor           環境自我檢查（yt-dlp / gallery-dl / ffmpeg / 登入瀏覽器）
    mdl_login_browser    登入瀏覽器 status / open / tabs / close

    下載類工具都接受 use_login_browser=true：改用「登入瀏覽器」（tools\browser.ps1）的 cookie。

需求
----
* Python 3.8+（標準函式庫即可，不需要 pip install 任何東西）
* 同目錄的 ``mdl.py``
* ``bin\yt-dlp.exe`` 與 ``bin\ffmpeg.exe`` —— 請先雙擊專案根目錄的「首次設定.bat」下載

=============================================================================
掛載到 Claude Code
=============================================================================
在專案任意目錄下執行（``--scope user`` 表示所有專案都能用；想只給單一專案用
就改成 ``--scope project``）：

    claude mcp add media-downloader --scope user -- python "<path-to-project>\src\mcp_server.py"

確認掛載結果：

    claude mcp list
    claude mcp get media-downloader

移除：

    claude mcp remove media-downloader

掛好之後在 Claude Code 裡直接講人話即可，例如
「用 media-downloader 幫我把這個網址存成 mp3：https://...」。

=============================================================================
掛載到 Claude Desktop
=============================================================================
編輯設定檔（Windows）：

    %APPDATA%\Claude\claude_desktop_config.json

貼上以下內容（若檔案已有 "mcpServers"，把 "media-downloader" 這一段併進去就好）：

    {
      "mcpServers": {
        "media-downloader": {
          "command": "python",
          "args": ["<path-to-project>\\src\\mcp_server.py"]
        }
      }
    }

注意：JSON 裡的反斜線要寫成兩個 (``\\``)。存檔後**完全關閉並重開** Claude
Desktop 才會生效。如果 ``python`` 不在 PATH 上，把 "command" 換成完整路徑，
例如 ``"C:\\Python312\\python.exe"``。

=============================================================================
手動測試
=============================================================================
不需要任何 MCP client，直接餵 JSON 進 stdin 就能測：

    python src\mcp_server.py
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}
    {"jsonrpc":"2.0","id":2,"method":"tools/list"}
    {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mdl_doctor","arguments":{}}}

（每行貼一則，Enter 送出；Ctrl+Z 再 Enter 結束。）

設計上的注意事項
----------------
* **stdout 只會有 JSON-RPC 訊息**，任何除錯／錯誤訊息一律走 stderr，
  否則會把 MCP client 的解析器弄壞。
* 沒有 ``id`` 的訊息是通知 (notification)，依規範**不回應**。
* 內部例外一律轉成 JSON-RPC error 回應，server 本身不會整個掛掉。
"""

from __future__ import annotations

import io
import json
import os
import sys
import traceback

SERVER_NAME = "media-downloader"
SERVER_VERSION = "1.0.0"

#: 預設回報的 MCP 協定版本。client 送來的版本若在此清單內就原樣回傳，
#: 不認得的版本則退回這個預設值。
DEFAULT_PROTOCOL_VERSION = "2024-11-05"
SUPPORTED_PROTOCOL_VERSIONS = ("2024-11-05", "2025-03-26", "2025-06-18")

# JSON-RPC 2.0 標準錯誤碼
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)


# --------------------------------------------------------------------------
# 基礎工具
# --------------------------------------------------------------------------
def log(message: str) -> None:
    """除錯訊息一律寫 stderr —— stdout 是 JSON-RPC 專用通道。"""
    try:
        sys.stderr.write("[%s] %s\n" % (SERVER_NAME, message))
        sys.stderr.flush()
    except Exception:
        pass


def _setup_stdio():
    """把 stdin/stdout 轉成 UTF-8、行緩衝的文字串流。

    Windows 主控台預設是 cp950，不處理的話中文標題會直接炸掉。
    """
    stdin = sys.stdin
    stdout = sys.stdout
    # 用 utf-8-sig 讀 stdin：正規的 MCP client 不會送 BOM，但從 PowerShell 管線
    # 餵測試資料時開頭會多一個 UTF-8 BOM，害第一則訊息解析失敗。utf-8-sig 會在
    # 串流開頭有 BOM 時吃掉它，沒有 BOM 時行為與 utf-8 完全相同。
    try:
        stdin = io.TextIOWrapper(
            sys.stdin.buffer, encoding="utf-8-sig", errors="replace", newline=""
        )
    except Exception:
        try:
            sys.stdin.reconfigure(encoding="utf-8-sig", errors="replace")
        except Exception:
            pass
    try:
        stdout = io.TextIOWrapper(
            sys.stdout.buffer, encoding="utf-8", errors="replace", newline="\n"
        )
    except Exception:
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    try:
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    return stdin, stdout


# --------------------------------------------------------------------------
# 延遲載入 mdl.py
# --------------------------------------------------------------------------
_mdl_module = None
_mdl_error = None


def get_mdl():
    """載入並回傳 ``mdl`` 模組；失敗時回傳 ``None`` 並記下原因。

    刻意延遲到真的要用時才 import：即使 ``mdl.py`` 還沒寫好或壞掉，
    ``initialize`` / ``ping`` 仍然要能正常回應，client 才看得到清楚的錯誤，
    而不是一個「server 啟動失敗」的黑盒子。
    """
    global _mdl_module, _mdl_error
    if _mdl_module is not None:
        return _mdl_module
    try:
        import mdl  # noqa: F401  （與本檔同目錄）

        _mdl_module = mdl
        _mdl_error = None
        return _mdl_module
    except Exception as exc:  # ImportError、SyntaxError、模組層級例外……
        _mdl_error = "%s: %s" % (type(exc).__name__, exc)
        log("無法載入 mdl.py -> %s" % _mdl_error)
        log(traceback.format_exc())
        return None


def mdl_unavailable_message() -> str:
    return (
        "無法載入核心引擎 mdl.py（預期路徑：%s）。原因：%s\n"
        "請確認：(1) 檔案存在且語法正確；(2) Python 版本為 3.8 以上。"
        % (os.path.join(_HERE, "mdl.py"), _mdl_error or "未知")
    )


# --------------------------------------------------------------------------
# JSON-RPC 訊息組裝
# --------------------------------------------------------------------------
def make_result(msg_id, result):
    return {"jsonrpc": "2.0", "id": msg_id, "result": result}


def make_error(msg_id, code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": msg_id, "error": err}


# --------------------------------------------------------------------------
# 各方法的處理
# --------------------------------------------------------------------------
def handle_initialize(params):
    requested = None
    if isinstance(params, dict):
        requested = params.get("protocolVersion")
    if not isinstance(requested, str) or requested not in SUPPORTED_PROTOCOL_VERSIONS:
        requested = DEFAULT_PROTOCOL_VERSION
    return {
        "protocolVersion": requested,
        "capabilities": {"tools": {}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
    }


def handle_tools_list(_params):
    """把 ``mdl.TOOL_SCHEMAS`` 轉成 MCP 的格式。

    mdl 用的是 snake_case 的 ``input_schema``（與 Anthropic API 一致），
    MCP 規範用的則是駝峰式的 ``inputSchema``，這裡負責翻譯。
    """
    mdl = get_mdl()
    if mdl is None:
        raise RuntimeError(mdl_unavailable_message())

    schemas = getattr(mdl, "TOOL_SCHEMAS", None)
    if not isinstance(schemas, (list, tuple)):
        raise RuntimeError("mdl.TOOL_SCHEMAS 不存在或型別錯誤（應為 list）。")

    tools = []
    for schema in schemas:
        if not isinstance(schema, dict):
            continue
        name = schema.get("name")
        if not name:
            continue
        # 同時容忍 input_schema / inputSchema 兩種寫法
        input_schema = schema.get("input_schema")
        if input_schema is None:
            input_schema = schema.get("inputSchema")
        if not isinstance(input_schema, dict):
            input_schema = {"type": "object", "properties": {}}
        tools.append(
            {
                "name": name,
                "description": schema.get("description", "") or "",
                "inputSchema": input_schema,
            }
        )
    return {"tools": tools}


def _text_result(payload, is_error):
    return {
        "content": [
            {
                "type": "text",
                "text": json.dumps(payload, ensure_ascii=False, indent=2, default=str),
            }
        ],
        "isError": bool(is_error),
    }


def handle_tools_call(params):
    if not isinstance(params, dict):
        raise ValueError("tools/call 的 params 必須是物件。")

    name = params.get("name")
    if not isinstance(name, str) or not name:
        raise ValueError("tools/call 缺少 'name'。")

    arguments = params.get("arguments")
    if arguments is None:
        arguments = {}
    if not isinstance(arguments, dict):
        raise ValueError("tools/call 的 'arguments' 必須是物件。")

    mdl = get_mdl()
    if mdl is None:
        return _text_result(
            {"ok": False, "error": mdl_unavailable_message(), "hint": "請先跑「首次設定.bat」並確認 src\\mdl.py 存在。"},
            True,
        )

    call_tool = getattr(mdl, "call_tool", None)
    if not callable(call_tool):
        return _text_result(
            {"ok": False, "error": "mdl.call_tool 不存在或不可呼叫。", "hint": None},
            True,
        )

    try:
        result = call_tool(name, arguments)
    except Exception as exc:
        # 契約上 call_tool 不該拋例外，但真的拋了也要變成工具錯誤而非讓 server 死掉。
        log("call_tool(%r) 拋出例外：%s" % (name, exc))
        log(traceback.format_exc())
        return _text_result(
            {
                "ok": False,
                "error": "%s: %s" % (type(exc).__name__, exc),
                "hint": "這是 mdl.call_tool 內部的未預期例外，詳細 traceback 在 stderr。",
            },
            True,
        )

    if not isinstance(result, dict):
        result = {"ok": False, "error": "mdl.call_tool 回傳了非 dict 的值。", "data": result}

    return _text_result(result, not result.get("ok", False))


def handle_ping(_params):
    return {}


#: method -> handler
HANDLERS = {
    "initialize": handle_initialize,
    "tools/list": handle_tools_list,
    "tools/call": handle_tools_call,
    "ping": handle_ping,
}

#: 收到但不需要回應、也不需要做事的通知
KNOWN_NOTIFICATIONS = {
    "notifications/initialized",
    "initialized",
    "notifications/cancelled",
    "notifications/progress",
}


def dispatch(message):
    """處理一則已解析的 JSON-RPC 訊息，回傳要送出的回應 dict；通知回傳 None。"""
    if not isinstance(message, dict):
        return make_error(None, INVALID_REQUEST, "JSON-RPC 訊息必須是物件。")

    method = message.get("method")
    has_id = "id" in message and message.get("id") is not None
    msg_id = message.get("id")
    params = message.get("params")

    if not isinstance(method, str):
        # 沒有 method 的多半是回應 (result/error)，client 不該送給我們，安靜忽略。
        if "result" in message or "error" in message:
            return None
        if not has_id:
            return None
        return make_error(msg_id, INVALID_REQUEST, "缺少 'method'。")

    if not has_id:
        # 通知：不論認不認得都絕對不能回應。
        if method not in KNOWN_NOTIFICATIONS:
            log("忽略未知通知：%s" % method)
        return None

    handler = HANDLERS.get(method)
    if handler is None:
        return make_error(msg_id, METHOD_NOT_FOUND, "Method not found: %s" % method)

    try:
        return make_result(msg_id, handler(params))
    except ValueError as exc:
        return make_error(msg_id, INVALID_PARAMS, str(exc))
    except Exception as exc:
        log("處理 %s 時發生例外：%s" % (method, exc))
        log(traceback.format_exc())
        return make_error(
            msg_id, INTERNAL_ERROR, "%s: %s" % (type(exc).__name__, exc)
        )


def dispatch_raw(line):
    """解析一行文字並處理；回傳要送出的訊息（dict 或 list），沒有則回 None。"""
    try:
        message = json.loads(line)
    except Exception as exc:
        log("JSON 解析失敗：%s" % exc)
        return make_error(None, PARSE_ERROR, "Parse error: %s" % exc)

    # JSON-RPC 批次（MCP stdio 少見，但規範允許）
    if isinstance(message, list):
        if not message:
            return make_error(None, INVALID_REQUEST, "空的批次請求。")
        responses = [r for r in (dispatch(m) for m in message) if r is not None]
        return responses or None

    return dispatch(message)


# --------------------------------------------------------------------------
# 主迴圈
# --------------------------------------------------------------------------
def serve(stdin, stdout):
    log("已啟動（pid=%d）。等待 JSON-RPC 訊息……" % os.getpid())
    while True:
        try:
            line = stdin.readline()
        except KeyboardInterrupt:
            break
        except Exception as exc:
            log("讀取 stdin 失敗：%s" % exc)
            break

        if line == "":  # EOF：client 關掉了管線
            log("stdin 已關閉，結束。")
            break

        line = line.strip()
        if not line:
            continue

        try:
            response = dispatch_raw(line)
        except Exception as exc:
            # 最後一道防線：dispatch 本身不該爆，爆了也不能讓 server 死掉。
            log("dispatch 發生未預期例外：%s" % exc)
            log(traceback.format_exc())
            response = make_error(None, INTERNAL_ERROR, "%s: %s" % (type(exc).__name__, exc))

        if response is None:
            continue

        try:
            stdout.write(json.dumps(response, ensure_ascii=False, default=str) + "\n")
            stdout.flush()
        except Exception as exc:
            log("寫入 stdout 失敗：%s" % exc)
            break


def main():
    stdin, stdout = _setup_stdio()
    try:
        serve(stdin, stdout)
    except KeyboardInterrupt:
        log("收到 Ctrl+C，結束。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
