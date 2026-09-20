#requires -Version 5.1
<#
.SYNOPSIS
    Previews or launches Chrome profiles, or requests a graceful browser close.
.DESCRIPTION
    Windows-only, dependency-free launcher for Windows PowerShell 5.1 and PowerShell 7.
    With neither -Run nor -RunAll, prints commands without starting or closing Chrome.
    -Run asks before the first five profiles, then offers 5/10/15/20/all/quit.
    -RunAll submits every selected launch without prompts or an intentional delay.
    -WhatIf always prevents browser changes. Each launched profile opens a self-contained
    identification tab first so the temporary folder is visible in the active tab/window title.
    Nothing edits Chrome's Local State file, deletes profiles, disables browser security,
    or forcibly terminates processes.

    Standard: existing profiles inside one Chrome user-data directory.
    Temp: one profile per immediate child user-data directory under -TempDir.
    Close: best-effort graceful close of Chrome windows in this Windows session.
.PARAMETER Mode
    Standard, Temp, or Close. May be specified positionally.
.PARAMETER Run
    Interactive execution. Initial launch batch is five (or the number remaining).
    Pressing Enter at the initial confirmation or continuation menu cancels.
.PARAMETER RunAll
    Noninteractive execution. Mutually exclusive with -Run and with -Confirm:$true.
    Launches are submitted back-to-back; website load completion is not awaited.
.PARAMETER UserDataDir
    Standard mode only. Defaults to the current user's Chrome User Data directory.
.PARAMETER TempDir
    Temp mode only. Parent of isolated Chrome user-data directories.
    Default: D:\Temp\Chrome. These directories persist; they are NOT auto-deleted.
.PARAMETER ChromePath
    Optional full path to chrome.exe. Otherwise searches normal installations,
    registered App Paths, and PATH. No administrator elevation is requested.
.PARAMETER ProfileDirectory
    Temp mode only. Exact internal profile folder, for example 'Default' or 'Profile 2'.
    When omitted, selects Default if it exists, otherwise the single existing profile.
    Empty user-data roots initialize Default. Ambiguous roots are skipped unless
    explicitly selected. This is a folder NAME, never an absolute path.
    Use -TempDir for a path such as D:\Temp\Chrome.
.PARAMETER ExcludeDirectory
    Temp mode only. Additional case-insensitive wildcard patterns for child directory
    names, for example 'Backup*', 'Archive*'. Dot-prefixed, hidden, system, and linked
    directories are always skipped. Unrelated or unreadable directories are skipped
    with a warning. An explicit ProfileDirectory does not bypass these protections.
.PARAMETER ProfileFilter
    Wildcard matched against folder names and, in Standard mode, display names.
    Default: *. Filtering occurs before StartIndex and MaxProfiles.
.PARAMETER StartIndex
    One-based starting position within the sorted, filtered discovery results.
.PARAMETER MaxProfiles
    Maximum number of profiles selected after StartIndex. Default: unlimited.
.PARAMETER Urls
    Optional replacement URLs. Only absolute HTTP/HTTPS URLs and about:blank are accepted.
    Temp defaults: Gemini, ChatGPT, SeaArt. Standard defaults: a new blank tab.
    Pass -Urls @() from PowerShell for a blank tab in either launch mode.
.PARAMETER NoProfileIdentifierTab
    Disables the identification tab that is normally opened first in each launched window.
    By default the tab title is "PROFILE - <temporary-folder-name>" and the page shows
    the temporary folder, user-data directory, internal profile directory, and full profile path.
.PARAMETER LaunchDelayMilliseconds
    Delay BETWEEN launches within a batch. Default: 500 with -Run, zero with -RunAll.
    An explicitly supplied value is honored in either mode. This is not a load wait.
.PARAMETER CloseTimeoutSeconds
    Close mode only. Maximum polling time for graceful close. Default: 15 seconds.
    Blocked windows are reported rather than force-killed.
.PARAMETER StopOnError
    Stops after the first failed launch request. Otherwise attempts the remaining
    selected profiles, then throws an aggregate error if any launch requests failed.
.PARAMETER PassThru
    Emits structured plan/result objects instead of command strings during preview,
    or emits execution results during a run. Status LaunchRequested is NOT a
    guarantee that Chrome displayed the correct window or finished loading websites.
.EXAMPLE
    .\chrome.ps1 Temp
.EXAMPLE
    .\chrome.ps1 Temp -Run
.EXAMPLE
    .\chrome.ps1 Temp -RunAll
.EXAMPLE
    .\chrome.ps1 Standard -UserDataDir 'D:\Browsers\Work User Data' -Run
.EXAMPLE
    .\chrome.ps1 Temp -ProfileFilter 'Session*' -StartIndex 6 -MaxProfiles 10 -Run
.EXAMPLE
    .\chrome.ps1 Temp -RunAll -WhatIf
.EXAMPLE
    .\chrome.ps1 Close -Run
