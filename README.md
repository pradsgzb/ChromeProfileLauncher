# Chrome Profile Launcher 2.0

A single-file replacement for the supplied `chrome.ps1`.

**Runtime target:** Windows PowerShell 5.1 or PowerShell 7 on Windows. No extra PowerShell modules are required to use the launcher. Pester and PSScriptAnalyzer are development/test dependencies only.

**Validation status:** Supplemental source and algorithm checks were run in the preparation environment. The PowerShell interpreter, PSScriptAnalyzer, Pester, and a real Windows/Chrome GUI were not available there and were **not run**. Execute the included validation and the small real-browser smoke test below before broad deployment. See `VALIDATION.md` for the exact boundary.

## 1. Start here

Back up your original script and save the replacement as `chrome.ps1`. Run these commands from the folder containing the new file:

```powershell
# Print the temporary-profile launch commands without opening Chrome.
.\chrome.ps1 Temp

# Ask for confirmation, start five, then ask which batch to start next.
.\chrome.ps1 Temp -Run

# Start all selected profiles without asking any script-level questions.
.\chrome.ps1 Temp -RunAll
```

The existing temporary-profile parent remains `D:\Temp\Chrome`. Override it explicitly when needed:

```powershell
.\chrome.ps1 Temp -TempDir 'E:\Browser Sessions' -Run
```

Neither the launcher nor its examples change PowerShell execution policy. Use your organization's approved script-signing and execution process. Review the script before trusting or unblocking a downloaded copy.

## 2. Execution behavior

| Invocation | Behavior |
| --- | --- |
| No execution switch | Preview only. No Chrome launches or close requests. |
| `-Run` | Ask before the first five, or all remaining if fewer than five. Then offer 5, 10, 15, 20, all remaining, or quit. |
| `-RunAll` | No confirmation/menu prompts. Submit every selected launch back-to-back, with no intentional inter-launch delay by default. |
| `-WhatIf` | Prevent browser changes even when combined with `-Run` or `-RunAll`. No custom interaction prompts. |
| `-Run -RunAll` | Rejected during parameter binding. |
| `-RunAll -Confirm` | Rejected as contradictory. It does not silently override an explicit request for confirmation. |

“First five” means the first five **selected** profiles after discovery, ordering, filtering, and any starting-index/maximum-count selection. The first confirmation defaults to **No**. At a continuation menu, Enter defaults to **quit**.

Example interaction:

```text
Selected 37 profile(s) from 37 matching profile(s). Mode: Temp.
First batch from 'D:\Temp\Chrome':
  1. Session1 -> Default
  2. Session2 -> Default
  3. Session3 -> Default
  4. Session4 -> Default
  5. Session5 -> Default
Launch the first 5 of 37 selected Chrome profiles? [y/N]: y
...
32 remaining. Next [5 / 10 / 15 / 20 / A=all / Q=quit] (Enter quits): 10
```

A requested batch never exceeds the remaining count. Selecting `A`/`ALL` submits all remaining launches without another menu. Quitting leaves previously started Chrome windows open. Repeating a selection can open duplicate windows or tabs; this launcher does not automatically de-duplicate already open windows.

`-Run` defaults to a 500-millisecond interval **between** launches in each batch. `-RunAll` defaults to zero. Both accept an explicit override:

```powershell
.\chrome.ps1 Temp -Run -LaunchDelayMilliseconds 1000
.\chrome.ps1 Temp -RunAll -LaunchDelayMilliseconds 250
```

“All at once” means immediate submission of the entire selection, not literal simultaneous process creation. The script does not wait for pages to finish loading or for a browser window to become ready. Opening many profiles at once may be resource-intensive; begin with a small real-browser smoke test.

## 3. The profile-selector repair

The original Temp command placed a backslash directly before a closing native quote and also appended the directory as an extra bare argument. It did not explicitly select an internal Chrome profile. The replacement:

* Passes one correctly quoted native argument string to `Start-Process`, including proper escaping of trailing backslashes and embedded quotes. [1][2]
* Specifies both `--user-data-dir` and `--profile-directory`, with a particular existing profile selected whenever one can be identified safely. [3][4]
* Removes the duplicate bare directory argument and supplies `--new-window`, `--no-first-run`, and `--no-default-browser-check`.

Conceptually, a temporary launch is now:

```text
chrome.exe "--user-data-dir=D:\Temp\Chrome\Session1" "--profile-directory=Default" "--new-window" "--no-first-run" "--no-default-browser-check" "https://gemini.google.com/app" "https://chatgpt.com" "https://seaart.ai"
```

The executable and the entire argument string are separately escaped when the script prints a copyable PowerShell `Start-Process` command. This avoids relying on differing direct-native-command argument handling between PowerShell versions.

The change fixes the command-construction defects identified in the supplied file. It is not a guarantee that managed-browser policies, a damaged/locked profile, a mandatory sign-in dialog, or another environmental issue cannot display browser UI. No Chrome policy or profile metadata is modified to bypass those conditions.

