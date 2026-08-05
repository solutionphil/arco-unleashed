#!/usr/bin/env python3
# portal.py — Arco Unleashed WiFi captive portal (no Phrozen software needed).
# Serves a small responsive page (logo + network list + password) on the setup AP.
# On submit: writes wpa_supplicant-wlan0.conf and reboots so the printer joins the WiFi.
#
# Run as root (it writes the wpa config + reboots). Started by wifi-portal.sh.
import json, os, subprocess, threading, time, html, hashlib, glob
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

PORT = 80
NETWORKS_FILE = "/tmp/arco-wifi-networks.json"      # written by wifi-portal.sh (pre-scan)
WPA_CONF = "/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
# user-acknowledged (in the portal) that the Phrozen download happens on their device, subject to
# Phrozen's terms. Recorded here so arco-firstrun stage 2 fetches only after explicit consent.
CONSENT_FILE = "/var/lib/arco-unleashed/phrozen-consent"
# Records that a network was chosen HERE, so a stale WiFi file left on the USB stick cannot overwrite it
# on the next boot (see apply-selfflash-seed.sh).
PORTAL_MARK = os.environ.get("ARCO_PORTAL_MARK", "/var/lib/arco-unleashed/portal-configured")
# Same list apply-selfflash-seed.sh consults: WiFi files from the stick that must not be applied again.
SEED_STAMP  = os.environ.get("ARCO_SEED_STAMP", "/var/lib/arco-unleashed/seed-applied")
LOGO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "logo.png")

