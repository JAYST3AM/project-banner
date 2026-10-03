"""PixelLab client for Project Banner — small CLI over the v2 HTTP API.

The API key is NEVER stored in this file: it is read from the PIXELLAB_API_KEY
environment variable, or from the local encrypted vault (vault.sh) when the
env var is absent. Nothing here prints the key.

Usage:
    python tools/pixellab/pixellab.py balance
    python tools/pixellab/pixellab.py unzoom in.png out.png
    python tools/pixellab/pixellab.py image out.png --desc "..." --w 96 --h 96 [--seed 7]
    python tools/pixellab/pixellab.py animate in.png out_dir --action "..." [--frames 8] [--seed 7]
    python tools/pixellab/pixellab.py job <job_id>

Deps: pillow (run via `uv run --with pillow python tools/pixellab/pixellab.py ...`).
Docs: https://api.pixellab.ai/v2/docs (OpenAPI: /v2/openapi.json).
"""
import argparse, base64, io, json, os, subprocess, sys, time
import urllib.request

BASE = "https://api.pixellab.ai/v2"
BASH = r"C:\Program Files\Git\bin\bash.exe"
VAULT = "C:/Users/jayde/AppData/Local/hermes/vault/vault.sh"


def get_key() -> str:
    key = os.environ.get("PIXELLAB_API_KEY", "").strip()
    if not key and os.path.exists(BASH):
        try:
            key = subprocess.run([BASH, VAULT, "get", "PIXELLAB_API_KEY"],
                                 capture_output=True, text=True, timeout=30).stdout.strip()
        except Exception:
            pass
    if not key:
        sys.exit("PIXELLAB_API_KEY not set and vault lookup failed")
    return key


def api(path, payload=None, method="POST", timeout=240):
    req = urllib.request.Request(
        BASE + path, method=method,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Authorization": "Bearer " + get_key(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:400]
        sys.exit("HTTP %s on %s: %s" % (e.code, path, body))


def b64img(path):
    return {"type": "base64", "base64": base64.b64encode(open(path, "rb").read()).decode(), "format": "png"}


def save_img(obj, path):
    raw = obj["base64"]
    if raw.startswith("data:"):
        raw = raw.split(",", 1)[1]
    open(path, "wb").write(base64.b64decode(raw))
    from PIL import Image
    im = Image.open(path)
    print("saved %s (%dx%d)" % (path, im.width, im.height), flush=True)


def poll_job(jid, every=6, tries=90):
    for _ in range(tries):
        time.sleep(every)
        st = api("/background-jobs/%s" % jid, method="GET")
        print("status:", st.get("status"), flush=True)
        if st.get("status") in ("completed", "failed"):
            return st
    sys.exit("job %s did not finish in time" % jid)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("balance")
    p = sub.add_parser("unzoom"); p.add_argument("src"); p.add_argument("dst")
    p = sub.add_parser("image")
    p.add_argument("dst"); p.add_argument("--desc", required=True)
    p.add_argument("--w", type=int, default=64); p.add_argument("--h", type=int, default=64)
    p.add_argument("--seed", type=int, default=None)
    p = sub.add_parser("animate")
    p.add_argument("src"); p.add_argument("out_dir"); p.add_argument("--action", required=True)
    p.add_argument("--frames", type=int, default=8); p.add_argument("--seed", type=int, default=7)
    p.add_argument("--last-frame", default=None, help="optional end keyframe for loops")
    p = sub.add_parser("job"); p.add_argument("job_id")
    a = ap.parse_args()

    if a.cmd == "balance":
        print(json.dumps(api("/balance", method="GET"), indent=1))
    elif a.cmd == "unzoom":
        r = api("/unzoom", {"image": b64img(a.src), "quantize": 0})
        print("native:", r.get("unzoomed_size"), "zoom:", r.get("zoom_factor_detected"))
        save_img(r["image"], a.dst)
    elif a.cmd == "image":
        r = api("/create-image-pixen", {"description": a.desc,
                "image_size": {"width": a.w, "height": a.h},
                "no_background": True, "seed": a.seed, "enhance_prompt": False})
        imgs = r.get("images") or r.get("image") or []
        if isinstance(imgs, dict):
            imgs = [imgs]
        assert imgs, json.dumps(r)[:300]
        r2 = api("/background-jobs/%s" % r["background_job_id"], method="GET") if r.get("background_job_id") else None
        if r2:
            st = poll_job(r["background_job_id"]) if r2.get("status") != "completed" else r2
            imgs = (st.get("last_response") or {}).get("images") or imgs
        save_img(imgs[0], a.dst)
    elif a.cmd == "animate":
        payload = {"first_frame": b64img(a.src), "action": a.action,
                   "frame_count": a.frames, "no_background": True, "seed": a.seed,
                   "enhance_prompt": False}
        if a.last_frame:
            payload["last_frame"] = b64img(a.last_frame)
        r = api("/animate-with-text-v3", payload)
        jid = r.get("background_job_id") or r.get("job_id")
        print("job:", jid, flush=True)
        st = poll_job(jid)
        if st.get("status") != "completed":
            sys.exit("job failed: " + json.dumps(st)[:400])
        imgs = (st.get("last_response") or {}).get("images") or []
        if isinstance(imgs, dict):
            imgs = list(imgs.values())
        os.makedirs(a.out_dir, exist_ok=True)
        for i, im in enumerate(imgs):
            save_img(im, os.path.join(a.out_dir, "frame_%02d.png" % i))
        print("frames:", len(imgs))
    elif a.cmd == "job":
        print(json.dumps(api("/background-jobs/%s" % a.job_id, method="GET"), indent=1)[:2000])


if __name__ == "__main__":
    main()