.NOTES
    Version: 2.1.0
    Invoke this script normally; do not dot-source it into your interactive profile.
    Re-running the same selection may open duplicate windows/tabs.
#>
[CmdletBinding(DefaultParameterSetName = 'Preview', SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Preview')]
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Interactive')]
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Unattended')]
    [ValidateSet('Standard', 'Temp', 'Close')]
    [string]$Mode,

    [Parameter(Mandatory = $true, ParameterSetName = 'Interactive')]
    [switch]$Run,

    [Parameter(Mandatory = $true, ParameterSetName = 'Unattended')]
    [switch]$RunAll,

    [ValidateNotNullOrEmpty()]
    [string]$UserDataDir = "$env:LOCALAPPDATA\Google\Chrome\User Data",

    [ValidateNotNullOrEmpty()]
    [string]$TempDir = 'D:\Temp\Chrome',

    [ValidateNotNullOrEmpty()]
    [string]$ChromePath,

    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        if ($_ -match '[\\/:]') {
            throw "ProfileDirectory must be an internal folder NAME such as 'Default' or 'Profile 2', not a path. For the parent path use: Temp -TempDir 'D:\Temp\Chrome'."
        }
        if ([string]::IsNullOrWhiteSpace($_) -or
            $_ -notmatch '^(?!\.{1,2}$)(?!.*[. ]$)[^\\/:*?"<>|\x00-\x1f]+$') {
            throw "ProfileDirectory must be a valid folder NAME such as 'Default' or 'Profile 2', without a trailing dot or space. Use -TempDir for a parent path."
        }
        return $true
    })]
    [string]$ProfileDirectory,

    [AllowEmptyCollection()]
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) {
            throw 'ExcludeDirectory patterns cannot be blank.'
        }
        # Validate the pattern before discovery or any browser operation.
        $candidatePattern = [System.Management.Automation.WildcardPattern]::new(
            $_, [System.Management.Automation.WildcardOptions]::IgnoreCase
        )
        [void]$candidatePattern.IsMatch('')
        return $true
    })]
    [string[]]$ExcludeDirectory = @(),

    [ValidateNotNullOrEmpty()]
    [string]$ProfileFilter = '*',

    [ValidateRange(1, 2147483647)]
    [int]$StartIndex = 1,

    [ValidateRange(1, 2147483647)]
    [int]$MaxProfiles = [int]::MaxValue,

    [AllowEmptyCollection()]
    [string[]]$Urls,

    [switch]$NoProfileIdentifierTab,

    [ValidateRange(0, 60000)]
    [int]$LaunchDelayMilliseconds = 500,

    [ValidateRange(1, 300)]
    [int]$CloseTimeoutSeconds = 15,

    [switch]$StopOnError,
    [switch]$PassThru
)

Set-StrictMode -Version 3.0

# Discovery, command construction, interaction, and side effects are deliberately
# separated. Launch-plan objects are the command records; each mode is a discovery
# strategy. The process adapter is a small, mockable side-effect boundary.

function Write-ChromeMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message)
    Write-Information -MessageData $Message -InformationAction Continue
}

function Resolve-ChromeDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if ($item.PSProvider.Name -ne 'FileSystem' -or -not $item.PSIsContainer) {
        throw "Not a file-system directory: $LiteralPath"
    }
    # Keep a drive/UNC root intact; otherwise remove trailing directory separators.
    $root = [System.IO.Path]::GetPathRoot($item.FullName)
    if ($item.FullName -eq $root) { return $item.FullName }
    return $item.FullName.TrimEnd([char[]]@('\', '/'))
}

function Get-ChromeInfoCache {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][string]$Root)

    $cache = @{}
    $statePath = Join-Path -Path $Root -ChildPath 'Local State'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $cache }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $state) { throw 'Local State is empty.' }
            $profileProperty = $state.PSObject.Properties['profile']
            if ($null -eq $profileProperty -or $null -eq $profileProperty.Value) { return $cache }
            $cacheProperty = $profileProperty.Value.PSObject.Properties['info_cache']
            if ($null -eq $cacheProperty -or $null -eq $cacheProperty.Value) { return $cache }
            foreach ($property in $cacheProperty.Value.PSObject.Properties) {
                $cache[$property.Name] = $property.Value
            }
            return $cache
        }
        catch {
            if ($attempt -eq 3) {
                Write-Warning "Cannot read profile labels in '$statePath'; using directory names. $($_.Exception.Message)"
            }
            else { Start-Sleep -Milliseconds 100 }
        }
    }
    return $cache
}

function Get-ChromeProfileFolder {
    [CmdletBinding()]
    [OutputType([System.IO.DirectoryInfo])]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$InfoCache
    )

    Get-ChildItem -LiteralPath $Root -Directory -ErrorAction Stop | Where-Object {
        # Never follow profile junctions/symlinks into a different user-data root.
        ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and
        $_.Name -notin @('System Profile', 'Guest Profile') -and
        ($_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' -or $InfoCache.ContainsKey($_.Name))
    }
}