## 4. Correct directory layouts

Chrome distinguishes the **user-data root** from its **profile subdirectories**. A common internal profile folder is `Default`. Chrome's `chrome://version` page reports the actual Profile Path; its parent is the user-data root. [3]

### Temp mode: many isolated user-data roots

```text
D:\Temp\Chrome\                     <-- -TempDir
    Session1\                       <-- --user-data-dir
        Local State
        Default\                    <-- --profile-directory
            Preferences
    Session2\
        Local State
        Default\
            Preferences
    Session3\                       <-- an empty directory is allowed
```

Each immediate child of `-TempDir` contributes **one** launch. Selection inside each child root works as follows:

1. An explicit `-ProfileDirectory` takes precedence. A missing named profile may be created by Chrome when execution is authorized.
2. Otherwise, use `Default` when it exists.
3. Otherwise, use the sole recognized existing profile folder.
4. An empty child user-data root selects a new `Default` profile.
5. Multiple non-Default profiles are ambiguous and cause a preflight error. A nonempty unrelated folder also causes a preflight error unless an internal profile was explicitly selected.

```powershell
.\chrome.ps1 Temp -ProfileDirectory 'Profile 2' -Run
```

All matching child roots are discovered and checked before the first launch. Consequently, a malformed matching directory can prevent execution even if it falls beyond `-MaxProfiles`. Use `-ProfileFilter` to narrow discovery to the intended session directories.

Do not point `-TempDir` directly at Chrome's normal `User Data` folder: its children are profiles, not isolated user-data roots. The script detects common cases of this layout mistake rather than silently creating nested blank profiles. Linked child directories and linked discovered profile directories are not followed.

“Temp” preserves the original script's terminology. These are **persistent directories**, not auto-deleted incognito sessions. The script neither deletes nor cleans up their data.

### Standard mode: many profiles within one user-data root

```text
C:\Users\YourUser\AppData\Local\Google\Chrome\User Data\
    Local State
    Default\
    Profile 1\
    Profile 2\
```

```powershell
.\chrome.ps1 Standard
.\chrome.ps1 Standard -Run
.\chrome.ps1 Standard -RunAll

# A custom root is passed to Chrome as well as used during discovery.
.\chrome.ps1 Standard -UserDataDir 'D:\Browsers\Work User Data' -Run
```

Standard mode reads display labels from `Local State` when available. Missing or malformed labels fall back to directory names. System/Guest profile directories are excluded. Standard mode opens a blank tab unless you supply `-Urls`; this makes the new-window request explicit instead of relying on existing startup preferences.

## 5. Useful options

| Parameter | Purpose |
| --- | --- |
| `-ChromePath` | Explicit existing `chrome.exe`; otherwise discover normal install locations, registered App Paths, then PATH. |
| `-ProfileFilter` | Wildcard filter. Temp: root folder name. Standard: folder name or display label. |
| `-StartIndex` | One-based index into the sorted, filtered discovery list. |
| `-MaxProfiles` | Maximum count after the starting index. Omit for all remaining. |
| `-Urls` | Replacement list, not additions to the defaults. Accepts HTTP/HTTPS URLs without embedded credentials and `about:blank`. |
| `-StopOnError` | Stop immediately after a failed launch request. |
| `-PassThru` | Return structured plans/results for inspection or export. |
| `-Verbose` | Additional diagnostic information. |

Ordering uses a natural numeric key, so `Session2` comes before `Session10`. Standard mode uses display labels, with folder names as a tie-breaker.

```powershell
# Narrow discovery before selecting a starting position/count.
.\chrome.ps1 Temp -ProfileFilter 'Session*' -StartIndex 6 -MaxProfiles 10 -Run

# Test only one profile against a non-AI placeholder page.
.\chrome.ps1 Temp -MaxProfiles 1 -Urls 'about:blank' -Run

# Custom websites replace the three original Temp defaults.
.\chrome.ps1 Temp -Urls @('https://example.com', 'https://example.org') -Run

# The original default Temp websites: Gemini, ChatGPT, SeaArt.
# Use approved URLs only; avoid secrets or sensitive identifiers in URLs.

# Save preview commands. This command itself does not launch browsers.
.\chrome.ps1 Temp | Set-Content -LiteralPath '.\ChromeCommands.ps1' -Encoding UTF8

# Structured preview.
.\chrome.ps1 Temp -PassThru |
    Select-Object Index, DisplayName, UserDataDir, ProfileDirectory

# Structured execution results. Failures still raise a terminating error.
.\chrome.ps1 Temp -RunAll -MaxProfiles 5 -PassThru |
    Export-Csv -LiteralPath '.\ChromeResults.csv' -NoTypeInformation -Encoding UTF8
```

**An exported command file contains executable commands.** Running it directly does not reproduce the launcher's batching/confirmation gates. Use the main script with `-Run` for those controls.

