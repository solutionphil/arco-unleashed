#!/usr/bin/env python3
# voronFDM <-> moonraker transparent WebSocket relay.
# Goal: decouple voronFDM's ~5s SAVE_CONFIG-restart block from moonraker so moonraker NEVER sees a
# stalled client and never drops the connection -> voronFDM never has to reconnect -> no freeze.
#  - Always reads from moonraker (upstream) and fire-and-forget forwards to voronFDM (tornado buffers
#    if voronFDM is momentarily not reading) -> no backpressure to moonraker.
#  - Auto-pongs moonraker's pings (tornado client does this).
#  - Never pings voronFDM (websocket_ping_interval=None) -> never drops it for being slow.
#  - If moonraker ever closes, sends voronFDM a clean WS CLOSE (1001) so its reconnect fires.
# moonraker-neutral (no moonraker patch) + voronFDM-binary untouched (redirected via the connshim
# LD_PRELOAD). Runs under the moonraker-env python (tornado). Listens on 127.0.0.1:7126.
# NOTE: the TFT-reprint print.start injection lives in a SEPARATE helper (arco-reprint-bridge.py)
# that reads voronFDM's stdout; this relay is pure freeze-protection and touches no message.
import asyncio
import tornado.web, tornado.websocket, tornado.ioloop
from tornado.websocket import websocket_connect
import logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s wsrelay %(message)s")
UP = "ws://127.0.0.1:7125/websocket"
MAXMSG = 64 * 1024 * 1024
# WAIT for moonraker rather than turning voronFDM away. The upstream connection is made when voronFDM
# ARRIVES, not when this relay starts, so on a fast boot voronFDM can get here first. And voronFDM never
# retries a refused connection -- measured on hardware 2026-08-12: it stayed alive for 32 s with
# moonraker back up and never tried again; only the watchdog's restart fixed it, costing a full watchdog
# cycle plus its ~15 s of panel initialisation. Turning it away once is therefore expensive, and holding
# it for a few seconds costs nothing. This also removes the only reason the boot ordering had to be
# exact, which is what made it safe to look at that at all.
UP_WAIT = 60

class Relay(tornado.websocket.WebSocketHandler):
    def check_origin(self, origin): return True
    async def open(self, *a):
        self.up = None; self.alive = True
        loop = tornado.ioloop.IOLoop.current()
        deadline = loop.time() + UP_WAIT
        tries = 0
        last = "?"
        while self.alive:
            tries += 1
            try:
                self.up = await websocket_connect(UP, ping_interval=None, max_message_size=MAXMSG)
                break
            except Exception as e:
                last = str(e)
                if loop.time() >= deadline:
                    logging.info("upstream connect FAIL after %ss / %d tries: %s", UP_WAIT, tries, last)
                    self.close(); return
                await asyncio.sleep(1)
        if not self.alive or self.up is None:
            return
        if tries > 1:
            logging.info("bridged voronFDM <-> moonraker (waited %d tries; last error: %s)", tries, last)
        else:
            logging.info("bridged voronFDM <-> moonraker")
        loop.spawn_callback(self.pump)
    async def pump(self):
        while self.alive:
            try:
                msg = await self.up.read_message()
            except Exception:
                break
            if msg is None:
                break
            try:
                self.write_message(msg, binary=isinstance(msg, (bytes, bytearray)))
            except Exception:
                break
        try:
            self.close(1001, "upstream closed")  # clean CLOSE -> voronFDM reconnects
        except Exception:
            pass
    def on_message(self, msg):
        if self.up:
            try:
                self.up.write_message(msg, binary=isinstance(msg, (bytes, bytearray)))
            except Exception:
                pass
    def on_close(self):
        self.alive = False
        if self.up:
            try:
                self.up.close()
            except Exception:
                pass

def main():
    app = tornado.web.Application(
        [(r"/.*", Relay)],
        websocket_ping_interval=None,
        websocket_max_message_size=MAXMSG,
    )
    app.listen(7126, address="127.0.0.1")
    logging.info("listening 127.0.0.1:7126 -> moonraker 7125")
    tornado.ioloop.IOLoop.current().start()

if __name__ == "__main__":
    main()