function Get-ChromeProfileLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$FolderName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$InfoCache
    )
    if ($InfoCache.ContainsKey($FolderName) -and $null -ne $InfoCache[$FolderName]) {
        $nameProperty = $InfoCache[$FolderName].PSObject.Properties['name']
        if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
            # Metadata is displayed only; never evaluated as PowerShell code.
            return ([string]$nameProperty.Value -replace '[\x00-\x1f\x7f]', ' ')
        }
    }
    return $FolderName
}

function Get-ChromeDirectorySkipReason {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Directory,
        [AllowEmptyCollection()]
        [System.Management.Automation.WildcardPattern[]]$ExcludedPatterns = @()
    )

    # Check names and attributes BEFORE opening any candidate's contents. Quarantine
    # folders may contain real Chrome data; their contents do not authorize a launch.
    if ($Directory.Name.StartsWith('.', [System.StringComparison]::Ordinal)) {
        return 'dot-prefixed support/quarantine directory; not a launch candidate'
    }
    if (($Directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return 'linked directory (junction/symbolic link); links are not followed'
    }
    if (($Directory.Attributes -band [System.IO.FileAttributes]::Hidden) -ne 0 -or
        ($Directory.Attributes -band [System.IO.FileAttributes]::System) -ne 0) {
        return 'hidden or system directory; not a launch candidate'
    }
    foreach ($pattern in $ExcludedPatterns) {
        if ($pattern.IsMatch($Directory.Name)) {
            return 'name matches an -ExcludeDirectory pattern'
        }
    }
    return $null
}