The continuation message reports how to resume **unattempted** profiles with `-StartIndex` and `-MaxProfiles`. Reuse the same mode, paths, filters, and other launch options. This is reliable only while the discovery list/order remains unchanged; it is not a durable checkpoint and does not retry earlier failures automatically.

## 6. Results and failure handling

| Status | Meaning |
| --- | --- |
| `LaunchRequested` | `Start-Process` returned a process object. No assertion about window identity, page readiness, successful sign-in, or continued process lifetime. |
| `Failed` | The process-creation request raised an exception. |
| `Skipped` | PowerShell's confirmation/WhatIf gate declined the operation. |

Chrome can forward a request to an existing browser process, so the returned requested process ID is not a durable browser-window ID. The script does not automatically retry because that could duplicate windows.

By default, launch-request failures are reported, later profiles are still attempted subject to the selected batching, and an aggregate terminating error is raised afterward. `-StopOnError` stops at the first failure. Fatal preflight errors prevent the first launch. Cancellation is not treated as a failure unless failed requests have already occurred.

The script's `ShouldProcess` gates honor `-WhatIf`. `-RunAll` suppresses ambient script confirmation prompts but rejects explicit `-Confirm:$true`. With `-Run`, an explicit `-Confirm` or a low ambient `$ConfirmPreference` can add native PowerShell confirmations in addition to the batch menu. [5]

## 7. Close mode: intentional safety change

The original `Close` branch closed Chrome immediately and could loop forever. The replacement preserves the graceful-close operation but makes it opt-in and bounded:

```powershell
.\chrome.ps1 Close                                  # Preview only
.\chrome.ps1 Close -Run                             # Ask first
.\chrome.ps1 Close -RunAll                          # No script confirmation
.\chrome.ps1 Close -Run -CloseTimeoutSeconds 30
.\chrome.ps1 Close -RunAll -WhatIf                   # No close requests
```

**Close targets Chrome across the current Windows session**, including Standard and Temp windows; it is not limited to windows launched by this script. It snapshots window-owning processes, checks process identity to avoid PID reuse, requests close on newly observed main-window handles, and stops polling at the configured timeout. Unsaved-work or browser confirmation dialogs may still require manual action. No `Stop-Process`, force-kill, or profile deletion is used. Chrome background processes may remain, and main-window inspection is a best-effort mechanism rather than an exhaustive window-manager audit.

## 8. Design and development

The implementation separates mode-specific discovery, metadata reading, command planning, interactive decisions, process execution, and graceful-close handling. Launch plans are command records rather than strings evaluated as code. The process adapter gives the tests a narrow mockable boundary.

It uses advanced-script parameter sets for mutually exclusive execution modes, validation attributes, explicit mode validation, strict mode, approved PowerShell verbs, literal filesystem paths, comment-based help, structured result records, and `ShouldProcess` safety gates. It avoids unnecessary classes/frameworks, global state changes, `Invoke-Expression`, security-disabling browser flags, and automatic privilege elevation.

PSScriptAnalyzer is Microsoft's PowerShell static-analysis tool. The included configuration enables its default warning/error rules and syntax-compatibility checks. Two narrowly scoped rule suppressions document why pure in-memory `New-*` object factories do not need a confirmation prompt; operations that affect Chrome do have approval gates. These are implementation choices aligned with documented guidance, not a Microsoft certification or a claim of defect-free code. [5][6]

## 9. Local validation

The launcher requires no installation. To run its development tests, install the test-only dependencies through your organization's approved PowerShell repository process:

```powershell
Install-Module -Name Pester -RequiredVersion 5.7.1 -Scope CurrentUser
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser

# Run from a fresh PowerShell session.
.\Validate.ps1
```

Pester is deliberately pinned to 5.7.1 because these tests use its version-5 assertion/mocking API. Validation does not silently install modules. Run once under Windows PowerShell 5.1 and once under your supported PowerShell 7 version. The tests mock browser creation and use test directories; they are not real-browser smoke tests. A Windows-only test also checks the quoting round trip through `CommandLineToArgvW`.

After the test suite passes, perform the real-browser smoke test:

```powershell
.\chrome.ps1 Temp -MaxProfiles 1 -Urls 'about:blank'
.\chrome.ps1 Temp -MaxProfiles 1 -Urls 'about:blank' -Run
```

Inspect `chrome://version` in the resulting window and confirm its Profile Path belongs to the intended temporary root and internal profile. Then test a five-profile batch before using a large `-RunAll` selection.

Built-in help:

```powershell
Get-Help .\chrome.ps1 -Detailed
```

## Reference documentation

1. Microsoft Learn — Start-Process, especially `ArgumentList`: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process
2. Microsoft Learn — Parsing C command-line arguments: https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments
3. Chromium — User Data Directory: https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md
4. Chromium — Chrome command-line switch definitions: https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/common/chrome_switches.cc
5. Microsoft Learn — Everything you wanted to know about ShouldProcess: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
6. Microsoft Learn — PSScriptAnalyzer overview and state-changing-function rule: https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/overview and https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/useshouldprocessforstatechangingfunctions
