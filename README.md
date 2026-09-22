# LockSDK V4.7 — Developer Reference

Hotel door-lock / Mifare card-encoding SDK. Release package `LockSDK V4.7发布_20210913`
(dated 2021-09-13; the DLL's own version string is `210913`).

This document was reconstructed from the shipped headers, DLL exports and demo sources.
It is not vendor-authored. Items marked **(inferred)** are conclusions drawn from file
contents rather than documented statements.

---

## 1. Quick facts

| | |
|---|---|
| Core library | `LockSDK.dll` (+ `LockSDK.lib`, `LockSDK.h`) |
| Architecture | **x86 (32-bit) only** — confirmed via PE header |
| Calling convention | `__stdcall`, C linkage (`extern "C"`) |
| String types | `char*` (ANSI/**GBK**), caller-allocated output buffers |
| Return values | `int` error code — `1` = success, negatives = errors |
| Text encoding | GBK / codepage 936 throughout (headers, INI files, sources) |

> **32-bit only.** Any host application must be built for x86. An AnyCPU .NET
> assembly must have `Prefer 32-bit` enabled or be forced to x86, or the P/Invoke
> will fail with a BadImageFormatException.

---

## 2. Two API families

`LockSDK.dll` exports **84 functions** in two distinct layers:

### `TP_*` — high-level API (15 functions)

Documented in **`LockSDK.h`**. This is the intended integration surface for hotel
property-management software: configure, issue a guest card, read it back, cancel it.
Start here.

### `LS_*` — low-level API (69 functions)

Declared in **`LockDll.h`** (665 lines). Full card-system control: port management,
authorization codes, and every card type the lock system supports (staff, chief,
emergency, building, floor, lost/unlost, clear, install, elevator, networking,
data-export, checkout, factory, test…). Many entries carry no description comment
in the header.

---

## 3. `TP_*` API reference

### Lifecycle

```c
int __stdcall TP_Configuration(int lock_type);
```
Initialises the library: selects the lock/card type and connects the card encoder.
**Must be called before anything else.** See `LOCK_TYPE` below.

### Guest cards

```c
int __stdcall TP_MakeGuestCardEx (char *card_snr, char *room_no,
                                  char *checkin_time, char *checkout_time,
                                  int iflags);
int __stdcall TP_MakeGuestCardEx2(char *card_snr, char *room_no,
                                  char *checkin_time, char *checkout_time,
                                  int iflags, int waitMs);
```

| Parameter | Direction | Notes |
|---|---|---|
| `card_snr` | out | Card serial. **Pre-allocate ≥ 20 bytes.** |
| `room_no` | in | **Lock number**, not room number — e.g. `"1.2.8102"` |
| `checkin_time` | in | Reserved; forced to *current time* by the DLL (see §8) |
| `checkout_time` | in | `"YYYY-MM-DD hh:mm:ss"` |
| `iflags` | in | Option bitmask, see below |
| `waitMs` | in | `Ex2` only: how long to wait for card placement, in ms |

`iflags` values (additive; `0` = plain replacing, non-expiring-on-use card):

| Value | Meaning |
|---|---|
| `1` | Allow opening the deadbolt |
| `8` | Copy card — does *not* supersede the previous card (multiple cards per room) |
| `32` | One-shot — card expires after a single door opening |
| `128` | Enforce check-in time (lock refuses if card check-in > lock clock). Not recommended by the vendor |

> `room_no` expects the **lock number** as configured in the lock-management
> software's room setup screen. Only fall back to the room number if the management
> software has no lock numbers.

```c
int __stdcall TP_ReadGuestCardEx (char *card_snr, char *room_no,
                                  char *checkin_time, char *checkout_time,
                                  int *iFlags);
int __stdcall TP_ReadGuestCardEx2(char *card_snr, char *room_no,
                                  char *checkin_time, char *checkout_time,
                                  int *iFlags, int waitMs);
```
Reads a guest card. Pre-allocate ≥ 20 bytes for `card_snr` / `room_no` and
≥ 30 bytes for each timestamp.

```c
int __stdcall TP_CancelCard   (char *card_snr);
int __stdcall TP_CancelCardEx2(char *card_snr, int waitMs);
int __stdcall TP_GetCardSnr   (char *card_snr);   // read unique card serial
```

### Mifare / membership-card access

For hotel software managing its own member cards. **Call order matters:**
`TP_M1Active` → `TP_M1AuthKey` → read/write/set-key.

```c
int __stdcall TP_M1Active   (char *card_snr);              // activate, read serial (4 bytes / 8 chars)
int __stdcall TP_M1AuthKey  (char *keyA, UINT sector_no);  // sector 1–40; default key "ffffffffffff"
int __stdcall TP_M1SetKeyA  (char *newKeyA, UINT sector_no); // 6 bytes as 12 chars
int __stdcall TP_M1ReadBlock (UINT block_no, char *data);  // 16 bytes as 32 chars
int __stdcall TP_M1WriteBlock(UINT block_no, char *data);
```
Block numbering: `sector * 4 + block_within_sector`. Sector 9 exposes blocks 36, 37, 38
(block 3 of each sector holds the keys and is not freely writable).

---

## 4. Error codes

From `Defines.h` (`enum ERROR_TYPE`). `LockSDK.h` ships a shorter subset.

| Code | Name | Meaning |
|---|---|---|
| `1` | `OPR_OK` | Success |
| `-1` | `NO_CARD` | No card detected |
| `-2` | `NO_RW_MACHINE` | No card reader detected |
| `-3` | `INVALID_CARD` | Invalid card |
| `-4` | `CARD_TYPE_ERROR` | Wrong card type |
| `-5` | `RDWR_ERROR` | Read/write error |
| `-6` | `PORT_NOT_OPEN` | Port not open |
| `-7` | `END_OF_DATA_CARD` | End of data card |
| `-8` | `INVALID_PARAMETER` | Invalid parameter |
| `-9` | `INVALID_OPR` | Invalid operation |
| `-10` | `OTHER_ERROR` | Other error |
| `-11` | `PORT_IN_USED` | Port already in use |
| `-12` | `COMM_ERROR` | Communication error |
| `-13` | `ERR_RECOVER_CLIENT` | Authorization code recovered from encoder (success case) |
| `-20` | `ERR_CLIENT` | Client/customer code error |
| `-21` | `ERR_LOST` | Card reported lost |
| `-22` | `ERR_TIME_INVALID` | Invalid time |
| `-23` | `ERR_TIME_STOPED` | Guest card was superseded |
| `-24` | `ERR_BACK_LOCKED` | Deadbolt engaged |
| `-25` | `ERR_BUILDING` | Bad building number |
| `-26` | `ERR_FLOOR` | Bad floor number |
| `-27` | `ERR_ROOM` | Bad room number |
| `-28` | `ERR_LOW_BAT` | Lock battery low |
| `-29` | `ERR_NOT_REGISTERED` | Not registered |
| `-30` | `ERR_NO_CLIENT_DATA` | No authorization-card data |
| `-31` | `ERR_ROOMS_CNT_OVER` | Room count exceeds available sectors |
| `-32` | `ERR_CHANGE_CARD` | Please change card |
| `-33` | `ERR_MASTER_FIRST` | Master card must be made before sub-card |

## 5. Lock / card types

`enum LOCK_TYPE` in `Defines.h` — the argument to `TP_Configuration`:

| Value | Name | Type |
|---|---|---|
| `1` | `LT_CPU` | TM card lock |
| `2` | `LT_IC` | Contact IC card lock |
| `3` | `LT_256` | 256 card lock |
| `4` | `LT_T5557` | T5557 card lock |
| `5` | `LT_MF1` | MF1 (Mifare Classic) lock |
| `6` | `LT_MF0` | MF0 lock |

The demos expose only **4 (RF57)** and **5 (RF50)**.

`Defines.h` additionally defines `LOCK_SETTING`, `ROOM_TYPE`, `CARD_FLAGS`,
`MAKE_CARD_TYPE`, `LOCK_SYS_FLAGS0`, and the structs `CARD_INFO`, `LOCK_INFO`,
`ROOM_INFO`, `HANDSIM_INFO`, `ACS_ELEVATOR_SET`.

---

## 6. Two different DLL builds ship in this package

Not all copies of `LockSDK.dll` are identical. There are exactly two:

| Build | Size | MD5 (first 8) | Exports | Where |
|---|---|---|---|---|
| **Current** | 89,088 | `F6B5BB37` | 84 | All demo folders, `(避免厂家码问题)` |
| **Older** | 90,112 | `04CC8BAB` | 74 | `ReaderReset\`, `ReaderReset\DLL\`, `Demo_LockSDK - V4.7(VC6.0)\Debug\DLL\` |

The current build is a strict **superset** — nothing was removed. It adds 10 exports:

```
TP_MakeGuestCardEx2      TP_ReadGuestCardEx2     TP_CancelCardEx2
LS_MakeBatchInfoReadCard LS_MakeBatchInfoSetCard LS_MakeClearCard
LS_MakeClientCardEx1     LS_MakeLostCard_Ex1     LS_MakeLostReadCard
LS_MakeUnLostCard_Ex1
```

**Use the 89,088-byte build.** Matching header variants exist too: the older
`LockSDK.h` (7,049 bytes) lacks the `Ex2` declarations.

---

## 7. Package layout

### Redistributable runtime

`LockSDK V4.7发布_20210913(避免厂家码问题)\` is the cleanest starting point — the DLL
set and headers with no demo baggage. Its name translates to *"avoids the
manufacturer-code problem"*. It carries the same `LockSDK.dll` as the demos but omits
`LockInfo.dll`, the cached reader-authorization blob — **(inferred)** shipping without
a stale cached authorization is likely what avoids the problem.

Runtime files a host app needs alongside `LockSDK.dll`:

| File | Role |
|---|---|
| `PubFuns.dll` | Shared helper routines |
| `RF50S.dll` | M1 card-encoding driver ("M1 make card dll", v201026) |
| `RF57S.dll` | RF57 reader driver |
| `Rf_Rw.dll` | Reader read/write layer |
| `RC500USB.dll`, `EasyD12_500.dll`, `EasyZUSBMulti.dll`, `HSDApp.dll` | USB reader transports |
| `MF0SIM.dll`, `HOOKS_M1.dll` | Mifare support |
| `des.dll` | DES crypto |
| `DataReader.dll` | Data-card reading |

**Two "DLLs" are actually plain INI text files, despite the extension:**

| File | Actually contains |
|---|---|
| `LockInfo.dll` | `[ReaderInfo]` / `[CardData]` — the encoder's authorization blob and serial |
| `LockCard.dll` | `[CardNo]` — a log of issued card serials marked `recorded` |

Per the release notes, card-issuing activity is also written to `cardRecord.ini`.

### Bundled tools *(present but not exercised — descriptions from version metadata)*

| Tool | Description field |
|---|---|
| `LockReg.exe` | "LockReg" — MFC app; encoder registration **(inferred from name + `LS_SaveRegisterCode`)** |
| `RMCRecords.exe` | 3.8 MB; no description. Localised via `Languages(RMC)\{English,Chinese}.INI` |
| `ExtensionTools.exe` | No description |
| `001.RdWr.exe` | "Reader RD_WR" — MFC app, in `ReaderReset\` only |

`ReaderReset\` **(inferred)** is a reader-reset/recovery utility bundle; it pairs the
older DLL build with `001.RdWr.exe` and its own `RDVLanguage.ini`.

### Documentation & archives

| File | Notes |
|---|---|
| `酒管软件接口说明.doc` | "Hotel management software interface description" — 90 KB Word doc, the vendor's own interface spec |
| `Mifare卡详解.pdf` | "Mifare card explained" — 722 KB reference |
| `更改要求.txt` | V4.7 release notes (see §8) |
| `Delphi7.0 Demo_V4(1).7.rar`, `发卡机设置.rar`, `ReaderReset.rar` | Archived copies of shipped folders |

---

## 7a. Operational rules from the vendor spec

Extracted from `酒管软件接口说明.doc`. **Scope note: that document covers only the
`TP_*` API — it does not document any `LS_*` function.** The `LS_*` layer remains
undocumented beyond the comments in `LockDll.h`. What the spec does add is
operational knowledge that appears nowhere in the headers:

**Card supersession (新卡顶替旧卡).** Within one room, the guest card with the *later*
check-in time invalidates earlier ones. A card issued at 12:00 stops working once a
card issued at 12:05 is used at the door. To have several cards open one room they
must either share an identical check-in time, or the later ones must set the
no-replace flag (`iflags = 8`). This bites when several applications (the demo, the
PMS, the lock-management software) issue cards in turn: only the latest works.
Swiping an authorization card or a time-sync card at the lock revives superseded
cards. If cards mysteriously stop working, compare their check-in times first.

**Lock number format.** `1.2.8203`. Suites append a letter: `1.2.8203.A`. Older DLock
management software used formats like `102`, `20105A` or `A0203`. If that software
has no lock number, pass the room number. Authoritative source is the management
software's *客房设置 → 房间信息* (Room Setup → Room Info) screen.

**Add 30 minutes to checkout.** Lock clocks drift. For a real checkout of 12:00 the
next day, encode 12:30.

**Timestamp format is fixed** at `YYYY-MM-DD hh:mm:ss` and must not vary with the
PC's regional date settings.

**The encoder must be one that already issues cards successfully in the lock
management system.** Otherwise cards may encode yet fail to open doors, because the
authorization data is wrong. Recovery: close the software, place the authorization
card on the encoder, reopen — the authorization is then read automatically.

**Ship `LockReg.exe` with your application.** The vendor instructs that it be included
in the release package; it handles registration and reads the authorization card.

**Card records** land in `cardRecord.ini`, where `remark=new` marks a new card and
`remark=copy` a duplicate. `RMCRecords.exe` queries them, but only if it and the
`Languages(RMC)` folder sit in the PMS directory.

### Lock beep codes

Undocumented anywhere else. Swipe the card, remove it, and count the short beeps:

| Beeps | Meaning |
|---|---|
| 1 | Time error |
| 2 | Deadbolt engaged |
| 3 | Wrong building / floor / lock number |
| 4 | Card reported lost |
| 5 | Card password error |
| 6 | Client code error |
| 7 | No setup card swiped yet (lock already holds a room number) |

### Mifare card layout notes

- 16 sectors, numbered 0–15; each sector takes an independent key.
- 4 blocks per sector (0–3); **only blocks 0–2 are usable** (block 3 holds the keys).
- Address as `sector * 4 + block`. Sector 9 gives blocks 36, 37, 38.
- **Avoid sectors the lock itself uses — typically 1, 11 and 15.** Confirm with the
  lock manufacturer.
- Write data must be 32 hex characters (`0-9`, `A-F`, `a-f`).

---

## 8. V4.7 release notes (`更改要求.txt`, translated)

1. Changed to version 3.3.
2. Guest cards are made with `TP_MakeGuestCardEx` — usage is unchanged, **but the
   underlying library now forces the check-in time to the current time**.
3. Updated the latest DLL into all demos.

Also noted: card-issuing records are now saved to `cardRecord.ini`, and *"the VC6.0
`LOCK.h` file was not decrypted"* — which matches the damaged sources described below.

---

## 9. Demo inventory and build status

Nine demo projects ship. **Several have deliberately encrypted/obfuscated source
files** that are not valid text and cannot be compiled. Verified file-by-file:

| Demo | Language | Source status | Buildable |
|---|---|---|---|
| `VB6.0 Demo_V4.7` | VB6 | Intact (`.frm`, `.bas`) | Yes — needs VB6 |
| `Delphi7.0 Demo_V4(1).7` | Delphi 7 | Intact (`Unit1.pas`, `Unit2.pas`) | Yes — needs Delphi 7 |
| `VB.net 2008 DEMO_V4.7` | VB.NET | Intact in main folder | Yes |
| `C# 2010Demo_V4.7` | C# WinForms | Main folder **encrypted**; `Backup\` intact | **Yes, via `Backup\`** |
| `Delphi2010 Demo_V4.7` | Delphi 2010 | `Unit1.pas` **encrypted**; `__history\Unit1.pas.~25~` intact | Yes, via `__history\` |
| `Demo_LockSDK - V4.7(VC6.0)` | C++ / MFC | `Demo_LockSDKDlg.cpp` **encrypted, no intact copy anywhere** | **No** |
| `PB9.0 Demo_V4.7` | PowerBuilder 9 | Source inside `lockdemo.pbl` (binary) | Needs PowerBuilder 9 |
| `PB10.5 Demo_V4.7` | PowerBuilder 10.5 | Source inside `lockdemo.pbl` (binary) | Needs PowerBuilder 10.5 |

### The encrypted files

Affected files are binary blobs containing the marker strings `E-SafeNet` and `LOCK`,
not source text. E-SafeNet is a commercial source-encryption product; decrypting them
requires the vendor's tooling. Recovery paths that *do* work:

- **C#** — build from `C# 2010Demo_V4.7\Backup\CSharpDemo\`, which is complete and clean.
- **Delphi 2010** — the IDE's local-history folder `__history\` holds intact revisions;
  `Unit1.pas.~25~` (9,814 bytes) is the newest and is valid Pascal.
- **C++ / VC6** — no intact copy exists in the package. Ask the vendor, or port from
  the VB6 / Delphi 7 / C# demos, which cover the same API surface.

### Building the C# demo (verified working)

Requires the .NET Framework targeting pack and MSBuild (ships with Visual Studio).

1. Copy `C# 2010Demo_V4.7\Backup\` — **not** the main `CSharpDemo\` folder.
2. `CSharpDemo.csproj` declares no `TargetFrameworkVersion`; add one or MSBuild
   picks a wrong default and fails with `MSB3644`:
   ```xml
   <TargetFrameworkVersion>v4.8</TargetFrameworkVersion>
   ```
3. Build, then copy the runtime DLLs from §7 next to the output `LockSDK_Demo.exe`.
4. Remember the x86 constraint from §1.

---

## 9a. Runtime verification — every executable launched

All executables were copied to a scratch area and launched there (they write state
into their own directory, so running them in place would modify the package). Each
was observed and terminated; no buttons were clicked.

| Executable | Result | UI text |
|---|---|---|
| `LockSDK_Demo.exe` (VB6) | Runs | **Correct English** |
| `LockSDK_Demo.exe` (Delphi 7) | Runs | **Garbled** — 10 strings |
| `LockSDK_Demo.exe` (Delphi 2010) | Runs | **Garbled** — 10 strings |
| `LockSDK_Demo.exe` (VB.NET) | Runs | **Garbled** — 13 strings |
| `LockSDK_Demo.exe` (VC6 prebuilt) | Runs | **Garbled** — 13 strings |
| `locksdk_demo.exe` (PB 9.0) | Runs | Mostly English, **2 garbled** |
| `locksdk_demo.exe` / `lockdemo.exe` (PB 10.5) | **Cannot start** | — missing runtime |
| `LockReg.exe` | Runs (most folders) | Correct English |
| `LockReg.exe` (in `ReaderReset\`) | **Crashes** `0xC0000005` | — |
| `RMCRecords.exe` | Runs — "Issue Card Records" | Correct English |
| `ExtensionTools.exe` (102,400 build) | Runs | Correct English |
| `ExtensionTools.exe` (131,072, VC6 only) | Runs | **Garbled** |
| `001.RdWr.exe` (in `ReaderReset\`) | **Crashes** `0xC000001D` | — |

### PowerBuilder 10.5 is unusable as shipped

Both PB 10.5 executables fail at load with *"The code execution cannot proceed
because MSVCR71.dll was not found"*. Import analysis of every binary confirms two
unresolved dependencies:

| Missing | Needed by | Available? |
|---|---|---|
| `MSVCR71.dll` | `PBVM105.DLL`, `PBSHR105.DLL`, `msvcp71.dll` | **No** — absent from the package and from this system |
| `ATL71.DLL` | `PBVM105.DLL` | **Yes** — the vendor shipped it in `PB9.0 Demo_V4.7\`, just not in the 10.5 folder |

This is a vendor packaging defect: `msvcp71.dll` (the C++ library) was included but
its companion `MSVCR71.dll` (the C runtime) was not. Both belong to the Visual C++
7.1 / Visual Studio .NET 2003 runtime. Copying `atl71.dll` from the PB 9.0 folder
fixes half of it; `MSVCR71.dll` must come from a legitimate Microsoft source —
**do not** fetch it from a "DLL download" site, as those are a well-known malware
vector.

PB 9.0 also shows one unresolved import, `ntwdblib.dll` (needed by `pbmss90.dll`,
PowerBuilder's MS SQL Server interface), but this does not prevent startup — the
demo uses no database and PB 9.0 runs fine.

### The two DLL builds are not ordinal-compatible

The `LockReg.exe` crash in `ReaderReset\` is a build-pairing problem, not a broken
tool — the identical binary (MD5 `3AAC82F2`, present in 11 folders) runs correctly
everywhere else. `ReaderReset\` is the folder carrying the *older* 90,112-byte DLL.

Substituting the newer DLL there does not help: `LockReg.exe` then fails with
`0xC0000138` — *"The ordinal 52 could not be located in the dynamic link library
LockSDK.dll"*. Because the newer build adds 10 exports, export ordinals shift, and
these tools bind by ordinal rather than by name.

**Consequence: `LockSDK.dll` and the tools around it must be deployed as a matched
set.** Never mix a DLL from one folder with executables from another. Interestingly
`001.RdWr.exe` behaves oppositely — it dies with `0xC000001D` against the old DLL
but starts against the new one, so its shipped pairing appears wrong too.

---

## 10. Known issues and gotchas

### Mojibake: GBK text through ANSI APIs

The demos load their UI strings at runtime from `ToolsLanguage.ini`, which is
GBK-encoded. The bundled `Ini` helper calls `GetPrivateProfileString` via P/Invoke
**without specifying `CharSet`** — C# defaults to `CharSet.Ansi`, so Windows decodes
those GBK bytes using the machine's ANSI codepage. On any system not set to codepage
936 the entire UI renders as garbage: `门锁` (GBK `C3 C5 CB F8`) displays as `ÃÅËø`.

Fixes, best first:

1. **Parse the INI in managed code with an explicit encoding**
   (`Encoding.GetEncoding(936)`), replacing the `GetPrivateProfileString` P/Invoke.
   Contained, and correct on every machine.
2. Swap in the shipped English string table — `ToolsLanguage-en.ini` over
   `ToolsLanguage.ini`. Sidesteps the issue for English UIs but leaves the bug.
3. Setting Windows' *Language for non-Unicode programs* to Chinese (PRC) also masks
   it, but it is system-wide, needs a reboot, and does not fix the code.

The same class of bug applies to any `char*` crossing the `TP_*`/`LS_*` boundary:
these are ANSI strings, so marshal them as GBK rather than assuming the host's
default codepage.

**Which demo is affected is pure luck of packaging.** The vendor shipped a different
`ToolsLanguage.ini` in each folder, and garbling tracks that exactly:

| Folder | `ToolsLanguage.ini` shipped | Observed UI |
|---|---|---|
| VB6, PB 9.0, PB 10.5, ReaderReset | English | Readable |
| Delphi 7, Delphi 2010, VB.NET, VC6 | Chinese | Garbled |

Every folder ships the other language too, as `ToolsLanguage-en.ini` or
`ToolsLanguage-cn.ini`, so switching is a file copy. That masks the defect rather
than fixing it — a Chinese UI stays broken until the INI reading is corrected.

The diagnosis is verifiable by reversing the fault: re-encode a garbled string as
Latin-1 and decode it as GBK, and the intended text reappears. Confirmed on every
affected app, e.g. `ÔÊÐí¿ª·´Ëø` → `允许开反锁` ("allow opening the deadbolt"),
`ÖÇÄÜËøÀ©Õ¹·ÖÇøÉèÖÃ¹¤¾ß` → `智能锁扩展分区设置工具`.

Two garbled strings in the PB 9.0 demo survive despite its English INI
(`门锁号：`, `预离时间：`), meaning those labels are hardcoded in the PowerBuilder
application rather than read from the string table. Swapping the INI will not fix
those two.

> This trap is not limited to the SDK. PowerShell 5.1 reads a `.ps1` file without a
> BOM using the ANSI codepage, so tooling written to *audit* this bug will itself be
> corrupted if it contains CJK literals. Keep such scripts pure ASCII and build
> character ranges from codepoints.

### Mixed source encodings

Source files are inconsistently encoded even within one project — some GBK without
BOM, some UTF-8 with BOM. Compilers that auto-detect by BOM will silently misread
the GBK ones. Either pass the compiler an explicit codepage (`csc /codepage:936`) or
normalise everything to UTF-8-with-BOM before editing, or Chinese comments and
string literals will be corrupted on save.

### Duplicated, drifting copies

`LockSDK.h` exists in 13 locations in 2 versions; `LockSDK.dll` in 14 locations in
2 builds; the C# and VB.NET demos each carry `Backup\` and `Backup1\` trees. Pin one
known-good copy rather than picking up whichever is nearest.

---

## 11. Integration checklist

- [ ] Target **x86**
- [ ] Take `LockSDK.dll` from the **89,088-byte** build
- [ ] Ship the support DLLs from §7 alongside it
- [ ] Marshal all strings as **GBK**, not the host default codepage
- [ ] Pre-allocate output buffers (≥ 20 bytes serials/rooms, ≥ 30 bytes timestamps)
- [ ] Call `TP_Configuration` first, with the right `LOCK_TYPE`
- [ ] Check every return against §4 — success is `1`, not `0`
- [ ] Pass the **lock number** to `TP_MakeGuestCardEx*`, not the room number
- [ ] Expect check-in time to be overridden to the current time (§8)
- [ ] Deploy `LockSDK.dll` and the tools as a **matched set** — they bind by ordinal (§9a)
- [ ] Ship `LockReg.exe` alongside your app, as the vendor instructs (§7a)
- [ ] Push encoded checkout times **30 minutes later** than the real checkout (§7a)
- [ ] Keep timestamps as `YYYY-MM-DD hh:mm:ss` regardless of PC locale (§7a)
- [ ] For member cards, avoid Mifare sectors 1, 11 and 15 (§7a)