function Get-ChromeProfile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Standard', 'Temp')][string]$DiscoveryMode,
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$InternalProfile,
        [Parameter(Mandatory = $true)][string]$Filter,
        [AllowEmptyCollection()][string[]]$ExcludedDirectories = @()
    )

    $wildcard = [System.Management.Automation.WildcardPattern]::new(
        $Filter, [System.Management.Automation.WildcardOptions]::IgnoreCase
    )
    if ($DiscoveryMode -eq 'Standard') {
        $cache = Get-ChromeInfoCache -Root $Root
        $folders = @(Get-ChromeProfileFolder -Root $Root -InfoCache $cache)
        foreach ($folder in $folders) {
            $label = Get-ChromeProfileLabel -FolderName $folder.Name -InfoCache $cache
            if ($wildcard.IsMatch($folder.Name) -or $wildcard.IsMatch($label)) {
                [pscustomobject]@{
                    Mode = 'Standard'; Folder = $folder.Name; DisplayName = $label
                    UserDataDir = $Root; ProfileDirectory = $folder.Name
                }
            }
        }
        return
    }

    if ((Test-Path -LiteralPath (Join-Path -Path $Root -ChildPath 'Local State') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path -Path $Root -ChildPath 'Default\Preferences') -PathType Leaf)) {
        throw "TempDir appears to be a single Chrome user-data root. Use Standard -UserDataDir '$Root', or select its parent directory."
    }

    $excludedPatterns = @(
        foreach ($pattern in $ExcludedDirectories) {
            [System.Management.Automation.WildcardPattern]::new(
                $pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase
            )
        }
    )
    # -Force lets us REPORT intentionally skipped hidden/system children. No recursive
    # enumeration is performed, and an unreadable parent still fails before any launch.
    $roots = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction Stop |
        Where-Object { $wildcard.IsMatch($_.Name) })
    foreach ($directory in $roots) {
        $skipReason = Get-ChromeDirectorySkipReason -Directory $directory -ExcludedPatterns $excludedPatterns
        if (-not [string]::IsNullOrEmpty($skipReason)) {
            Write-Warning "[SKIP] '$($directory.FullName)': $skipReason."
            continue
        }

        # Isolate candidate-specific filesystem/discovery failures. A bad sibling is
        # never a reason to create a profile in it or to abort all valid siblings.
        try {
            $childRoot = Resolve-ChromeDirectory -LiteralPath $directory.FullName
            if ((Test-Path -LiteralPath (Join-Path -Path $childRoot -ChildPath 'Preferences') -PathType Leaf -ErrorAction Stop) -and
                -not (Test-Path -LiteralPath (Join-Path -Path $childRoot -ChildPath 'Local State') -PathType Leaf -ErrorAction Stop)) {
                throw 'This is an internal profile folder, not a user-data root. Use Standard mode with its parent as -UserDataDir.'
            }
            $cache = Get-ChromeInfoCache -Root $childRoot
            $profileFolders = @(Get-ChromeProfileFolder -Root $childRoot -InfoCache $cache)

            # Establish that this is a plausible root BEFORE honoring an explicit
            # profile name. Otherwise -ProfileDirectory Default could initialize
            # Chrome inside unrelated nonempty folders such as logs or backups.
            $isEmpty = $false
            $explicitExistingProfile = $false
            if ($profileFolders.Count -eq 0) {
                $isEmpty = @(Get-ChildItem -LiteralPath $childRoot -Force -ErrorAction Stop |
                    Select-Object -First 1).Count -eq 0
                if (-not [string]::IsNullOrWhiteSpace($InternalProfile)) {
                    $explicitPath = Join-Path -Path $childRoot -ChildPath $InternalProfile
                    if (Test-Path -LiteralPath $explicitPath -PathType Container -ErrorAction Stop) {
                        $explicitItem = Get-Item -LiteralPath $explicitPath -Force -ErrorAction Stop
                        if (($explicitItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                            $explicitExistingProfile = Test-Path -LiteralPath (
                                Join-Path -Path $explicitPath -ChildPath 'Preferences'
                            ) -PathType Leaf -ErrorAction Stop
                        }
                    }
                }
                if (-not $isEmpty -and -not $explicitExistingProfile) {
                    throw 'No recognizable Chrome profile in this nonempty directory; leaving its contents unchanged.'
                }
            }

            $selected = $null
            if (-not [string]::IsNullOrWhiteSpace($InternalProfile)) {
                $selected = $InternalProfile
                $selectedPath = Join-Path -Path $childRoot -ChildPath $selected
                if (Test-Path -LiteralPath $selectedPath -ErrorAction Stop) {
                    $selectedItem = Get-Item -LiteralPath $selectedPath -Force -ErrorAction Stop
                    if (-not $selectedItem.PSIsContainer -or
                        ($selectedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "Selected profile is not a regular directory: $selectedPath"
                    }
                }
                else {
                    Write-Verbose "Chrome will create profile '$selected' in '$childRoot' on execution."
                }
            }
            elseif (@($profileFolders | Where-Object { $_.Name -eq 'Default' }).Count -gt 0) {
                $selected = 'Default'
            }
            elseif ($profileFolders.Count -eq 1) { $selected = $profileFolders[0].Name }
            elseif ($profileFolders.Count -gt 1) {
                throw "Ambiguous profiles: $($profileFolders.Name -join ', '). Specify -ProfileDirectory with an internal folder name to select this root."
            }
            elseif ($isEmpty) { $selected = 'Default' }
            else {
                throw 'No safe internal profile selection is available.'
            }
        }
        catch {
            Write-Warning "[SKIP] '$($directory.FullName)': $($_.Exception.Message)"
            continue
        }

        [pscustomobject]@{
            Mode = 'Temp'; Folder = $directory.Name; DisplayName = $directory.Name
            UserDataDir = $childRoot; ProfileDirectory = $selected
        }
    }
}

function Resolve-ChromeExecutable {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $item = Get-Item -LiteralPath $ExplicitPath -Force -ErrorAction Stop
        if ($item.PSProvider.Name -ne 'FileSystem' -or $item.PSIsContainer -or $item.Name -ine 'chrome.exe') {
            throw 'ChromePath must point to an existing chrome.exe file.'
        }
        return $item.FullName
    }
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($basePath in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($basePath)) {
            $candidates.Add((Join-Path -Path $basePath -ChildPath 'Google\Chrome\Application\chrome.exe'))
        }
    }
    foreach ($registryPath in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    )) {
        $key = Get-Item -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($null -ne $key) {
            $registeredPath = [string]$key.GetValue('')
            if (-not [string]::IsNullOrWhiteSpace($registeredPath)) {
                $candidates.Add($registeredPath.Trim('"'))
            }
        }
    }
    $pathCommand = Get-Command -Name 'chrome.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $pathCommand) { $candidates.Add($pathCommand.Source) }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-ChromeExecutable -ExplicitPath $candidate)
        }
    }
    throw "Chrome was not found. Supply -ChromePath 'C:\path\to\chrome.exe'."
}

function ConvertTo-ChromeNativeArgument {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.IndexOf([char]0) -ge 0 -or $Value -match '[\r\n]') {
        throw 'Native arguments cannot contain NUL or newline characters.'
    }
    # Microsoft native-command-line quoting: double trailing backslashes and
    # backslashes before quotes. Always quote, including empty arguments.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function ConvertTo-ChromePowerShellLiteral {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-ChromeUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyCollection()][string[]]$Values)
    foreach ($value in $Values) {
        if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[\x00-\x20\x7f]') {
            throw 'URLs must be nonempty and cannot contain whitespace/control characters. Percent-encode spaces.'
        }
        if ($value -eq 'about:blank') { $value; continue }
        $uri = $null
        if (-not [uri]::TryCreate($value, [System.UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @('http', 'https') -or [string]::IsNullOrEmpty($uri.Host) -or
            -not [string]::IsNullOrEmpty($uri.UserInfo)) {
            throw "Unsupported URL '$value'. Use absolute HTTP/HTTPS URLs without embedded credentials, or about:blank."
        }
        $value
    }
}