PAGE = """<!DOCTYPE html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>Arco Unleashed — WiFi Setup</title>
<style>
  :root{ --blue:#2747e0; --blue2:#1b34b8; --ink:#0d1330; --bg:#eef1fb; --card:#fff; }
  *{box-sizing:border-box;margin:0;padding:0;font-family:'Segoe UI',system-ui,Arial,sans-serif}
  body{background:linear-gradient(160deg,#dfe6fb,#eef1fb 60%);color:var(--ink);min-height:100vh;
       display:flex;align-items:center;justify-content:center;padding:18px}
  .card{background:var(--card);width:100%;max-width:430px;border-radius:20px;
        box-shadow:0 18px 50px rgba(27,52,184,.18);overflow:hidden}
  .head{background:#fff;padding:18px 20px 6px;text-align:center}
  .head img{max-width:100%;height:auto}
  .body{padding:8px 22px 24px}
  h1{font-size:17px;text-align:center;color:var(--blue2);margin:4px 0 2px;letter-spacing:.2px}
  p.sub{text-align:center;color:#6b7390;font-size:12.5px;margin-bottom:16px}
  label{display:block;font-size:12px;font-weight:700;color:#444c6e;margin:14px 0 5px;text-transform:uppercase;letter-spacing:.4px}
  select,input{width:100%;padding:13px 14px;border:2px solid #d7ddf5;border-radius:12px;font-size:15px;background:#f7f9ff;color:var(--ink)}
  select:focus,input:focus{outline:none;border-color:var(--blue)}
  .row{display:flex;gap:8px;align-items:center}
  .pw-toggle{font-size:12px;color:var(--blue);background:none;border:none;cursor:pointer;white-space:nowrap;padding:6px}
  button.go{width:100%;margin-top:20px;padding:14px;border:none;border-radius:12px;background:var(--blue);
            color:#fff;font-size:16px;font-weight:800;letter-spacing:.4px;cursor:pointer;
            box-shadow:0 8px 18px rgba(39,71,224,.35);transition:transform .05s,background .2s}
  button.go:hover{background:var(--blue2)} button.go:active{transform:translateY(1px)}
  button.go:disabled{background:#9aa6e0;box-shadow:none;cursor:default}
  .refresh{display:block;margin:10px auto 0;font-size:12px;color:var(--blue);background:none;border:none;cursor:pointer}
  .msg{margin-top:14px;padding:12px 14px;border-radius:12px;font-size:13.5px;display:none}
  .msg.ok{display:block;background:#e7f7ec;color:#1c7a3f;border:1px solid #b6e6c6}
  .msg.err{display:block;background:#fdecec;color:#b3261e;border:1px solid #f3c2c0}
  .usbnote{margin:0 0 4px;padding:11px 13px;background:#fff7e6;border:1px solid #f0d488;
           border-radius:12px;font-size:12.5px;color:#7a5a12;line-height:1.45}
  .usbnote code{background:#fbedc7;padding:1px 5px;border-radius:5px;font-size:11.5px}
  .consent{display:flex;gap:9px;align-items:flex-start;margin-top:18px;padding:12px 13px;
           background:#f7f9ff;border:1px solid #d7ddf5;border-radius:12px}
  .consent input{width:18px;height:18px;margin-top:1px;flex:0 0 auto;accent-color:var(--blue)}
  .consent label{margin:0;text-transform:none;letter-spacing:0;font-weight:500;font-size:12px;color:#4a5274;line-height:1.45}
  .foot{text-align:center;color:#9aa1bd;font-size:11px;padding:0 0 18px}
</style></head><body>
  <div class="card">
    <div class="head"><img src="/logo.png" alt="Arco Unleashed — Bookworm Edition"></div>
    <div class="body">
      <h1>WiFi Setup</h1>
      <p class="sub">Choose your network and connect — the printer finishes setup automatically.</p>
      <div class="usbnote">&#128190; <b>Before you finish:</b> have a <b>FAT32 USB stick</b> with
        Phrozen's official <code>Arco_FW_V*.zip</code> ready. After connecting, the printer asks you
        to <b>plug it into the USB port</b> to install Phrozen's software (it is never downloaded).</div>
      <form id="f">
        <label for="ssid">Network</label>
        <select id="ssid" name="ssid" onchange="toggleManual()"></select>
        <input id="ssidm" type="text" placeholder="Network name (SSID)" autocomplete="off" style="display:none;margin-top:8px">
        <button type="button" class="refresh" onclick="loadNets()">&#x21bb; rescan networks</button>
        <label for="psk">Password</label>
        <div class="row">
          <input id="psk" name="psk" type="password" autocomplete="off" placeholder="WiFi password">
          <button type="button" class="pw-toggle" onclick="tog()">show</button>
        </div>
        <label for="cc">Country (WiFi region)</label>
        <select id="cc" name="cc" onchange="toggleCC()">
          <option value="" disabled selected>Select your country…</option>
          <option value="AR">Argentina (AR)</option>
          <option value="AU">Australia (AU)</option>
          <option value="AT">Austria (AT)</option>
          <option value="BE">Belgium (BE)</option>
          <option value="BR">Brazil (BR)</option>
          <option value="CA">Canada (CA)</option>
          <option value="CL">Chile (CL)</option>
          <option value="CN">China (CN)</option>
          <option value="CZ">Czechia (CZ)</option>
          <option value="DK">Denmark (DK)</option>
          <option value="FI">Finland (FI)</option>
          <option value="FR">France (FR)</option>
          <option value="DE">Germany (DE)</option>
          <option value="GR">Greece (GR)</option>
          <option value="HK">Hong Kong (HK)</option>
          <option value="HU">Hungary (HU)</option>
          <option value="IN">India (IN)</option>
          <option value="ID">Indonesia (ID)</option>
          <option value="IE">Ireland (IE)</option>
          <option value="IL">Israel (IL)</option>
          <option value="IT">Italy (IT)</option>
          <option value="JP">Japan (JP)</option>
          <option value="MY">Malaysia (MY)</option>
          <option value="MX">Mexico (MX)</option>
          <option value="NL">Netherlands (NL)</option>
          <option value="NZ">New Zealand (NZ)</option>
          <option value="NO">Norway (NO)</option>
          <option value="PH">Philippines (PH)</option>
          <option value="PL">Poland (PL)</option>
          <option value="PT">Portugal (PT)</option>
          <option value="RO">Romania (RO)</option>
          <option value="SA">Saudi Arabia (SA)</option>
          <option value="SG">Singapore (SG)</option>
          <option value="ZA">South Africa (ZA)</option>
          <option value="KR">South Korea (KR)</option>
          <option value="ES">Spain (ES)</option>
          <option value="SE">Sweden (SE)</option>
          <option value="CH">Switzerland (CH)</option>
          <option value="TW">Taiwan (TW)</option>
          <option value="TH">Thailand (TH)</option>
          <option value="TR">Turkey (TR)</option>
          <option value="UA">Ukraine (UA)</option>
          <option value="AE">United Arab Emirates (AE)</option>
          <option value="GB">United Kingdom (GB)</option>
          <option value="US">United States (US)</option>
          <option value="__manual__">Other… (enter code)</option>
        </select>
        <input id="ccm" type="text" maxlength="2" placeholder="2-letter WiFi code (e.g. AU)" autocomplete="off"
               style="display:none;margin-top:8px;text-transform:uppercase">
        <div class="consent">
          <input type="checkbox" id="consent">
          <label for="consent">I will provide Phrozen's official firmware myself on a USB stick
            (<b>Arco_FW_V*.zip</b>), and I use Phrozen's software &amp; cloud (PhrozenGo /
            ThroughTek&nbsp;TUTK) <b>at my own responsibility</b> under <b>Phrozen's own license
            &amp; privacy terms</b>.</label>
        </div>
        <button type="submit" class="go" id="go" disabled>Connect</button>
      </form>
      <div class="msg" id="msg"></div>
    </div>
    <div class="foot">Arco Unleashed &middot; Bookworm Edition</div>
  </div>
<script>
async function loadNets(){
  const sel=document.getElementById('ssid'); sel.innerHTML='<option>scanning…</option>';
  let n=[];
  try{const r=await fetch('/networks');n=await r.json();}catch(e){n=[];}
  sel.innerHTML='';
  n.forEach(s=>{const o=document.createElement('option');o.value=s;o.textContent=s;sel.appendChild(o);});
  const om=document.createElement('option');om.value='__manual__';
  om.textContent=n.length?'✏️ Other / hidden network…':'✏️ Enter network name manually…';
  sel.appendChild(om);
  if(!n.length) sel.value='__manual__';
  toggleManual();
}
function toggleManual(){
  const man=document.getElementById('ssid').value==='__manual__';
  const m=document.getElementById('ssidm'); m.style.display=man?'block':'none'; if(man) m.focus();
}
function toggleCC(){
  const man=document.getElementById('cc').value==='__manual__';
  const m=document.getElementById('ccm'); m.style.display=man?'block':'none'; if(man) m.focus();
}
function tog(){const p=document.getElementById('psk');p.type=p.type==='password'?'text':'password';}
const cb=document.getElementById('consent');
cb.addEventListener('change',()=>{document.getElementById('go').disabled=!cb.checked;});
document.getElementById('f').addEventListener('submit',async e=>{
  e.preventDefault();const go=document.getElementById('go');const m=document.getElementById('msg');
  let ssid=document.getElementById('ssid').value;const psk=document.getElementById('psk').value;
  if(ssid==='__manual__'){ssid=document.getElementById('ssidm').value.trim();}
  if(!ssid){m.className='msg err';m.textContent='Please pick or type a network name.';return;}
  let cc=document.getElementById('cc').value;
  if(cc==='__manual__'){cc=document.getElementById('ccm').value.trim().toUpperCase();}
  if(!/^[A-Z]{2}$/.test(cc)){m.className='msg err';m.textContent='Please select your country (or pick "Other" and enter your 2-letter WiFi code) — a wrong region stops the printer joining your network.';return;}
  if(!cb.checked){m.className='msg err';m.textContent='Please tick the consent box first.';return;}
  go.disabled=true;go.textContent='Connecting…';
  try{const r=await fetch('/connect',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:'ssid='+encodeURIComponent(ssid)+'&psk='+encodeURIComponent(psk)+'&cc='+encodeURIComponent(cc)+'&consent=1'});
    if(r.ok){m.className='msg ok';m.innerHTML='Saved! The printer reboots and joins <b>'+ssid+'</b>. To finish setup, insert a USB stick with the Phrozen firmware (<b>Arco_FW_V*.zip</b>) when the display asks. You can close this page.';}
    else{const why=await r.text();m.className='msg err';
         m.textContent=why&&why.length>3?why:'Could not save — try again.';
         go.disabled=false;go.textContent='Connect';}
  }catch(e){m.className='msg ok';m.textContent='Rebooting… you can close this page.';}
});
loadNets();
</script></body></html>"""

