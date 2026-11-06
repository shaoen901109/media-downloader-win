#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""三種把「免安裝影音下載器」接給 agent 用的方式，可直接執行。

    python src\example_agent_use.py              # 只跑唯讀示範（doctor / info），不下載
    python src\example_agent_use.py --download   # 額外跑真正會下載檔案的示範
    python src\example_agent_use.py --url "<自訂網址>"

三種接法
--------
1. **直接 import**（同一個 Python 行程，最快、可拿到原生 dict）
2. **子行程 + JSON**（語言不限，只要能跑 process 和讀 JSON 就行）
3. **LLM function calling**（把 ``mdl.TOOL_SCHEMAS`` 當成 tools 參數餵給模型）

第 3 段只印出「該長什麼樣」，不會真的呼叫任何 API，也不需要安裝 anthropic 套件。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MDL_PATH = os.path.join(HERE, "mdl.py")
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# 唯讀示範用的網址（YouTube 官方頻道的公開影片，短、穩定）
DEFAULT_URL = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"

SEP = "=" * 72


def header(title: str) -> None:
    print("\n" + SEP)
    print(title)
    print(SEP)


def dump(label: str, payload) -> None:
    print("--- %s ---" % label)
    print(json.dumps(payload, ensure_ascii=False, indent=2, default=str))


def import_mdl():
    """import mdl，失敗時給清楚的錯誤而不是一堆 traceback。"""
    try:
        import mdl

        return mdl
    except Exception as exc:
        print("[錯誤] 無法載入核心引擎 mdl.py")
        print("       預期路徑：%s" % MDL_PATH)
        print("       原因：%s: %s" % (type(exc).__name__, exc))
        print("       請確認檔案存在、語法正確，且 Python 版本為 3.8 以上。")
        return None


# ==========================================================================
# 接法 1：直接 import
# ==========================================================================
def demo_import(url: str, do_download: bool) -> None:
    header("接法 1：直接 import mdl（同行程呼叫，回傳原生 dict）")

    mdl = import_mdl()
    if mdl is None:
        return

    print("# 環境自我檢查")
    print(">>> import mdl; mdl.doctor()")
    dump("mdl.doctor()", mdl.doctor())

    print("\n# 取得影片資訊（不下載）")
    print('>>> mdl.get_info(%r)' % url)
    info = mdl.get_info(url)
    dump("mdl.get_info(url)", info)

    if info.get("ok"):
        print("標題：%s" % info.get("title"))
        print("長度：%s 秒" % info.get("duration"))
        print("上傳者：%s" % info.get("uploader"))
    else:
        print("取得資訊失敗：%s" % info.get("error"))
        if info.get("hint"):
            print("提示：%s" % info["hint"])

    if not do_download:
        print("\n（跳過下載示範；加上 --download 才會真的抓檔案。）")
        return

    print("\n# 下載成 MP3")
    print('>>> mdl.download(%r, mode="mp3")' % url)
    result = mdl.download(url, mode="mp3")
    dump('mdl.download(url, mode="mp3")', result)
    for f in result.get("files") or []:
        print("產出檔案：%s（%s bytes）" % (f.get("path"), f.get("size")))


# ==========================================================================
# 接法 2：子行程 + JSON
# ==========================================================================
def run_mdl_tool(tool_name: str, args: dict) -> dict:
    """跑 ``python mdl.py tool <工具名> <json>``，解析 stdout 的 JSON。

    這是給非 Python 的 agent 用的通用作法：只要能開 process、讀 stdout
    就能接，不必在意 Python 的匯入路徑。
    """
    cmd = [sys.executable, MDL_PATH, "tool", tool_name, json.dumps(args, ensure_ascii=False)]
    print(">>> %s" % " ".join(cmd))

    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    if proc.stderr and proc.stderr.strip():
        print("[stderr] %s" % proc.stderr.strip()[:500])

    stdout = (proc.stdout or "").strip()
    if not stdout:
        return {
            "ok": False,
            "error": "mdl.py 沒有輸出任何東西（return code=%s）" % proc.returncode,
            "hint": "確認 %s 存在且可執行。" % MDL_PATH,
        }

    try:
        return json.loads(stdout)
    except json.JSONDecodeError as exc:
        return {
            "ok": False,
            "error": "stdout 不是合法 JSON：%s" % exc,
            "raw": stdout[:1000],
        }


def demo_subprocess(url: str, do_download: bool) -> None:
    header("接法 2：子行程 + JSON（語言不限）")

    if not os.path.exists(MDL_PATH):
        print("[錯誤] 找不到 %s，跳過本段示範。" % MDL_PATH)
        return

    print("# 唯讀：環境檢查")
    dump("tool mdl_doctor", run_mdl_tool("mdl_doctor", {}))

    print("\n# 唯讀：影片資訊")
    dump("tool mdl_info", run_mdl_tool("mdl_info", {"url": url}))

    if not do_download:
        print("\n（跳過下載示範；加上 --download 才會真的抓檔案。）")
        print("下載時要送的指令長這樣：")
        print(
            '    %s mdl.py tool mdl_download_video \'%s\''
            % (
                os.path.basename(sys.executable),
                json.dumps({"url": url, "quality": "1080"}, ensure_ascii=False),
            )
        )
        return

    print("\n# 下載影片（MP4，1080p 上限）")
    result = run_mdl_tool("mdl_download_video", {"url": url, "quality": "1080"})
    dump("tool mdl_download_video", result)
    for f in result.get("files") or []:
        print("產出檔案：%s" % f.get("path"))


