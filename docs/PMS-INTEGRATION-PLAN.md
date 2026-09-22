# Plan: LockSDK ↔ PMS bridge over gRPC / HTTPS

Goal: let a **cloud-hosted PMS** issue, read and cancel guest cards on a front-desk
encoder, instead of linking `LockSDK.dll` into the PMS itself.

Section references (§n) point to [README.md](../README.md).

### Decisions taken

| # | Question | Decision |
|---|---|---|
| 1 | Where does the PMS run? | **Cloud** → the bridge dials out; no inbound ports at the hotel |
| 2 | Encoder busy? | **Queue** (bounded FIFO per encoder) |
| 3 | Room → lock-number table | **PMS owns it** and sends `lock_number` on every request |
| 4 | Bridge stack | **.NET 8** (alternatives compared in §9) |

---

## 1. Constraints that drive the design

| Constraint (from README) | Design consequence |
|---|---|
| DLL is **x86-only**, `__stdcall`, `char*` GBK (§1) | Native code lives in a 32-bit process; all strings marshalled as bytes via codepage 936 |
| One physical USB encoder per PC; DLL almost certainly not thread-safe (unverified) | Every SDK call goes through **one worker thread**, one operation at a time, fed by a queue |
| Card ops block for a human (`waitMs`, "place card") | Long-running ops; API streams progress, not a quick request/response |
| A hung or crashing native call cannot be cancelled in-process; vendor tools do crash (`0xC0000005`, §9a) | DLL runs in a **separate child process** that the service can kill and restart |
| DLL writes state next to itself (`cardRecord.ini`, `LockInfo.dll`, §7) and must ship as a matched set (§9a) | Worker gets its own writable install folder holding a pinned, hashed DLL set |
| Supersession, checkout +30 min, fixed timestamp format, check-in forced to now (§7a, §8) | These rules live in **one place** (the bridge), not scattered across PMS clients |
| Port contention with the vendor's lock-management software (`-11 PORT_IN_USED`) | Surface this as a distinct, actionable status |

## 2. Architecture

```
 Cloud PMS
   ├─ BridgeTunnel gRPC endpoint  (accepts bridge connections, routes commands)
   └─ Encoder API for PMS UI/backend (gRPC + HTTPS/JSON, same contract)
        ▲
        │  outbound HTTP/2 + mTLS, long-lived bidi stream (bridge dials out)
        │  hotel firewall only needs outbound 443
 ┌──────┴──────────────────── Front-desk Windows PC ───────────────────────────┐
 │  EncoderBridge.Service  (.NET 8, Windows Service, x64)                      │
 │   • tunnel client + reconnect, auth, audit log, idempotency, job queue      │
 │   • supervises the worker; kills/restarts it on hang or crash               │
 │        │  local gRPC over named pipe                                        │
 │        ▼                                                                    │
 │  EncoderBridge.Worker   (.NET 8, **win-x86**, one process)                   │
 │   • single dedicated thread → P/Invoke → LockSDK.dll + support DLLs          │
 │        │ USB                                                                │
 │        ▼                                                                    │
 │    Card encoder                                                             │
 └─────────────────────────────────────────────────────────────────────────────┘
```

### Cloud connectivity

- The bridge opens `BridgeTunnel.Connect` to the PMS on start and keeps it open.
  The PMS pushes commands down the stream; the bridge streams events back.
- **Keepalive:** HTTP/2 PING every 30 s plus an application heartbeat every 30 s,
  so the PMS knows within ~1 min if an encoder goes offline. Hotel proxies and NAT
  drop idle connections, so this is required.
- **Reconnect:** exponential backoff with jitter (1 s → 60 s cap). On reconnect the
  bridge re-sends `Hello` with its queue state and any job results the PMS has not
  acknowledged (see §4.5).
- **Proxy support:** honour the system/`HTTPS_PROXY` proxy. Some hotel networks only
  allow outbound traffic through one. Test that HTTP/2 survives the proxy. If it
  doesn't, fall back to gRPC-Web or WebSocket (Phase 0 check at the pilot site).
- **Routing:** the PMS keeps `encoder_id → live tunnel` in a registry. With several
  PMS instances, route commands through a shared bus (Redis pub/sub or similar) to
  whichever instance holds that tunnel.