def read_networks():
    try:
        with open(NETWORKS_FILE) as f:
            return json.load(f)
    except Exception:
        return []

def wpa_quote(s):
    """Escape a value for a quoted wpa_supplicant string.

    The old code DELETED double quotes instead of escaping them, which silently joined a different
    network or computed a different key — and it ignored backslashes entirely, so a password ending in
    one escaped the closing quote and made wpa_supplicant reject the whole file (the same total failure
    a too-short passphrase causes: no WiFi at all, nothing saying why).
    """
    return s.replace('\\', '\\\\').replace('"', '\\"')


def valid_ssid(ssid):
    """wpa_supplicant allows at most 32 BYTES; more is a parse error, i.e. the whole file is refused."""
    return 0 < len(ssid.encode('utf-8')) <= 32


def valid_psk(psk):
    """wpa_supplicant validates the WHOLE config file: one bad passphrase and it exits 255, systemd's
    start limit keeps it down for the rest of the boot, and the printer has no WiFi at all — not even
    the network it had before. Seen on hardware with a 5-character password. So refuse it here and say
    why, instead of writing a file that takes the radio down."""
    if psk == '':
        return True                                   # open network -> key_mgmt=NONE
    if len(psk) == 64 and all(c in '0123456789abcdefABCDEF' for c in psk):
        return True                                   # raw PSK
    # BYTES, not characters: wpa_supplicant counts bytes, so a 63-character passphrase with umlauts is
    # over the limit and would be rejected despite passing a naive length check.
    return 8 <= len(psk.encode('utf-8')) <= 63