# ==========================================================================
# 接法 3：LLM function calling
# ==========================================================================
def demo_function_calling(url: str) -> None:
    header("接法 3：把 TOOL_SCHEMAS 餵給 LLM function calling（僅示意，不呼叫 API）")

    mdl = import_mdl()
    if mdl is None:
        return

    schemas = getattr(mdl, "TOOL_SCHEMAS", None)
    if not isinstance(schemas, list):
        print("[錯誤] mdl.TOOL_SCHEMAS 不存在或型別不對。")
        return

    print("mdl.TOOL_SCHEMAS 共 %d 個工具：%s\n" % (
        len(schemas),
        ", ".join(s.get("name", "?") for s in schemas),
    ))

    # -- 步驟 A：TOOL_SCHEMAS 本身就是 Anthropic tools= 參數的格式 ----------
    print("步驟 A：TOOL_SCHEMAS 已經是 Anthropic Messages API 要的形狀")
    print("        （name / description / input_schema），可以原封不動丟進去：\n")
    print("    response = client.messages.create(")
    print('        model="claude-sonnet-4-5",')
    print("        max_tokens=1024,")
    print("        tools=mdl.TOOL_SCHEMAS,          # <-- 就是這個")
    print('        messages=[{"role": "user", "content": "幫我把 %s 存成 mp3"}],' % url)
    print("    )\n")

    print("    tools= 實際長這樣（只印第一個工具當範例）：")
    print(json.dumps(schemas[:1], ensure_ascii=False, indent=2))

    # -- 步驟 B：收到 tool_use 之後怎麼 dispatch ---------------------------
    print("\n步驟 B：模型回 stop_reason=\"tool_use\" 時，把每個 tool_use block")
    print("        丟回 mdl.call_tool，再把結果包成 tool_result 送回去：\n")
    print(
        "    def dispatch(block):\n"
        "        result = mdl.call_tool(block.name, block.input)   # 不會拋例外\n"
        "        return {\n"
        '            "type": "tool_result",\n'
        '            "tool_use_id": block.id,\n'
        '            "content": json.dumps(result, ensure_ascii=False),\n'
        '            "is_error": not result["ok"],\n'
        "        }\n"
    )

    # -- 步驟 C：用假的 tool_use 實際跑一次 dispatch -----------------------
    print("步驟 C：用一個假造的 tool_use block 實際跑一次 dispatch（唯讀工具）：\n")

    fake_tool_use = {
        "type": "tool_use",
        "id": "toolu_example_0123456789",
        "name": "mdl_doctor",
        "input": {},
    }
    print("    模型回傳的 tool_use block：")
    print(json.dumps(fake_tool_use, ensure_ascii=False, indent=2))

    result = mdl.call_tool(fake_tool_use["name"], fake_tool_use["input"])
    tool_result = {
        "type": "tool_result",
        "tool_use_id": fake_tool_use["id"],
        "content": json.dumps(result, ensure_ascii=False),
        "is_error": not result.get("ok", False),
    }
    print("\n    要送回模型的 tool_result block：")
    print(json.dumps(tool_result, ensure_ascii=False, indent=2)[:1500])

    print("\n重點：call_tool 永遠回傳統一信封的 dict、永遠不拋例外，")
    print("      所以 dispatch 迴圈不需要 try/except，看 result['ok'] 就好。")


# ==========================================================================
def main() -> int:
    parser = argparse.ArgumentParser(
        description="示範三種把影音下載器接給 agent 用的方式。"
    )
    parser.add_argument(
        "--download",
        action="store_true",
        help="連真正會下載檔案的示範一起跑（預設只跑唯讀的 doctor / info）",
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_URL,
        help="示範用的網址（預設是一支公開的 YouTube 影片）",
    )
    parser.add_argument(
        "--only",
        choices=["import", "subprocess", "schemas"],
        help="只跑其中一段示範",
    )
    args = parser.parse_args()

    print("影音下載器 —— agent 介接示範")
    print("引擎路徑：%s" % MDL_PATH)
    print("示範網址：%s" % args.url)
    print("下載示範：%s" % ("開啟" if args.download else "關閉（加 --download 開啟）"))

    if args.only in (None, "import"):
        demo_import(args.url, args.download)
    if args.only in (None, "subprocess"):
        demo_subprocess(args.url, args.download)
    if args.only in (None, "schemas"):
        demo_function_calling(args.url)

    print("\n" + SEP)
    print("示範結束。第四種接法是 MCP：見 src\\mcp_server.py 的說明。")
    print(SEP)
    return 0


if __name__ == "__main__":
    sys.exit(main())