### Why gRPC *and* HTTPS

Define the contract once in `.proto`. On the **PMS side**, serve native gRPC and
enable JSON transcoding (`google.api.http` annotations) so web or other clients can
call the same operations over HTTPS/JSON. The bridge ↔ PMS tunnel itself is gRPC only.

## 3. API contract (first draft)

Expose only the `TP_*` guest-card surface. Do **not** expose `LS_*` (master, emergency,
clear, factory cards…) or raw Mifare block writes remotely. Those cards work as master
keys and belong in the vendor's own software.

```proto
syntax = "proto3";
package encoderbridge.v1;
import "google/protobuf/timestamp.proto";
import "google/api/annotations.proto";

// ---- Served by the PMS to its own frontend/backends --------------------------
service Encoder {
  rpc GetStatus(GetStatusRequest) returns (EncoderStatus) {
    option (google.api.http) = { get: "/v1/encoders/{encoder_id}/status" };
  }
  rpc IssueGuestCard(IssueGuestCardRequest) returns (stream CardOperationEvent) {
    option (google.api.http) = { post: "/v1/encoders/{encoder_id}/guest-cards" body: "*" };
  }
  rpc ReadCard(ReadCardRequest) returns (stream CardOperationEvent) {
    option (google.api.http) = { post: "/v1/encoders/{encoder_id}/cards:read" body: "*" };
  }
  rpc CancelCard(CancelCardRequest) returns (stream CardOperationEvent) {
    option (google.api.http) = { post: "/v1/encoders/{encoder_id}/cards:cancel" body: "*" };
  }
  rpc AbortJob(AbortJobRequest) returns (AbortJobResponse) {
    option (google.api.http) = { post: "/v1/encoders/{encoder_id}/jobs/{request_id}:abort" };
  }
}

// ---- Served by the PMS; the bridge is the client and dials out ---------------
service BridgeTunnel {
  rpc Connect(stream BridgeToPms) returns (stream PmsToBridge);
}

message BridgeToPms {
  oneof msg {
    Hello              hello     = 1;  // first message: encoder_id, versions, queue state
    Heartbeat          heartbeat = 2;
    JobEvent           job_event = 3;  // request_id + CardOperationEvent
    EncoderStatus      status    = 4;
  }
}

message PmsToBridge {
  oneof msg {
    IssueGuestCardRequest issue  = 1;
    ReadCardRequest       read   = 2;
    CancelCardRequest     cancel = 3;
    AbortJobRequest       abort  = 4;
    JobAck                ack    = 5;  // PMS has durably stored a job's terminal event
  }
}

message IssueGuestCardRequest {
  string encoder_id  = 1;
  string request_id  = 2;   // idempotency key, required
  string lock_number = 3;   // required, from the PMS room table, e.g. "1.2.8102"
  google.protobuf.Timestamp checkout = 4;  // real checkout, UTC; bridge adds grace
  bool allow_deadbolt = 5;  // iflags 1
  bool additional_key = 6;  // iflags 8 — don't supersede existing cards
  bool single_use     = 7;  // iflags 32
  int32 wait_seconds  = 8;  // card-placement timeout → waitMs
  string operator_id  = 9;  // front-desk user, for the audit log
  google.protobuf.Timestamp queue_deadline = 10; // give up if not started by then
}

message CardOperationEvent {
  oneof event {
    Queued         queued   = 1;  // position in queue; re-sent as it moves
    WaitingForCard waiting  = 2;  // "place card on encoder"
    CardResult     result   = 3;  // terminal: success
    CardError      error    = 4;  // terminal: failure
  }
}

message Queued { int32 position = 1; }  // 0 = next to run

message CardResult {
  string card_serial = 1;
  string lock_number = 2;
  google.protobuf.Timestamp checkin  = 3;  // as actually encoded (forced to now)
  google.protobuf.Timestamp checkout = 4;  // as actually encoded (incl. grace)
  uint32 flags = 5;
}

message CardError {
  int32  sdk_code  = 1;  // raw LockSDK code, e.g. -1; 0 for bridge-level errors
  string sdk_name  = 2;  // "NO_CARD"
  string message   = 3;
  bool   retryable = 4;
}
```

