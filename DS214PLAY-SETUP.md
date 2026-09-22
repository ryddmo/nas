# Synology DS214play — Setup Notes

Working notes for the home NAS. Written so future-me (or Claude, next time) can pick up
exactly where this left off without re-deriving everything from scratch.

No secrets live in this file — passwords, VPN credentials and keys are only in DSM itself
and in `~/.ssh/` on the Mac. Anywhere a secret would go, you'll see a placeholder.

## Hardware & identity

| | |
|---|---|
| Model | Synology DS214play (2014) |
| CPU | Intel Atom CE5335 @ 1.6GHz (x86, **32-bit i686** — not ARM, corrected an earlier wrong assumption) |
| RAM | ~700 MB usable (1 GB physical) — very tight, keep this in mind for anything we add |
| DSM | 7.1.1 (build 42962), Swedish UI |
| Hostname | `ds` / `diskstation.lan` |
| LAN IP | `192.168.86.11` (static) |
| MAC | `00:11:32:26:31:56` |
| Admin account | `ryddmo` (member of `administrators`) |

**No Docker / Container Manager support** — the CPU is 32-bit, which rules out the whole
"Docker Compose stack" approach used on more capable NAS boxes (Jellyfin + *arr apps in
containers). Everything here has to be a native DSM package or a manually-scripted
workaround.

## How we got here (brief history)

- NAS went unreachable on the network after a DSM update.
- Diagnosed as a hung boot (network-level ping worked, no service responded).
- Full reset (hold RESET ~4s, beep, release, hold again ~4s, second beep) didn't fully
  clear it; ended up doing a full drive-pull test + fresh DSM install to get back to a
  known-good state.
- Rebuilt storage as a 2-disk **SHR** pool (see below) and re-secured SSH/VPN from scratch.

## Storage

- **Lagringspool 1**: SHR, 2 disks — Disk 1 (1.8 TB) + Disk 2 (3.6 TB), **with data
  protection (1-disk fault tolerance)**. Because SHR mirrors to the *smaller* disk's
  capacity, usable space is ~1.8 TB, not the sum — expected behavior, not a bug.
- Both disks passed SMART (`Felfri`) before being combined.
- **Volym 1**: ext4, ~1.7 TB.

## SSH access

- Key-based only for the Mac ↔ NAS connection. Private key: `~/.ssh/id_ed25519_ds214play`.
- Alias set up in `~/.ssh/config` on the Mac:
  ```
  Host ds214play
      HostName 192.168.86.11
      User ryddmo
      IdentityFile ~/.ssh/id_ed25519_ds214play
  ```
  → connect with just `ssh ds214play`.
- `sudo` on the NAS still requires an interactive password — it is **not** passwordless.
  Any root-level change has to be run by hand in a real terminal session (password never
  typed to Claude), not scripted non-interactively.
- **TODO**: disable SSH password authentication entirely now that the key works (leave
  key auth on). Not done yet.

## VPN (PIA) — for safe downloading

- Provider: **Private Internet Access**, existing account.
- Set up via DSM's **native** VPN client (Control Panel → Network → Network Interface →
  VPN Profile → OpenVPN, imported PIA's `.ovpn` + CA cert), *not* a PIA app — PIA has no
  dedicated Synology package; this is the standard/only route.
- Profile name on disk: `o1790077439` (`/usr/syno/etc/synovpnclient/openvpn/`). Server:
  `de-frankfurt.privacy.network`, UDP port `1198`.
- Verified working: NAS's outbound IP changes to PIA's (Frankfurt) when connected.

### Kill switch — important, and non-default

**DSM's built-in VPN client has no kill switch.** Confirmed by testing: disconnecting the
VPN profile made all traffic silently fall back to the normal home IP (a real leak) until
we added firewall rules.

We could not use the "clean" approach (blocking only Download Station's traffic by user
ID) because this kernel/iptables build (`iptables v1.8.3 legacy`) **does not have the
`owner` match module**. Fallback: block **all** non-VPN outbound traffic on `eth0`,
excepting only what's needed to keep functioning:

```sh
iptables -A OUTPUT -o eth0 -d 192.168.86.0/24 -j ACCEPT   # LAN
iptables -A OUTPUT -o eth0 -p udp --dport 53 -j ACCEPT    # DNS
iptables -A OUTPUT -o eth0 -p tcp --dport 53 -j ACCEPT    # DNS
iptables -A OUTPUT -o eth0 -p udp --dport 1198 -j ACCEPT  # PIA's own port, for reconnect
iptables -A OUTPUT -o eth0 -j DROP                        # everything else on eth0: blocked
```

**Trade-off to remember:** this blocks *all* non-VPN outbound traffic when the tunnel is
down — not just downloads. DSM's own background stuff (update checks, NTP, etc.) also
pauses during a VPN outage. Acceptable given the 1 GB RAM box's job is mainly "download
things privately," but worth knowing if some other DSM feature seems to hang after a VPN
drop.

- **Tested and confirmed working both ways**: VPN down → outbound requests time out (no
  leak, DNS still resolves). VPN back up → normal traffic resumes via `tun0`.
- **Made persistent** via DSM **Task Scheduler**: Triggered Task → user-defined script →
  runs as `root` → trigger **Boot-up** → same 5 `iptables` lines (without `sudo`, since the
  task already runs as root). Saved and in place.
