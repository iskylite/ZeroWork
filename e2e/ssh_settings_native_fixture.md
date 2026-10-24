SSH settings native supplement — prepared, **not executed**.

The root owns the only native window. This fixture starts no UI and sends no
RPC. It extends `shared_forward.py`'s existing localhost peer lifecycle.
`ssh_auth_loopback.py` and `ssh_reconnect_loopback.py` remain headless evidence;
their results cannot replace the main-app run below.

1. Root starts the fixture in a fresh directory:

   ```sh
   python3 e2e/ssh_settings_native_fixture.py --serve --out /tmp/zw-settings-peer-UNIQUE
   ```

   Without `--serve`, it only writes a `prepared_not_run` plan. `ready.json`
   identifies generated keys, localhost ports and fixture password. Copy its
   `hosts.toml` only into a new, root-owned isolated app data directory before
   launching that app with the existing launcher. Do not replace a real host
   registry or modify another live window. The three hosts intentionally omit
   per-host TERM/compression/keepalive overrides.

2. Reuse the existing settings runner against that exact app's `live.json`:

   ```sh
   node e2e/settings_remaining_native.ts --live LIVE_JSON --out EMPTY_CONTROL_DIR --fields ssh.keepalive_sec,ssh.connect_timeout_sec,ssh.term,ssh.compression --keep-target yes
   ```

   This runner changes controls and saves actual config; it uses synthetic
   Harness input. Its `report.json` supplies before/target/saved values. Root
   should inspect the retained targets before connecting. For reconnect tests,
   stage `auto_reconnect=true`, `reconnect_max=3`,
   `reconnect_backoff=[1,2,3,4,5]`, `buffer_input=true` through actual controls
   first; the generic runner toggles booleans and skips disabled dependencies,
   so do not assume a field list alone produces this combination.

3. Connect `Owned settings normal` through the ordinary sidebar. Trust only
   that generated fingerprint. Enter `shared-secret` if requested. Capture the
   native owner/session, saved values and resulting terminal. `state.json`
   records actual PTY TERM, both negotiated compression directions and global
   requests with monotonic timestamps. Wait at least two saved keepalive
   intervals. Match `keepalive@libssh2.org`; do not count unrelated global
   requests as keepalives. Repeat a new connection with compression/keepalive
   opposite settings if that branch is needed. An existing connection is the
   frozen-policy control; retain its connection index before each Save.

4. Connect `Owned settings timeout`. It accepts TCP and consumes the client
   banner without returning an SSH banner. `tcp_accept` and
   `stalled_client_closed` bound the real handshake attempt. Correlate with
   native failure timing and the saved timeout; multiple automatic retries
   must be treated separately. Fixture shutdown closure is not timeout proof.

5. Trigger an owned drop by atomically replacing `command.json` with:

   ```json
   {"peer":"normal","action":"drop","next_mode":"reject"}
   ```

   Each subsequent TCP accept has a timestamp. Count retries relative to the
   original connection and allow ordinary scheduling/network tolerance when
   comparing saved backoff. After max retries, observe a full extra expected
   interval to prove there is no extra attempt. For successful replay, use a
   fresh connected session, drop with `next_mode="stall"`, type exactly
   `ZW_SETTINGS_BUFFER_ONCE` during the disconnected native state, then set:

   ```json
   {"peer":"normal","action":"mode","mode":"normal"}
   ```

   A stalled current attempt must expire before the next accepted connection
   uses normal mode. The fixture emits real OSC 133 prompt markers. Verify
   the marker count is one on the new connection and zero on unrelated owners.
   Repeat with saved `buffer_input=false` and expect zero. Save
   `auto_reconnect=false` before creating another connection, drop it and
   observe beyond the prior backoff interval; expect no new TCP accepts.

6. Save `otp_modal`/`totp_autofill` targets, then connect `Owned settings otp`.
   It advertises only keyboard-interactive with the recognized, non-echo
   `Verification code:` prompt. Before submit, verify no `otp_response` event;
   capture modal or protected-form presentation and request/owner. Submit an
   explicit six-digit fixture response; only shape/count are recorded.
   The fixture intentionally does not create or persist a TOTP seed. Testing
   actual autofill requires a separately approved, exclusively owned seeded
   host; without it, leave `totp_autofill` consumption unverified. Never put a
   seed, full OTP, or unredacted answer tree into evidence. A masked native
   screenshot alone cannot prove that manual edits were preserved.

7. SOCKS defaults reuse `multihop_socks_native_fixture.py`; do not duplicate
   existing payload/path evidence. This new fixture rejects forwarding.
   Restore settings using the existing runner's `--restore-from REPORT_JSON`
   in a fresh output directory, close the exact test sessions and inspect
   `state.json` before writing `finish`. Fixture then writes
   `peer-report.json` before cleanup. Its `native_accepted` is always false:
   root must map protocol records to actual native controls/owners and review
   screenshots before updating the audit.

Preparation validation: Python AST syntax only. No fixture process, SSH
connection, main app, window, Harness RPC or native acceptance was run.