`CardResult` echoes what was *actually* written, because the DLL silently changes
check-in (§8) and the bridge adds grace to checkout. The PMS stores these, not what
it asked for.

### SDK error → gRPC status mapping

| SDK code | gRPC status | Retry? |
|---|---|---|
| `-1 NO_CARD` | `DEADLINE_EXCEEDED` | yes (operator places card) |
| `-2 NO_RW_MACHINE`, `-6 PORT_NOT_OPEN`, `-12 COMM_ERROR` | `UNAVAILABLE` | after worker restart |
| `-11 PORT_IN_USED` | `UNAVAILABLE` + "close lock-management software" | yes |
| `-3`, `-4`, `-32` card problems | `FAILED_PRECONDITION` | with another card |
| `-8 INVALID_PARAMETER`, `-25..-27` bad building/floor/room | `INVALID_ARGUMENT` | no — fix the PMS room table |
| `-20 ERR_CLIENT`, `-29`, `-30` authorization | `FAILED_PRECONDITION` + "run LockReg / present authorization card" | no |
| queue full | `RESOURCE_EXHAUSTED` | yes, later |
| `queue_deadline` passed before start | `DEADLINE_EXCEEDED` | yes |
| encoder offline (no tunnel) | `UNAVAILABLE` (returned by PMS, no queueing in the cloud) | yes |
| worker crash / hang | `ABORTED` | yes, after restart |

## 4. Business rules

### 4.1 Lock numbers (PMS-owned)
The PMS stores `room → lock_number`, imported from the lock software's
*Room Setup → Room Info* screen (§7a), and sends `lock_number` on every request.
The bridge does **format validation only**. It must allow the legacy formats listed
in §7a, not just `1.2.8203`:
`^[0-9A-Za-z]+(\.[0-9A-Za-z]+)*$`, ≤ 19 bytes (the output buffer is 20 bytes).
`-25/-26/-27` errors from the DLL are reported to the PMS as "room table is wrong".

### 4.2 Time
- Add a configurable checkout grace (default **30 min**, §7a).
- Convert UTC → the property's time zone (IANA ID, set per bridge at enrolment),
  then format with `InvariantCulture` as `yyyy-MM-dd HH:mm:ss`. Never use the PC's
  regional format.
- The PC clock must be NTP-synced, because the DLL stamps check-in from it. The
  bridge reports its clock offset in `Heartbeat`, and the PMS alerts if it drifts
  more than 2 min.

### 4.3 Supersession
Default new cards to *replace* (iflags 0). "Extra key for the same stay" →
`additional_key = true` (iflags 8). PMS developers must be told that issuing a plain
card invalidates earlier ones.

### 4.4 Queue (per encoder)
- **Where:** in the bridge service, not the cloud. The cloud rejects with
  `UNAVAILABLE` while the encoder is offline and does not buffer commands. Encoding a
  card minutes after the clerk walked away is worse than failing fast.
- **Bounded:** max 10 jobs (configurable). Beyond that → `RESOURCE_EXHAUSTED`.
- **FIFO**, one job running at a time. `Queued{position}` is re-sent whenever it changes.
- **Per-job `queue_deadline`** (default now + 2 min). A job not *started* by then fails
  without touching the encoder.
- **Abort:** `AbortJob` removes a queued job. A running job cannot be aborted cleanly
  inside the DLL. Treat abort of a running job as "kill worker and restart", and
  report the outcome as *unknown* (the card may or may not be encoded).
- **Crash recovery:** the queue is in-memory. On service restart, queued jobs fail
  with `ABORTED`, and the PMS retries them with the same `request_id` if the clerk
  still wants them.
- **Physical reality:** one encoder, one card slot. The queue mainly absorbs
  double-clicks and two clerks sharing a desk. The UI should show queue position so a
  clerk doesn't place a card for someone else's job.

### 4.5 Idempotency and delivery
- `request_id → terminal result` stored in SQLite on the bridge (retain 7 days).
  A duplicate request returns the stored result or joins the running/queued job, and
  never encodes twice.
- Terminal events are kept until the PMS sends `JobAck`, and re-sent after a
  reconnect. This covers "card encoded, then the network dropped before the PMS heard".

## 5. Native interop layer (worker)

