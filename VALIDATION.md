# Validation record

Prepared: September 20, 2026.

## Performed in the preparation environment

The environment was Linux with Python available, but without Windows PowerShell, `pwsh`, Pester, PSScriptAnalyzer, or a Windows Chrome GUI. An attempted runtime acquisition was unsuccessful. No PowerShell runtime test result is claimed.

`python tests/static_checks.py` was executed against the delivered source. Its report is saved as `STATIC_CHECK_RESULTS.json`.

The supplemental checks covered:

- Balanced delimiters outside comments/quoted strings in the delivered `.ps1` and `.psd1` files. This is a lexical check, **not** the PowerShell parser or syntax certification.
- 20,014 single-argument cases and 5,000 multi-argument vectors, using the quoting regular expressions extracted from `chrome.ps1`, an independent Windows argument-parsing model, and Python's Windows-command-line quoting implementation as an additional comparison.
- 600 batch-loop model scenarios for different profile counts and menu selections, checking ordering, no duplication, batch capping, and cancellation.
- Nine targeted textual regression assertions, including both profile-selection switches, exclusive execution modes, a five-profile first batch, a zero-delay RunAll default, a bounded close loop, and absence of force-kill/evaluated-command/global-variable statements.

These checks passed. They do **not** establish that the PowerShell script parses, the Windows APIs execute correctly, Pester mocks behave correctly, every analyzer rule passes, or Chrome opens the intended GUI profile on a particular installation.

## Included, but not executed here

`Validate.ps1` invokes the actual PowerShell parser, PSScriptAnalyzer, and the Pester 5.7.1 suite. The suite covers argument construction, URL validation, profile discovery/layouts, metadata fallback, menu choices, initial confirmation, all continuation sizes, cancellation, RunAll behavior, WhatIf precedence, selection offsets, error handling, parameter conflicts, graceful-close identity/timeout safeguards, and a Windows native argument-parsing round trip.

**Status:** NOT RUN in this environment. Run on the intended Windows PowerShell 5.1 and PowerShell 7 installations before deployment. The test code itself also requires local validation.

## Required real-browser acceptance checks

Use existing disposable/non-sensitive test profile roots rather than operational browser sessions.

| Check | Expected behavior | Status here |
| --- | --- | --- |
| `Temp` without execution switches | Prints commands; no browser changes. | Not run on Windows |
| `Temp -Run`, answer No/Enter | Zero launches. | Not run on Windows |
| `Temp -Run`, answer Yes | First five selected profiles requested, then menu. | Not run on Windows |
| Next 5 / 10 / 15 / 20 | Only the chosen next batch requested, capped at remaining. | Not run on Windows |
| All remaining | Remaining selection requested without another menu. | Not run on Windows |
| `Temp -RunAll` | No script prompts; entire selection requested. | Not run on Windows |
| `Temp -RunAll -WhatIf` | No browser changes and no custom prompts. | Not run on Windows |
| `chrome://version` | Intended root/internal profile appears in Profile Path. | Not run on Windows |
| `Standard -UserDataDir ...` | Chrome uses the specified root, not an unrelated default root. | Not run on Windows |
| `Close` without execution switches | No close requests. | Not run on Windows |
| `Close -Run` | Confirmation required; current-session scope disclosed. | Not run on Windows |
| Browser blocks close | Bounded timeout; no force-kill. | Not run on Windows |

Browser process creation is not proof of page readiness, sign-in completion, or the absence of management-policy dialogs. A `LaunchRequested` result deliberately makes none of those claims.