def retire_stick_wifi():
    """Mark the WiFi files currently on the USB stick as spent, by CONTENT.

    The stick can still hold WiFi from before this moment — the flasher captures one when the flash is
    armed, and the user may have left a wifi-seed.txt — and first boot would otherwise apply those over
    what was just typed here, one per boot, bringing this portal back each time. That is exactly what
    happened on hardware: the portal appeared once per stale file.

    Recording DIGESTS, not a timestamp, is deliberate. The first version compared modification times and
    it never worked: the stick is FAT, Windows writes FAT timestamps in local time and Linux reads them
    as UTC, so a file the user made on their PC looks hours into the future. A seed the user adds AFTER
    this has different contents, so it is not on the list and still applies — the rescue path lives.
    """
    stamped = 0
    # Same candidates apply-selfflash-seed.sh scans, and overridable the same way, so the two cannot
    # disagree about where the stick is — if they did, this would retire nothing and the stale file
    # would win on the next boot, which is the bug this function exists to prevent.
    dirs = os.environ.get('ARCO_USB_DIRS')
    dirs = dirs.split() if dirs else glob.glob('/media/*') + glob.glob('/mnt/*') + \
        glob.glob('/run/media/*/*') + ['/home/mks/printer_data/gcodes/USB']
    for d in dirs:
        for pat in ('wifi-seed.txt', '.arco-wifi.conf'):
            p = os.path.join(d, pat)
            try:
                if not os.path.isfile(p):
                    continue
                with open(p, 'rb') as f:
                    dg = hashlib.sha256(f.read()).hexdigest()
                os.makedirs(os.path.dirname(SEED_STAMP), exist_ok=True)
                with open(SEED_STAMP, 'a') as f:
                    f.write(dg + '\n')
                stamped += 1
                print('[portal] retired %s (already superseded by what you just entered)' % p, flush=True)
            except Exception as e:
                print('[portal] WARNING could not retire %s (%s) — it could overwrite this network on the '
                      'next boot' % (p, e), flush=True)
    try:
        os.makedirs(os.path.dirname(PORTAL_MARK), exist_ok=True)
        with open(PORTAL_MARK, 'w') as f:
            f.write('network set via the setup portal at %s (%d stick file(s) retired)\n'
                    % (time.strftime('%Y-%m-%dT%H:%M:%S%z'), stamped))
    except Exception:
        pass


def write_wpa(ssid, psk, cc='00'):
    cc = (cc or '').strip().upper()
    if len(cc) != 2 or not cc.isalpha():
        cc = '00'   # world roaming — permissive fallback if the country field was blank/invalid
    body = 'ctrl_interface=/run/wpa_supplicant\nupdate_config=1\ncountry=%s\n\nnetwork={\n' % cc
    body += '    ssid="%s"\n' % wpa_quote(ssid)
    if psk:
        body += '    psk="%s"\n' % wpa_quote(psk)
    else:
        body += '    key_mgmt=NONE\n'
    body += '}\n'
    with open(WPA_CONF, 'w') as f:
        f.write(body)
    os.chmod(WPA_CONF, 0o600)
    retire_stick_wifi()

def write_consent():
    os.makedirs(os.path.dirname(CONSENT_FILE), exist_ok=True)
    with open(CONSENT_FILE, 'w') as f:
        f.write('phrozen-download acknowledged via WiFi portal at %s\n'
                % time.strftime('%Y-%m-%dT%H:%M:%S%z'))

def reboot_later():
    time.sleep(2)
    subprocess.call(['systemctl', 'stop', 'arco-wifi-portal-ap.service'])  # tear down AP (best effort)
    subprocess.call(['reboot'])