- Target `net8.0-windows`, `RuntimeIdentifier=win-x86`, `PlatformTarget=x86`.
- `[DllImport("LockSDK.dll", CallingConvention = CallingConvention.StdCall)]` with
  **`byte[]`** for every `char*`. Encode/decode with `Encoding.GetEncoding(936)`
  after `Encoding.RegisterProvider(CodePagesEncodingProvider.Instance)`.
  Never use `string`/`StringBuilder` with default ANSI marshalling (§10).
- Pre-allocate output buffers generously (64 bytes rather than the 20/30 minimum), and
  trim at the first `\0`.
- Use the `Ex2` variants, which take `waitMs`. They exist only in the 89,088-byte
  build, so verify the DLL hash at startup and refuse to run on a mismatch.
- All calls on one dedicated thread (STA if Phase 0 shows the DLL needs it), including
  `TP_Configuration`, which runs once at worker start.
- Worker ↔ service: gRPC over a named pipe, ACL'd to the service account.
- Service watchdog: if an op exceeds `wait_seconds + margin`, kill the worker, report
  `ABORTED`, restart it.

## 6. Security

- **Transport:** TLS 1.2+ outbound only; **mTLS** on the tunnel.
- **Enrolment:** a PMS admin creates the encoder in the PMS and gets a one-time code.
  The installer uses the code to fetch a client certificate bound to
  `(property_id, encoder_id)`. The cert private key goes in the Windows cert store
  (machine, non-exportable). Rotate before expiry automatically over the tunnel.
- **Authorization:** issuing a card opens a door, so treat it as privileged. The PMS
  checks the clerk's permission before sending a command. The tunnel identity
  scopes every command to one property, so one hotel's tenant cannot reach another's
  encoder.
- **Audit:** append-only log of every operation (who, lock number, flags, serial,
  result), streamed to the PMS. The DLL's own `cardRecord.ini` is not a sufficient
  audit trail.
- **Surface:** no `LS_*`, no raw Mifare writes over the network (§3). The bridge
  opens **no listening ports**.

## 7. Delivery phases

### Phase 0: Hardware + network spike (≈ 3 days)

Test with a real encoder and a real lock, using a throwaway x86 console app. (A
32-bit Python + `ctypes.WinDLL` script is the fastest way to poke the DLL, see §9.)

- [ ] Is the DLL thread-affine? (call from a second thread after `TP_Configuration`)
- [ ] Is it reentrant / safe to call `TP_Configuration` more than once?
- [ ] Does anything pop a modal dialog? (would hang a Windows Service in session 0)
- [ ] Does it work from a service account / session 0 at all? USB driver access?
- [ ] Behaviour on USB unplug/replug mid-session: recoverable without restart?
- [ ] Does `waitMs` actually bound the call? What happens with no card?
- [ ] Which files does it write, and where? (needs write ACL on the install folder)
- [ ] Encode → door opens; confirm checkout grace, supersession and the flags end to end
- [ ] Does it coexist with the vendor lock-management software on the same PC?
- [ ] At a pilot hotel: does an outbound HTTP/2 stream survive their firewall/proxy for 24 h?

Exit: a one-page findings note. If the DLL can't run in session 0, the worker becomes a
per-user tray app started at logon, supervised the same way.

### Phase 1: Worker + interop (≈ 1 week)
- P/Invoke layer, GBK marshalling, error-code enum, DLL hash check.
- `IEncoder` interface + `FakeEncoder` (scriptable: no card, busy, crash, hang) for tests.
- Local CLI to issue/read/cancel via the worker.

### Phase 2: Bridge service (≈ 1.5 weeks)
- Tunnel client: connect, heartbeat, reconnect/backoff, proxy support.
- Job queue, idempotency store, `JobAck` redelivery, watchdog.
- Time handling, grace, lock-number validation, audit log.
- Windows Service + MSI installer bundling the pinned DLL set and `LockReg.exe` (§7a).

### Phase 3: PMS side (≈ 1.5 weeks)
- `BridgeTunnel` endpoint, encoder registry, cross-instance routing, enrolment flow.
- `Encoder` API (gRPC + JSON transcoding) for the PMS frontend.
- Room table: add `lock_number` column and an import from the lock software's export.
- Front-desk UX: queue position → "place card on encoder" → result. Clear messages for
  each `CardError`, and a "new key" vs "extra key" choice.
