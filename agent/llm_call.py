"""
llm_call.py —— 模型调用层（独立进程，由 agent.ps1 调用）

为什么用 Python：这台机器的 PowerShell/.NET TLS 握手失败（连百度都报"接收时发生错误"），
而 Python 的 urllib 正常。所有 HTTP 都走这里，agent 只负责编排。

用法：
    python llm_call.py <request.json> <response.json>
request: {style, baseUrl, model, apiKey, messages:[{role,content}], image(base64 可选), timeout}
response: {ok, content, usage:{prompt,completion,total}, error}
"""
import json
import sys
import urllib.request
import urllib.error


def build_openai_payload(req):
    msgs = []
    image = req.get("image") or ""
    for i, m in enumerate(req["messages"]):
        last = (i == len(req["messages"]) - 1)
        if m["role"] == "user" and image and last:
            msgs.append({
                "role": "user",
                "content": [
                    {"type": "text", "text": m["content"]},
                    {"type": "image_url", "image_url": {"url": "data:image/png;base64," + image}},
                ],
            })
        else:
            msgs.append({"role": m["role"], "content": m["content"]})

    payload = {
        "model": req["model"],
        "messages": msgs,
        "temperature": 0,
    }
    if not image:
        payload["response_format"] = {"type": "json_object"}
    return payload, "/chat/completions"


def build_ollama_payload(req):
    msgs = []
    for m in req["messages"]:
        msgs.append({"role": m["role"], "content": m["content"]})
    image = req.get("image") or ""
    if image:
        msgs[-1]["images"] = [image]
    payload = {
        "model": req["model"],
        "messages": msgs,
        "stream": False,
        "format": "json",
        "options": {"temperature": 0, "num_predict": 1600},
    }
    return payload, "/api/chat"


def build_anthropic_payload(req):
    system = ""
    rest = []
    for m in req["messages"]:
        if m["role"] == "system":
            system = m["content"]
        else:
            rest.append(m)

    image = req.get("image") or ""
    msgs = []
    for i, m in enumerate(rest):
        last = (i == len(rest) - 1)
        if image and last and m["role"] == "user":
            msgs.append({
                "role": "user",
                "content": [
                    {"type": "text", "text": m["content"]},
                    {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": image}},
                ],
            })
        else:
            msgs.append({"role": m["role"], "content": m["content"]})

    payload = {"model": req["model"], "messages": msgs, "max_tokens": 1200, "temperature": 0}
    if system:
        payload["system"] = system
    return payload, "/v1/messages"


def extract(style, data):
    if style == "ollama":
        content = (data.get("message") or {}).get("content", "")
        p = int(data.get("prompt_eval_count") or 0)
        c = int(data.get("eval_count") or 0)
        return content, {"prompt": p, "completion": c, "total": p + c}
    if style == "anthropic":
        parts = data.get("content") or []
        content = "".join(x.get("text", "") for x in parts if x.get("type") == "text")
        u = data.get("usage") or {}
        p = int(u.get("input_tokens") or 0)
        c = int(u.get("output_tokens") or 0)
        return content, {"prompt": p, "completion": c, "total": p + c}
    content = ((data.get("choices") or [{}])[0].get("message") or {}).get("content", "")
    u = data.get("usage") or {}
    p = int(u.get("prompt_tokens") or 0)
    c = int(u.get("completion_tokens") or 0)
    return content, {"prompt": p, "completion": c, "total": int(u.get("total_tokens") or p + c)}


def main():
    if len(sys.argv) < 3:
        print("usage: llm_call.py <request.json> <response.json>")
        return 2

    req_path, res_path = sys.argv[1], sys.argv[2]
    with open(req_path, "rb") as f:
        req = json.loads(f.read().decode("utf-8-sig"))

    style = req.get("style", "openai")
    base = (req.get("baseUrl") or "").rstrip("/")

    try:
        if style == "ollama":
            payload, path = build_ollama_payload(req)
            headers = {"Content-Type": "application/json"}
        elif style == "anthropic":
            payload, path = build_anthropic_payload(req)
            headers = {
                "Content-Type": "application/json",
                "x-api-key": req.get("apiKey", ""),
                "anthropic-version": "2023-06-01",
            }
        else:
            payload, path = build_openai_payload(req)
            headers = {"Content-Type": "application/json"}
            if req.get("apiKey"):
                headers["Authorization"] = "Bearer " + req["apiKey"]

        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(base + path, data=body, headers=headers)
        timeout = int(req.get("timeout") or 180)

        with urllib.request.urlopen(request, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
        data = json.loads(raw)
        content, usage = extract(style, data)
        out = {"ok": True, "content": content, "usage": usage}
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", "ignore")[:400]
        except Exception:
            pass
        out = {"ok": False, "error": "HTTP %s: %s" % (e.code, detail)}
    except Exception as e:
        out = {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}

    with open(res_path, "wb") as f:
        f.write(json.dumps(out, ensure_ascii=False).encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