class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype='text/html; charset=utf-8'):
        b = body if isinstance(body, bytes) else body.encode()
        self.send_response(code); self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
    def do_GET(self):
        p = self.path.split('?')[0]
        if p == '/' or p == '/index.html':
            self._send(200, PAGE)
        elif p == '/logo.png':
            try:
                with open(LOGO, 'rb') as f: self._send(200, f.read(), 'image/png')
            except Exception: self._send(404, b'')
        elif p == '/networks':
            self._send(200, json.dumps(read_networks()), 'application/json')
        else:
            # captive-portal detection -> redirect to the portal
            self.send_response(302); self.send_header('Location', 'http://192.168.4.1/'); self.end_headers()
    def do_POST(self):
        if self.path.split('?')[0] != '/connect':
            self._send(404, b''); return
        n = int(self.headers.get('Content-Length', 0))
        d = parse_qs(self.rfile.read(n).decode())
        ssid = (d.get('ssid', ['']) [0]).strip(); psk = (d.get('psk', ['']) [0])
        cc = (d.get('cc', ['']) [0]).strip()
        consent = (d.get('consent', ['']) [0]) == '1'
        # Say WHY on the server side as well. A rejection used to be visible only to the phone, as
        # "Could not save — try again" — which tells whoever is holding it nothing, and tells the log
        # nothing at all. Reported on hardware: the first submit fails and an identical retry works.
        if not ssid:
            print('[portal] REJECTED: no ssid in the submission', flush=True)
            self._send(400, 'no ssid'); return
        if not consent:
            print('[portal] REJECTED: consent box not ticked', flush=True)
            self._send(400, 'consent required'); return
        if not valid_ssid(ssid):
            print('[portal] REJECTED: SSID is %d bytes' % len(ssid.encode('utf-8')), flush=True)
            self._send(400, 'A network name can be at most 32 characters.'); return
        if not valid_psk(psk):
            print('[portal] REJECTED: passphrase is %d characters' % len(psk), flush=True)
            self._send(400, 'A WiFi password must be 8 to 63 characters (yours is %d). '
                            'Leave it empty only for an open network.' % len(psk)); return
        try:
            write_consent()
            write_wpa(ssid, psk, cc)
            print('[portal] accepted ssid=%r cc=%r psk=%s — rebooting shortly'
                  % (ssid, cc, 'set' if psk else 'EMPTY (open network)'), flush=True)
            self._send(200, 'ok')
            threading.Thread(target=reboot_later, daemon=True).start()
        except Exception as e:
            import traceback
            print('[portal] FAILED to save: %r' % (e,), flush=True)
            traceback.print_exc()
            self._send(500, str(e))

def bind_server():
    """Bind :80, and be loud instead of dying quietly if it is taken.

    Port 80 is not automatically ours. This project's own setup-nginx-ports.sh puts Mainsail on :80
    (the stock Arco URL every owner has bookmarked), so on a real printer nginx already holds it. An
    unguarded bind then raises EADDRINUSE, this process dies in its first millisecond, wifi-portal.sh
    returns, and because that script runs under a Type=oneshot unit, systemd tears down the cgroup and
    reaps hostapd with it. Observed on hardware: the access point vanished the instant the "connect to
    Arco-Unleashed-Setup" screen appeared — the screen kept showing because nothing repaints it.
    wifi-portal.sh frees the port before starting us; this is the second line of defence.
    """
    for attempt in (1, 2, 3):
        try:
            return ThreadingHTTPServer(('0.0.0.0', PORT), H)
        except OSError as e:
            print('[portal] cannot bind :%d (%s)' % (PORT, e), flush=True)
            if attempt == 1:
                # Mainsail is unreachable during setup anyway (no network yet), and a successful
                # submit reboots the printer, which brings nginx back.
                print('[portal] stopping nginx to free the port', flush=True)
                try:
                    subprocess.call(['systemctl', 'stop', 'nginx'])
                except Exception as ee:      # no systemd (or no systemctl) must not abort the retry
                    print('[portal] could not run systemctl: %s' % ee, flush=True)
            time.sleep(2)
    return None


if __name__ == '__main__':
    srv = bind_server()
    if srv is None:
        print('[portal] giving up: port %d stays occupied. To see who holds it: ss -lptn "sport = :%d"'
              % (PORT, PORT), flush=True)
        raise SystemExit(3)
    print('[portal] listening on :%d' % PORT, flush=True)
    srv.serve_forever()