- Recovery note: none of this touches *inbound* rules, so SSH/DSM access over LAN is never
  at risk even if the outbound rules misbehave. Worst case fix: `sudo iptables -F OUTPUT`
  from a LAN session.

## Media

### Folder structure

Shared folder `Media` on Volym 1, with:

```
Media/
├── Movies/
└── TV/
```

Download Station's **"Temporary folder for incomplete downloads"** is set to a folder
*outside* this tree (so Plex never scans a half-downloaded torrent). Per-download
destination is picked manually as Movies or TV when adding a torrent — no *arr-style
auto-sorting exists here, so this is a deliberate manual step each time.

- **Plex Media Server** — already installed (found pre-existing on this install). Not yet
  configured (library paths, hardware transcoding, remote access).
- **Download Station** — installed, not yet configured (destination folders above still
  need to be wired up in its settings, RSS auto-download not yet set up, BT port not yet
  fixed).
- **No Jellyfin, no *arr stack (Radarr/Sonarr/Prowlarr/Bazarr)** — ruled out by lack of
  Docker + weak ARM~~x86 32-bit hardware. This machine cannot replicate that setup.

### Subtitles — custom script (OpenSubtitles.com API)

Plex's built-in subtitle agent (OpenSubtitles.org) **was removed by Plex** in server
1.40.0.7998 (Feb 2024) — confirmed gone on this install (1.41.5). Sub-Zero (the usual
third-party replacement) is also effectively deprecated. So there is no "click a checkbox
in Plex" option anymore, for anyone, on any NAS — not a DS214play limitation specifically.

Built our own lightweight Bazarr-equivalent instead:

- **Script**: `~ryddmo/scripts/subtitles/subtitle_fetch.py` on the NAS. Pure Python 3
  standard library only (no pip available on this DSM's Python3) — shells out to `curl`
  for all HTTP calls.
- **Config**: `~ryddmo/scripts/subtitles/config.json` (git-ignored equivalent — lives only
  on the NAS, never in this repo). Holds an OpenSubtitles.com API key + account
  username/password + target languages (`sv`, `en`).
- **What it does**: walks `Media/Movies` and `Media/TV`, finds video files with no matching
  `.srt`, computes the OpenSubtitles moviehash (falls back to filename search), downloads
  the best match, saves it as `<basename>.<lang>.srt` next to the video. Works with any
  player, including Plex, since the file just sits alongside the video.
- **Scheduled**: DSM Task Scheduler → **Schemalagd uppgift** (Scheduled Task, *not*
  "Utlöst uppgift"/Triggered Task — that one only offers Boot-up/Shutdown, no recurring
  calendar schedule) → user-defined script → user `ryddmo` (no root needed) → daily 04:00 →
  runs `python3 /var/services/homes/ryddmo/scripts/subtitles/subtitle_fetch.py`.
- **Verified end-to-end**: tested against a dummy `Inception.2010.1080p.mkv` — found a
  match, logged in, downloaded a real, correctly-formatted `.srt`. Confirmed against the
  real folder structure too (0 files found, since no media was in place yet at the time).

**Two gotchas that cost time, worth remembering:**
1. OpenSubtitles' API gateway (Kong) hard-rejects certain `User-Agent` header shapes with
   an opaque `kong-user-agent-block` error, *before* even checking credentials. Fix: the
   header must look like `Name vX.Y.Z` — no hyphens, name not starting lowercase. (A UA of
   `ds214play-subtitle-fetch v1.0` was blocked; `DS214playApp v1.0.0` was not.) Not a
   TLS/client-fingerprint thing — reproduced identically with both `curl` and Python's
   `urllib`.
2. Rate limit is **1 request/second**, and the free-tier daily download quota is small
   (~20/day was seen). The script sleeps ~1.1s after every API call. A large library will
   take several days to fully backfill subtitles — expected, not a bug.
3. Login errors are picky: "invalid username/password" can actually mean *you typed your
   email instead of your OpenSubtitles username* — that's a distinct, explicitly-flagged
   error case from the API itself.

## Open TODOs

1. Wire up Download Station: set the two destination paths above in its settings
   (incomplete-downloads temp folder + confirm Movies/TV as picker destinations), consider
   a fixed BT port, optionally set up RSS auto-download feeds per show/movie.
2. Configure Plex: add `Media/Movies` and `Media/TV` as library folders, verify hardware
   transcoding (CE5335 supports it), decide on remote access.
3. Once real media exists: watch the first few Task Scheduler runs of the subtitle script
   (`~ryddmo/scripts/subtitles/subtitle_fetch.log`) to confirm it behaves the same against
   real files as it did in testing.
4. Harden SSH: disable password auth now that key-based login works.
5. General DSM hardening not yet revisited after the reinstall: 2FA on the admin account,
   confirm no stray default/blank accounts, check whether DSM/QuickConnect is exposed
   externally (should not be, if only used on LAN/VPN).

## Reference: what NOT to expect from this box

For comparison, a friend's separate homelab NAS (`radestad-stack-docs 2.pdf`, kept locally,
not part of this repo) runs a full Docker-based Jellyfin + Radarr/Sonarr/Prowlarr/Bazarr +
qBittorrent-behind-Gluetun stack on much newer hardware (Intel i3, 32 GB RAM, real Docker
support). That level of automation is **not achievable** on the DS214play — this document
exists so we don't keep re-deciding that.