- Persist `CardResult` against the reservation; encoder online/offline indicator.

### Phase 4: Hardening & rollout
- Cert rotation, alerting (encoder offline, clock drift, repeated `ABORTED`).
- Auto-update of the bridge (not of the vendor DLL set, which is pinned).
- Pilot at one property. Test matrix: each lock type in use (4 = RF57, 5 = RF50),
  unplugged encoder, no card, wrong card, lock software open, clock skew, queue full,
  queue deadline, network drop mid-encode, worker crash mid-encode, proxy restart.

## 8. Out of scope (v1)

`LS_*` card types, member/Mifare cards, multiple encoders on one PC, encoder firmware
or registration automation (keep using `LockReg.exe`), on-prem PMS mode.

---

## 9. Bridge tech-stack options

**Only the worker has to be 32-bit.** The service (tunnel, queue, auth) can be any
64-bit stack, and the two talk over a named pipe. So the choice is really two
choices, and mixing is fine.

### Requirements any stack must meet

| Need | Why |
|---|---|
| 32-bit Windows build + `stdcall` FFI | the DLL (§1) |
| GBK / codepage 936 encoding | `char*` strings (§10) |
| Mature gRPC client with bidi streaming + mTLS | the tunnel |
| Runs as a Windows Service | unattended front-desk PCs |
| Single, simple installer | hotel IT is minimal |

### Comparison

| Stack | 32-bit FFI | gRPC | Windows service | Deploy | Fit |
|---|---|---|---|---|---|
| **.NET 8 (chosen)** | `DllImport` + `StdCall`; `win-x86` RID | Grpc.Net, first-class | `UseWindowsService()` | self-contained or single-file | ★★★★★ vendor C# demo is a working P/Invoke reference |
| **Go** | `GOARCH=386`; `syscall.NewLazyDLL(...).Call()` uses stdcall natively, **no cgo** | grpc-go, first-class | `golang.org/x/sys/windows/svc` | one static `.exe`, no runtime | ★★★★☆ easiest deployment; GBK via `x/text/encoding/simplifiedchinese` |
| **Rust** | `i686-pc-windows-msvc`; `extern "system"` | tonic, mature | `windows-service` crate | one `.exe` | ★★★★☆ strongest reliability; GBK via `encoding_rs`; slower to write, smaller hiring pool |
| **Node.js / TypeScript** | 32-bit Node + `koffi` (supports `__stdcall`) | `@grpc/grpc-js` | via `node-windows`/NSSM wrapper | runtime + node_modules | ★★☆☆☆ works, but needs 32-bit Node and a service wrapper |
| **Python** | 32-bit Python + `ctypes.WinDLL` (stdcall) | `grpcio`, check 32-bit wheel availability | `pywin32` service or NSSM | interpreter + deps (PyInstaller) | ★★☆☆☆ **great for the Phase 0 spike**, weak for production |
| **C/C++ worker only** | native | (worker needs none) | n/a | tiny `.exe` | ★★★☆☆ as a *worker* behind any service; only if the team is fluent in C++ |
| Java | needs a 32-bit JRE (scarce) + JNA | grpc-java | procrun/WinSW | JRE bundle | ★☆☆☆☆ 32-bit JVMs are largely unsupported now |

### Recommended combinations

1. **.NET 8 service + .NET 8 x86 worker** (chosen): one language, one toolchain,
   the vendor's C# demo to crib from, and your team's choice.
2. **Go service + Go 386 worker**: best if you want a single dependency-free binary
   per process and the PMS team already writes Go. Go's native Windows syscalls use
   stdcall, so the 32-bit worker needs no C toolchain at all.
3. **Any service + minimal C++ x86 worker**: when the service must match the PMS's
   language (e.g. Rust or Node) but you want the smallest possible native layer.
   The worker then only does "receive command on a pipe → call DLL → reply".

Whatever the stack, use **32-bit Python + `ctypes`** for the Phase 0 spike. You can
call `TP_Configuration` and `TP_MakeGuestCardEx2` interactively in minutes, which is
the fastest way to answer the unknowns in §7.
