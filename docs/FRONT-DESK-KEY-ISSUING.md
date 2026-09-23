# Front-Desk Key Issuing — Using the RFID Reader/Writer with LockSDK_Demo.exe

How to use the Mifare card encoder (RFID reader/writer) at the front desk to issue,
read, and cancel guest key cards, using the vendor demo app as the day-to-day tool.
Background on the SDK itself is in [`README.md`](../README.md).

---

## 1. What you're running

**Tool:** `LockSDK_Demo.exe` (C# build)
**Location:** `build/CSharpDemo/CSharpDemo/bin/Debug/LockSDK_Demo.exe`

This is the vendor's sample application, not a limited trial — it calls the same
`TP_*` functions a real PMS integration would use, against the real `LockSDK.dll`
(89,088-byte / MD5 `F6B5BB37` build). Cards it makes are real, working guest cards.

It's paired in that folder with the matching `LockSDK.dll` and support DLLs — don't
copy the `.exe` elsewhere without also copying the DLLs next to it (see README §6 /
§9a on why builds must be deployed as a matched set).

---

## 2. One-time setup

1. **Plug in the encoder** (the USB card reader/writer).
2. **Check `LockInfo.dll` first, before running `LockReg.exe`.** Despite the `.dll`
   extension it's a plain INI file — open it in a text editor. If it already has a
   populated `[ReaderInfo] Data=` blob and a `[CardData] Sn=...` serial, the encoder
   was already registered on this machine at some point, and you can **skip
   `LockReg.exe` entirely** — go straight to step 4.
3. **Only if `LockInfo.dll` is empty/default**, run `LockReg.exe` from the same
   folder to register the encoder and populate that file.

   > ⚠️ **Known issue:** in this package, `LockReg.exe` (the copy in
   > `build/CSharpDemo/CSharpDemo/bin/Debug/`) crashes on launch on Windows 11 —
   > `APPCRASH`, exception `0xC0000005` (access violation) in `KERNEL32.DLL`,
   > before it ever creates a window. Confirmed reproducible (3/3 launches, same
   > fault offset). Compatibility-mode shims (Windows 7 / XP) do **not** fix it —
   > this is a real bug in the old binary, not an environment setting. All
   > required support DLLs are present, so it isn't a missing-dependency issue
   > either. If you hit this and `LockInfo.dll` is genuinely empty, you'll need a
   > working copy of `LockReg.exe` from the vendor, or a different machine/OS to
   > run it on — see README §9a for the identical crash the vendor's own
   > `ReaderReset\` copy has (different cause, same symptom).
4. Confirm Windows sees the reader as a device (COM/USB) before opening the demo —
   if it doesn't show up, this is a driver issue, not an SDK issue.

If cards encode fine but stop opening doors, that's the symptom of the *cached*
authorization data going stale (wrong encoder, re-paired hardware, etc.) — at that
point you're stuck needing a working `LockReg.exe` even if step 2 let you skip it
initially.

---

## 3. Issuing a guest card

1. Open `LockSDK_Demo.exe`.
2. Set the lock/card type via configuration (`TP_Configuration`) — this must happen
   before anything else works. Use the type matching your locks:

   | Value | Type |
   |---|---|
   | 4 | `LT_T5557` (RF57) |
   | 5 | `LT_MF1` (RF50, Mifare Classic) |

   These are the two the demo actually supports.
3. Fill in the guest-card fields:

   | Field | What to enter |
   |---|---|
   | **Lock number** (labeled "room" in some fields) | The **lock number** from the lock-management software's Room Setup screen, e.g. `1.2.8102`. Only use the guest-facing room number if that software has no separate lock numbers configured. |
   | **Check-in time** | Whatever you type here is ignored — the DLL silently forces it to the current time. Don't rely on it. |
   | **Checkout time** | `YYYY-MM-DD hh:mm:ss`, and **add 30 minutes** to the real checkout time (lock clocks drift; this is the vendor's own recommendation). |
   | **Flags** | `0` = normal card, replaces any earlier card for this room. `8` = copy card — does *not* invalidate the previous card (use this if you want more than one valid card for the same room at once, e.g. two guests). `1` = also allow opening the deadbolt. `32` = one-shot, expires after first use. Add values together if you need more than one. |
4. Place the blank/guest card on the encoder and issue.
5. The card's serial is returned/shown — that's `card_snr`, useful if you need to
   look the card up later.

### Important: only the newest card works

Within one room, a card issued later invalidates an earlier one automatically
(unless you used the copy flag above). If a guest says their key stopped working,
the most likely cause is that a second card was issued after theirs — not a broken
card. Re-issuing fixes it. Swiping an authorization or time-sync card at the lock
also revives previously-superseded cards, if you ever need to do that.

---

## 4. Reading a card back

Use the demo's "read" function (`TP_ReadGuestCardEx`) to check what's actually
encoded on a card — lock number, checkin/checkout times, flags. Useful for
troubleshooting a guest complaint ("my key doesn't work") before re-issuing.

---

## 5. Cancelling a card

Use the demo's cancel function (`TP_CancelCard`) to invalidate a card immediately —
e.g. a guest reports theirs lost. This doesn't require the card itself to be present
at the encoder in the `Ex2` variant (there's a wait-timeout version); check which
button the demo exposes.

---

## 6. Checking the issue log

**Tool:** `RMCRecords.exe`, same folder.

Run it to see "Issue Card Records" — a view over `cardRecord.ini`, where each entry
is marked `remark=new` (first card) or `remark=copy` (a copy-flag card). Useful for
an audit trail of who got a card and when, though it doesn't record which staff
member issued it.

---

## 6a. C# demo marshaling bug (real, but not the blocker — see §6b)

**Symptom:** click the config/connect button (or "Make Card") with the reader
plugged in → no error dialog, app is briefly unresponsive, then the process dies.
Windows Event Log shows `APPCRASH`, `0xC0000005` (access violation) in `PubFuns.dll`,
and `.NET Runtime` logs `System.AccessViolationException` inside `TP_Configuration`
or `TP_MakeGuestCard`.

**Cause found:** a bug in the shipped C# demo source
(`build/CSharpDemo/CSharpDemo/IDD102.cs`). The native `LockSDK.dll` exports both
functions taking a 32-bit `int` (per `LockSDK.h`), but the demo's `[DllImport]`
declarations wrongly used `Int16` (16-bit) for the `LockType` / `iflags`
parameters. On a `__stdcall` call this pushes the wrong number of bytes onto the
native stack, corrupting it.

**Fix (already applied in this checkout):** changed both declarations from `Int16`
to `int` in `IDD102.cs`, and rebuilt with MSBuild:

```bash
"C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe" \
  "build\CSharpDemo\CSharpDemo\CSharpDemo.csproj" //p:Configuration=Debug //p:Platform=AnyCPU
```

This overwrites `bin/Debug/LockSDK_Demo.exe` with a corrected build. It's a
legitimate bug worth keeping fixed, and worth re-applying if you ever pull a fresh
copy of the vendor package — **but it turned out not to be what was blocking us.**
After rebuilding, the exact same crash still happened, at the identical fault
offset in `PubFuns.dll`. See §6b for the real cause.

## 6b. Root cause: `LockSDK.dll` / `PubFuns.dll` don't work on Windows 11

**Finding:** with the reader physically connected, clicking connect/read-card
crashes the app the moment it actually touches the hardware — and this happens
**identically across independently-written demos**:

| Demo | Crash |
|---|---|
| C# (`LockSDK_Demo.exe`, CSharpDemo) | `0xC0000005` access violation in `PubFuns.dll`, same fault offset before and after fixing the §6a marshaling bug |
| VB6 (`LockSDK_Demo.exe`, `build/run/VB6/`) | `0xC0000005` at a **null address** (jump through a null/garbage function pointer), then a fatal `0xC00000FF` in `ntdll.dll` |

Two demos, two languages, two independent codebases, both written against the
same `LockSDK.dll`/`PubFuns.dll`/USB-transport-DLL chain — both die at the same
step. That rules out a demo-side bug. The common factor is the native vendor DLLs
themselves, which date to roughly 2013 and were never updated for modern Windows.
This is consistent with a legacy `GetVersionEx()`-style OS-version branch inside
`PubFuns.dll` picking a bad code path (or an unresolved function pointer) on
Windows 11, since the same *class* of crash (jump into invalid/null code) shows up
both times.

**This is not fixable from this checkout** — `PubFuns.dll` and the USB transport
DLLs are closed vendor binaries with no source available here.

**What Windows does confirm works:** the encoder/reader itself is correctly
detected at the OS level — it shows up as a working HID device
(`VID_5458&PID_0002`, "AISINOCHIP", `Status: OK`, no driver errors). So this is
purely an application-layer incompatibility, not a cabling/driver problem.

**Next steps, not yet tried:**
1. Test this SDK on an older Windows version/VM (Windows 7 or 8.1 is the most
   likely match for code this age) — confirms the theory and gives a working
   fallback environment.
2. Contact the vendor for a Windows 11–compatible build. Mention the specific
   symptom (crash in `PubFuns.dll` / null function pointer on connect, exact fault
   offsets logged in Windows Event Viewer under Application) — it's specific
   enough that vendor support may recognize it immediately.
3. Check whether Aisino (`VID_5458`, the reader's actual chip vendor) ships its
   own current SDK independent of this lock vendor's wrapper — would mean
   reimplementing the guest-card logic against a different, maintained API rather
   than `LockSDK.dll`.

---

## 7. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `NO_RW_MACHINE` (-2) error | Encoder not detected — check USB/driver, not the SDK |
| Card encodes fine but lock rejects it at the door | Encoder's authorization data is stale/wrong — close the app, place the *authorization card* on the encoder, reopen (it re-reads automatically), or re-run `LockReg.exe` |
| A previously-working key suddenly stops opening | A newer card was issued for that room (see §3) — check issue times in `RMCRecords.exe`, re-issue if needed |
| Lock beeps but door doesn't open | Count the beeps at the lock: 1=time error, 2=deadbolt engaged, 3=wrong building/floor/lock number, 4=card reported lost, 5=card password error, 6=client code error, 7=lock has no room number set yet |
| App UI shows garbled/mojibake text | Cosmetic only (GBK/ANSI codepage mismatch) — see README §10 if you want to fix it, doesn't affect card issuing |

---

## 8. Out of scope for now

This covers using the demo app directly for manual front-desk issuing. If you later
need this wired into a reservation system (auto-pull room/checkout dates, per-staff
audit trail, receipt printing), that's a separate integration effort — see
[`docs/PMS-INTEGRATION-PLAN.md`](PMS-INTEGRATION-PLAN.md).