function ConvertTo-ChromeHtmlText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    # System.Net.WebUtility is available in Windows PowerShell 5.1/.NET Framework and
    # PowerShell 7. Encode every user-derived value before inserting it into HTML.
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function New-ChromeProfileIdentifierUrl {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure string factory; no persistent or external state is changed.'
    )]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][pscustomobject]$ProfileRecord)

    $folderName = [string]$ProfileRecord.Folder
    $userDataDir = [string]$ProfileRecord.UserDataDir
    $profileDirectory = [string]$ProfileRecord.ProfileDirectory
    $fullProfilePath = Join-Path -Path $userDataDir -ChildPath $profileDirectory

    $encodedFolder = ConvertTo-ChromeHtmlText -Value $folderName
    $encodedUserData = ConvertTo-ChromeHtmlText -Value $userDataDir
    $encodedProfileDirectory = ConvertTo-ChromeHtmlText -Value $profileDirectory
    $encodedFullProfilePath = ConvertTo-ChromeHtmlText -Value $fullProfilePath

    # Keep the document self-contained. A data: URL avoids writing helper files into
    # the profile or filesystem and therefore cannot become stale when folders move.
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PROFILE - $encodedFolder</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f5f7fa;color:#1f2328}
main{max-width:960px;margin:48px auto;padding:32px;background:white;border:1px solid #d0d7de;border-radius:12px;box-shadow:0 4px 18px rgba(31,35,40,.08)}
h1{margin-top:0;font-size:32px} .label{font-weight:600;margin-top:20px}.value{font-family:Consolas,monospace;font-size:17px;padding:12px;background:#f6f8fa;border-radius:6px;overflow-wrap:anywhere}
.note{margin-top:28px;color:#57606a}
</style>
</head>
<body><main>
<h1>Chrome Profile: $encodedFolder</h1>
<div class="label">Temporary folder</div><div class="value">$encodedFolder</div>
<div class="label">User data directory</div><div class="value">$encodedUserData</div>
<div class="label">Internal profile directory</div><div class="value">$encodedProfileDirectory</div>
<div class="label">Full profile path</div><div class="value">$encodedFullProfilePath</div>
<div class="note">Keep this tab open when you want the Chrome window title to identify the temporary profile.</div>
</main></body></html>
"@

    return 'data:text/html;charset=utf-8,' + [System.Uri]::EscapeDataString($html)
}

function New-ChromeLaunchPlan {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory object factory; no persistent or external state is changed.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$ProfileRecord,
        [Parameter(Mandatory = $true)][string]$Executable,
        [AllowEmptyCollection()][string[]]$LaunchUrls,
        [Parameter(Mandatory = $true)][int]$Index,
        [bool]$IncludeProfileIdentifierTab = $true
    )

    $effectiveUrls = [System.Collections.Generic.List[string]]::new()
    if ($IncludeProfileIdentifierTab) {
        $effectiveUrls.Add((New-ChromeProfileIdentifierUrl -ProfileRecord $ProfileRecord))
    }
    foreach ($url in @($LaunchUrls)) { $effectiveUrls.Add($url) }

    $nativeArguments = @(
        '--user-data-dir=' + $ProfileRecord.UserDataDir
        '--profile-directory=' + $ProfileRecord.ProfileDirectory
        '--new-window'
        '--no-first-run'
        '--no-default-browser-check'
    ) + @($effectiveUrls)
    $argumentLine = ($nativeArguments | ForEach-Object { ConvertTo-ChromeNativeArgument -Value $_ }) -join ' '
    # Preview uses Start-Process as well, avoiding PS 5.1 / PS 7 native & quoting differences.
    $command = 'Start-Process -FilePath {0} -ArgumentList {1} -ErrorAction Stop' -f
        (ConvertTo-ChromePowerShellLiteral -Value $Executable), (ConvertTo-ChromePowerShellLiteral -Value $argumentLine)
    [pscustomobject]@{
        PSTypeName = 'ChromeProfileLauncher.Plan'
        Index = $Index; Mode = $ProfileRecord.Mode; DisplayName = $ProfileRecord.DisplayName
        UserDataDir = $ProfileRecord.UserDataDir; ProfileDirectory = $ProfileRecord.ProfileDirectory
        Executable = $Executable; Arguments = $nativeArguments; ArgumentLine = $argumentLine
        ProfileIdentifierTab = $IncludeProfileIdentifierTab
        Command = $command
    }
}

function Read-ChromeConfirmation {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Prompt)
    try { $answer = Read-Host -Prompt "$Prompt [y/N]" }
    catch { throw 'Interactive input is unavailable. Use -RunAll only when unattended execution is intended.' }
    return ($null -ne $answer -and $answer.Trim() -match '^(?i:y|yes)$')
}

function Read-ChromeBatchSize {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$Remaining)
    while ($true) {
        try {
            $answer = Read-Host -Prompt "$Remaining remaining. Next [5 / 10 / 15 / 20 / A=all / Q=quit] (Enter quits)"
        }
        catch { throw 'Interactive input is unavailable; remaining profiles were not launched.' }
        if ([string]::IsNullOrWhiteSpace($answer)) { return 0 }
        switch ($answer.Trim().ToUpperInvariant()) {
            'Q' { return 0 }
            'QUIT' { return 0 }
            'A' { return $Remaining }
            'ALL' { return $Remaining }
            '5' { return [Math]::Min(5, $Remaining) }
            '10' { return [Math]::Min(10, $Remaining) }
            '15' { return [Math]::Min(15, $Remaining) }
            '20' { return [Math]::Min(20, $Remaining) }
            default { Write-ChromeMessage 'Choose 5, 10, 15, 20, A, or Q.' }
        }
    }
}

