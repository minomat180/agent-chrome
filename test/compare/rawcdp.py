#!/usr/bin/env python3
"""control probe: minimal raw CDP (no Runtime.enable). usage: rawcdp.py PORT URL JS [wait_s]"""
import asyncio, json, sys, urllib.request, websockets
port, url, js = sys.argv[1], sys.argv[2], sys.argv[3]
wait = float(sys.argv[4]) if len(sys.argv) > 4 else 6
async def main():
    req = urllib.request.Request(f"http://127.0.0.1:{port}/json/new?about:blank", method="PUT")
    t = json.load(urllib.request.urlopen(req))
    async with websockets.connect(t["webSocketDebuggerUrl"], max_size=None) as ws:
        n = 0
        async def call(m, **p):
            nonlocal n; n += 1; i = n
            await ws.send(json.dumps({"id": i, "method": m, "params": p}))
            while True:
                r = json.loads(await ws.recv())
                if r.get("id") == i: return r
        await call("Page.navigate", url=url)
        await asyncio.sleep(wait)
        r = await call("Runtime.evaluate", expression=js, returnByValue=True, awaitPromise=True)
        print(r["result"]["result"].get("value"))
    urllib.request.urlopen(f"http://127.0.0.1:{port}/json/close/{t['id']}")
asyncio.run(main())