function New-ChromeLaunchResult {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory object factory; no persistent or external state is changed.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Plan,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][Nullable[int]]$RequestedProcessId,
        [AllowNull()][string]$ErrorMessage
    )
    [pscustomobject]@{
        PSTypeName = 'ChromeProfileLauncher.Result'
        TimestampUtc = [DateTime]::UtcNow; Index = $Plan.Index; Mode = $Plan.Mode
        DisplayName = $Plan.DisplayName; UserDataDir = $Plan.UserDataDir
        ProfileDirectory = $Plan.ProfileDirectory; Status = $Status
        RequestedProcessId = $RequestedProcessId; ErrorMessage = $ErrorMessage
        Command = $Plan.Command
    }
}

function Invoke-ChromeLaunchRequest {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][pscustomobject]$Plan)

    if (-not $PSCmdlet.ShouldProcess($Plan.UserDataDir, "Launch profile '$($Plan.ProfileDirectory)'")) {
        return (New-ChromeLaunchResult -Plan $Plan -Status 'Skipped')
    }
    # This operation has already been approved. Suppress nested cmdlet prompts;
    # Start-Process in Windows PowerShell 5.1 has no -Confirm parameter.
    $ConfirmPreference = 'None'
    $process = $null
    try {
        # One correctly quoted string; never use Invoke-Expression or cmd.exe.
        $process = Start-Process -FilePath $Plan.Executable -ArgumentList $Plan.ArgumentLine -PassThru -ErrorAction Stop
        if ($null -eq $process) { throw 'Start-Process returned no process object.' }
        return (New-ChromeLaunchResult -Plan $Plan -Status 'LaunchRequested' -RequestedProcessId $process.Id)
    }
    catch {
        return (New-ChromeLaunchResult -Plan $Plan -Status 'Failed' -ErrorMessage $_.Exception.Message)
    }
    finally {
        # Disposes our process handle only; does NOT terminate Chrome.
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Get-ChromeWindowProcess {
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param([Parameter(Mandatory = $true)][int]$SessionId)
    $processes = @(Get-Process -Name chrome -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        try {
            $process.Refresh()
            if ($process.SessionId -eq $SessionId -and $process.MainWindowHandle -ne [IntPtr]::Zero) {
                $process
            }
            else { $process.Dispose() }
        }
        catch { $process.Dispose() } # Normal race: Chrome exited after enumeration.
    }
}

function Invoke-ChromeGracefulClose {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Targets,
        [Parameter(Mandatory = $true)][ValidateRange(1, 300)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$SessionId
    )
    if (-not $PSCmdlet.ShouldProcess("$($Targets.Count) Chrome window-owning processes in session $SessionId", 'Request graceful close')) {
        return [pscustomobject]@{ Mode = 'Close'; Status = 'Skipped'; RemainingProcessIds = @() }
    }
    $identities = @{}
    foreach ($target in $Targets) {
        try { $identities[$target.Id] = $target.StartTime.ToUniversalTime().Ticks }
        catch { Write-Verbose "Process $($target.Id) exited before the close request." }
    }
    $requestedHandles = [System.Collections.Generic.HashSet[string]]::new()
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $remainingIds = @()
    do {
        $current = @(Get-ChromeWindowProcess -SessionId $SessionId)
        $remainingIds = @()
        foreach ($process in $current) {
            try {
                # Snapshot identity protects against newly opened processes and PID reuse.
                if (-not $identities.ContainsKey($process.Id) -or
                    $identities[$process.Id] -ne $process.StartTime.ToUniversalTime().Ticks) { continue }
                $remainingIds += $process.Id
                $handleKey = '{0}:{1}' -f $process.Id, $process.MainWindowHandle.ToInt64()
                if ($requestedHandles.Add($handleKey)) {
                    if (-not $process.CloseMainWindow()) {
                        Write-Warning "Chrome process $($process.Id) did not accept the close request."
                    }
                }
            }
            catch { Write-Verbose "Chrome process changed during close: $($_.Exception.Message)" }
            finally { $process.Dispose() }
        }
        if ($remainingIds.Count -eq 0 -or $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Start-Sleep -Milliseconds 250
    } while ($true)
    $timer.Stop()
    [pscustomobject]@{
        PSTypeName = 'ChromeProfileLauncher.CloseResult'
        Mode = 'Close'; TimestampUtc = [DateTime]::UtcNow
        Status = $(if ($remainingIds.Count -eq 0) { 'Closed' } else { 'TimedOut' })
        RemainingProcessIds = $remainingIds
    }
}

# ----------------------------- Orchestration -----------------------------
if ($env:OS -ne 'Windows_NT') { throw 'This script requires Windows. No browser operation was performed.' }

# Parameter sets make execution switches exclusive. Validate mode-specific options
# explicitly: Mode is a value, NOT a PowerShell parameter-set discriminator.
$allowedByMode = @{
    UserDataDir = @('Standard')
    TempDir = @('Temp')
    ProfileDirectory = @('Temp')
    ExcludeDirectory = @('Temp')
    ChromePath = @('Standard', 'Temp')
    ProfileFilter = @('Standard', 'Temp')
    StartIndex = @('Standard', 'Temp')
    MaxProfiles = @('Standard', 'Temp')
    Urls = @('Standard', 'Temp')
    LaunchDelayMilliseconds = @('Standard', 'Temp')
    StopOnError = @('Standard', 'Temp')
    CloseTimeoutSeconds = @('Close')
}
foreach ($parameterName in $allowedByMode.Keys) {
    if ($PSBoundParameters.ContainsKey($parameterName) -and $Mode -notin $allowedByMode[$parameterName]) {
        throw "-$parameterName is not valid in $Mode mode."
    }
}
if ($RunAll -and $PSBoundParameters.ContainsKey('Confirm') -and [bool]$PSBoundParameters['Confirm']) {
    throw '-RunAll and -Confirm:$true conflict. Use -Run, or remove -Confirm.'
}
if ($RunAll) {
    # Local scope only. Always preserve WhatIf even during unattended execution.
    $ConfirmPreference = 'None'
    if (-not $PSBoundParameters.ContainsKey('LaunchDelayMilliseconds')) { $LaunchDelayMilliseconds = 0 }
}
if ($ProfileDirectory -in @('System Profile', 'Guest Profile')) {
    throw 'ProfileDirectory cannot select Chrome internal System Profile or Guest Profile folders.'
}
$execute = [bool]($Run -or $RunAll)

if ($Mode -eq 'Close') {
    $self = [System.Diagnostics.Process]::GetCurrentProcess()
    try { $sessionId = $self.SessionId }
    finally { $self.Dispose() }
    $targets = @(Get-ChromeWindowProcess -SessionId $sessionId)
    try {
        if ($targets.Count -eq 0) { Write-ChromeMessage 'No Chrome windows found in the current Windows session.'; return }
        if (-not $execute -or $WhatIfPreference) {
            foreach ($target in $targets) {
                $description = 'Chrome process {0}, session {1}' -f $target.Id, $sessionId
                if ($WhatIfPreference) { [void]$PSCmdlet.ShouldProcess($description, 'Request graceful close') }
                if ($PassThru) {
                    [pscustomobject]@{ Mode = 'Close'; Status = 'Preview'; ProcessId = $target.Id; SessionId = $sessionId }
                }
                else { Write-Output "# Would request graceful close: $description" }
            }
            Write-ChromeMessage 'Preview only. Use Close -Run for confirmation or Close -RunAll for unattended close.'
            return
        }
        if ($Run -and -not (Read-ChromeConfirmation -Prompt 'Close ALL Chrome windows in this Windows session? Unsaved work may be affected.')) {
            Write-ChromeMessage 'Cancelled. No close requests were sent.'; return
        }
        if ($PSCmdlet.ShouldProcess("Chrome in Windows session $sessionId", 'Request graceful close of all current Chrome windows')) {
            $closeResult = Invoke-ChromeGracefulClose -Targets $targets -TimeoutSeconds $CloseTimeoutSeconds -SessionId $sessionId -Confirm:$false
            if ($PassThru) { $closeResult }
            if ($closeResult.Status -eq 'TimedOut') {
                throw "Graceful close timed out. Remaining process IDs: $($closeResult.RemainingProcessIds -join ', '). Resolve browser dialogs manually; no process was force-killed."
            }
            Write-ChromeMessage 'The targeted Chrome processes no longer expose a main window. Background Chrome processes may remain.'
        }
    }
    finally { foreach ($target in $targets) { $target.Dispose() } }
    return
}

$rootPath = if ($Mode -eq 'Standard') { $UserDataDir } else { $TempDir }
$rootPath = Resolve-ChromeDirectory -LiteralPath $rootPath
$executable = Resolve-ChromeExecutable -ExplicitPath $ChromePath
$discovered = @(Get-ChromeProfile -DiscoveryMode $Mode -Root $rootPath -InternalProfile $ProfileDirectory -Filter $ProfileFilter -ExcludedDirectories $ExcludeDirectory)
# Natural ordering: Session2 precedes Session10. Folder name breaks equal-label ties.
$ordered = @($discovered | Sort-Object -Property @(
    @{ Expression = { [regex]::Replace($_.DisplayName, '\d+', { param($match) $match.Value.PadLeft(24, '0') }) } },
    @{ Expression = { $_.Folder } }
))
if ($ordered.Count -eq 0) { Write-ChromeMessage 'No matching profiles found. No browser operation was performed.'; return }
if ($StartIndex -gt $ordered.Count) { throw "StartIndex $StartIndex exceeds the $($ordered.Count) matching profiles." }
$selectedProfiles = @($ordered | Select-Object -Skip ($StartIndex - 1) -First $MaxProfiles)
if (-not $PSBoundParameters.ContainsKey('Urls')) {
    $Urls = if ($Mode -eq 'Temp') {
        @('https://gemini.google.com/app', 'https://chatgpt.com', 'https://seaart.ai')
    }
    else { @('about:blank') }
}
$validatedUrls = @(Get-ChromeUrl -Values $Urls)
if ($validatedUrls.Count -eq 0) { $validatedUrls = @('about:blank') }
$plans = @(
    for ($index = 0; $index -lt $selectedProfiles.Count; $index++) {
        New-ChromeLaunchPlan -ProfileRecord $selectedProfiles[$index] -Executable $executable -LaunchUrls $validatedUrls -Index ($StartIndex + $index) -IncludeProfileIdentifierTab (-not $NoProfileIdentifierTab)
    }
)
Write-ChromeMessage ("Selected {0} profile(s) from {1} matching profile(s). Mode: {2}." -f $plans.Count, $ordered.Count, $Mode)

if (-not $execute -or $WhatIfPreference) {
    foreach ($plan in $plans) {
        if ($WhatIfPreference) { [void]$PSCmdlet.ShouldProcess($plan.UserDataDir, "Launch profile '$($plan.ProfileDirectory)'") }
        if ($PassThru) { $plan }
        else { Write-Output $plan.Command }
    }
    Write-ChromeMessage 'Preview only. No profiles were started. Use -Run or -RunAll to execute.'
    return
}

$batchSize = if ($RunAll) { $plans.Count } else { [Math]::Min(5, $plans.Count) }
if ($Run) {
    Write-ChromeMessage "First batch from '$rootPath':"
    for ($previewIndex = 0; $previewIndex -lt $batchSize; $previewIndex++) {
        $previewPlan = $plans[$previewIndex]
        Write-ChromeMessage ("  {0}. {1} -> {2}" -f $previewPlan.Index, $previewPlan.DisplayName, $previewPlan.ProfileDirectory)
    }
}
if ($Run -and -not (Read-ChromeConfirmation -Prompt "Launch the first $batchSize of $($plans.Count) selected Chrome profiles?")) {
    Write-ChromeMessage 'Cancelled. No profiles were started.'; return
}
$next = 0
$requested = 0
$failed = 0
$skipped = 0
try {
    while ($next -lt $plans.Count -and $batchSize -gt 0) {
        $endExclusive = [Math]::Min($next + $batchSize, $plans.Count)
        for (; $next -lt $endExclusive; $next++) {
            $plan = $plans[$next]
            if ($PSCmdlet.ShouldProcess($plan.UserDataDir, "Launch profile '$($plan.ProfileDirectory)'")) {
                $result = Invoke-ChromeLaunchRequest -Plan $plan -Confirm:$false
            }
            else { $result = New-ChromeLaunchResult -Plan $plan -Status 'Skipped' }
            switch ($result.Status) {
                'LaunchRequested' {
                    $requested++
                    Write-ChromeMessage ("[{0}/{1}] Launch requested: {2} ({3})" -f ($next + 1), $plans.Count, $plan.DisplayName, $plan.ProfileDirectory)
                }
                'Failed' {
                    $failed++
                    Write-Warning ("Failed: {0}. {1}" -f $plan.DisplayName, $result.ErrorMessage)
                }
                default { $skipped++ }
            }
            if ($PassThru) { $result }
            if ($result.Status -eq 'Failed' -and $StopOnError) {
                $next++
                throw "Launch failed for '$($plan.DisplayName)': $($result.ErrorMessage)"
            }
            if ($LaunchDelayMilliseconds -gt 0 -and ($next + 1) -lt $endExclusive) {
                Start-Sleep -Milliseconds $LaunchDelayMilliseconds
            }
        }
        if ($next -lt $plans.Count -and $Run) {
            Write-ChromeMessage ("Progress: {0} requested, {1} failed, {2} skipped; {3} not attempted." -f $requested, $failed, $skipped, ($plans.Count - $next))
            Write-ChromeMessage ("Resume unattempted profiles with the same mode/paths/filter and -StartIndex {0} -MaxProfiles {1}, provided the discovery list has not changed." -f $plans[$next].Index, ($plans.Count - $next))
            $batchSize = Read-ChromeBatchSize -Remaining ($plans.Count - $next)
        }
    }
}
finally {
    Write-ChromeMessage ("Summary: {0} requested; {1} failed; {2} skipped; {3} not attempted." -f $requested, $failed, $skipped, ($plans.Count - ($requested + $failed + $skipped)))
}
if ($failed -gt 0) { throw "$failed Chrome launch request(s) failed. Review the warnings above." }
if ($next -lt $plans.Count) { Write-ChromeMessage 'Stopped by the user. Already launched profiles remain open.' }
