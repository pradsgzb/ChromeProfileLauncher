#requires -Version 5.1
# Pester 5.7.1. All process launches are mocked. No real Chrome data is used.
BeforeAll {
    $script:Sut = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\chrome.ps1')).Path
    $tokens = $null
    $parseErrors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Sut, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
    # Load only function definitions, not the parameter binding or orchestration.
    # This keeps the delivered launcher a single file without a testing-only switch.
    foreach ($definition in $script:Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    function New-TestProcess {
        param([int]$Id = 12345)
        $process = [pscustomobject]@{
            Id = $Id
            StartTime = [datetime]'2026-01-01T00:00:00Z'
            MainWindowHandle = [IntPtr]100
            Disposed = $false
            CloseCount = 0
        }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
        $process | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $this.CloseCount++; return $true }
        return $process
    }
    function New-TestDirectory {
        param([string]$Path)
        [void](New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop)
        return (Get-Item -LiteralPath $Path).FullName
    }
    function New-TestPlan {
        $profileRecord = [pscustomobject]@{
            Mode = 'Temp'
            DisplayName = 'Session 1'
            UserDataDir = 'D:\Temp\Chrome\Session 1'
            ProfileDirectory = 'Default'
        }
        New-ChromeLaunchPlan -ProfileRecord $profileRecord -Executable 'C:\Program Files\Google\Chrome\Application\chrome.exe' -LaunchUrls @('https://example.com') -Index 1
    }
}

Describe 'Native argument quoting and command plans' {
    It 'Quotes <Value> without losing native characters' -TestCases @(
        @{ Value = ''; Expected = '""' }
        @{ Value = 'plain'; Expected = '"plain"' }
        @{ Value = 'C:\space here\Profile 1'; Expected = '"C:\space here\Profile 1"' }
        @{ Value = 'C:\'; Expected = '"C:\\"' }
        @{ Value = 'C:\Temp\'; Expected = '"C:\Temp\\"' }
        @{ Value = 'a"b'; Expected = '"a\"b"' }
        @{ Value = 'a\"b'; Expected = '"a\\\"b"' }
        @{ Value = "O'Brien"; Expected = '"O''Brien"' }
    ) {
        param($Value, $Expected)
        ConvertTo-ChromeNativeArgument -Value $Value | Should -BeExactly $Expected
    }
    It 'Rejects newlines in native arguments' {
        { ConvertTo-ChromeNativeArgument -Value "first`nsecond" } | Should -Throw
    }
    It 'Rejects NUL in native arguments' {
        { ConvertTo-ChromeNativeArgument -Value ("first" + [char]0 + 'second') } | Should -Throw
    }
    It 'Escapes apostrophes for copyable PowerShell commands' {
        ConvertTo-ChromePowerShellLiteral -Value "O'Brien" | Should -BeExactly "'O''Brien'"
    }
    It 'Includes both profile switches and never appends a bare directory argument' {
        $plan = New-TestPlan
        $plan.Arguments.Count | Should -Be 6
        $plan.Arguments[0] | Should -BeExactly '--user-data-dir=D:\Temp\Chrome\Session 1'
        $plan.Arguments[1] | Should -BeExactly '--profile-directory=Default'
        $plan.Arguments | Should -Contain '--new-window'
        $plan.Arguments | Should -Contain '--no-first-run'
        $plan.Arguments | Should -Contain '--no-default-browser-check'
        $plan.Arguments[-1] | Should -BeExactly 'https://example.com'
    }
    It 'Emits preview commands that the PowerShell parser accepts' {
        $plan = New-TestPlan
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($plan.Command, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $plan.Command | Should -Match '^Start-Process -FilePath '
    }
    It 'Does not evaluate PowerShell-looking text while constructing commands' {
        $literal = ConvertTo-ChromePowerShellLiteral -Value '$(Get-Process); $env:TEMP'
        $literal | Should -BeExactly '''$(Get-Process); $env:TEMP'''
    }
}

Describe 'URL validation' {
    It 'Accepts approved URL <Value>' -TestCases @(
        @{ Value = 'https://example.com/path?a=1&b=2' }
        @{ Value = 'http://localhost:8080/' }
        @{ Value = 'https://example.com/a%20b' }
        @{ Value = 'about:blank' }
    ) {
        param($Value)
        @(Get-ChromeUrl -Values @($Value))[0] | Should -BeExactly $Value
    }
    It 'Rejects unsafe or malformed URL <Value>' -TestCases @(
        @{ Value = '--disable-web-security' }
        @{ Value = 'javascript:alert(1)' }
        @{ Value = 'file:///C:/secret.txt' }
        @{ Value = 'https://user:password@example.com/' }
        @{ Value = 'https://example.com/a b' }
        @{ Value = '' }
        @{ Value = 'not-a-url' }
    ) {
        param($Value)
        { Get-ChromeUrl -Values @($Value) } | Should -Throw
    }
    It 'Allows an empty URL collection for caller-supplied blank-tab fallback' {
        @(Get-ChromeUrl -Values @()).Count | Should -Be 0
    }
}

Describe 'Safe profile discovery' {
    BeforeEach {
        $script:Root = New-TestDirectory -Path (Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N')))
    }
    It 'Uses Default for an empty isolated user-data directory without creating files' {
        $session = New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Session1')
        $profiles = @(Get-ChromeProfile -DiscoveryMode Temp -Root $script:Root -Filter '*')
        $profiles.Count | Should -Be 1
        $profiles[0].ProfileDirectory | Should -Be 'Default'
        @(Get-ChildItem -LiteralPath $session -Force).Count | Should -Be 0
    }
    It 'Uses the single existing profile instead of creating a new Default' {
        [void](New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Session1\Profile 3'))
        $profiles = @(Get-ChromeProfile -DiscoveryMode Temp -Root $script:Root -Filter '*')
        $profiles[0].ProfileDirectory | Should -Be 'Profile 3'
    }
    It 'Selects Default when Default and another profile both exist' {
        [void](New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Session1\Default'))
        [void](New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Session1\Profile 3'))
        @(Get-ChromeProfile -DiscoveryMode Temp -Root $script:Root -Filter '*')[0].ProfileDirectory | Should -Be 'Default'
    }
    It 'Rejects ambiguous roots that contain multiple non-Default profiles' {
        [void](New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Session1\Profile 1'))
        [void](New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Session1\Profile 2'))
        { Get-ChromeProfile -DiscoveryMode Temp -Root $script:Root -Filter '*' } | Should -Throw '*Ambiguous*'
    }
    It 'Honors an explicit internal profile without creating it during discovery' {
        $session = New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Session1')
        $profiles = @(Get-ChromeProfile -DiscoveryMode Temp -Root $script:Root -InternalProfile 'Profile 2' -Filter '*')
        $profiles[0].ProfileDirectory | Should -Be 'Profile 2'
        Test-Path -LiteralPath (Join-Path -Path $session -ChildPath 'Profile 2') | Should -BeFalse
    }
    It 'Rejects pointing TempDir at a single Chrome user-data root' {
        '{}' | Set-Content -LiteralPath (Join-Path -Path $script:Root -ChildPath 'Local State')
        { Get-ChromeProfile -DiscoveryMode Temp -Root $script:Root -Filter '*' } | Should -Throw '*single Chrome user-data root*'
    }
    It 'Rejects confusing a profile folder with a user-data root' {
        $session = New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Session1')
        '{}' | Set-Content -LiteralPath (Join-Path -Path $session -ChildPath 'Preferences')
        { Get-ChromeProfile -DiscoveryMode Temp -Root $script:Root -Filter '*' } | Should -Throw '*profile folder*'
    }
    It 'Rejects nonempty unrelated directories unless selection is explicit' {
        $session = New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Session1')
        'unrelated' | Set-Content -LiteralPath (Join-Path -Path $session -ChildPath 'notes.txt')
        { Get-ChromeProfile -DiscoveryMode Temp -Root $script:Root -Filter '*' } | Should -Throw '*No recognizable profile*'
    }
    It 'Filters temporary root folder names' {
        [void](New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Session1'))
        [void](New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Other1'))
        $profiles = @(Get-ChromeProfile -DiscoveryMode Temp -Root $script:Root -Filter 'Session*')
        $profiles.Count | Should -Be 1
        $profiles[0].Folder | Should -Be 'Session1'
    }
    It 'Discovers Standard profiles without requiring Local State' {
        foreach ($name in @('Default', 'Profile 1', 'System Profile', 'Guest Profile', 'ProfileBackup')) {
            [void](New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath $name))
        }
        $profiles = @(Get-ChromeProfile -DiscoveryMode Standard -Root $script:Root -Filter '*')
        $profiles.Count | Should -Be 2
        $profiles.Folder | Should -Contain 'Default'
        $profiles.Folder | Should -Contain 'Profile 1'
    }
    It 'Reads Standard profile labels and supports custom metadata-listed folders' {
        [void](New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'CustomWork'))
        '{"profile":{"info_cache":{"CustomWork":{"name":"Work Account"}}}}' |
            Set-Content -LiteralPath (Join-Path -Path $script:Root -ChildPath 'Local State') -Encoding UTF8
        $profiles = @(Get-ChromeProfile -DiscoveryMode Standard -Root $script:Root -Filter 'Work*')
        $profiles.Count | Should -Be 1
        $profiles[0].DisplayName | Should -Be 'Work Account'
    }
    It 'Falls back to directory names when JSON is malformed' {
        [void](New-TestDirectory -Path (Join-Path -Path $script:Root -ChildPath 'Default'))
        '{broken' | Set-Content -LiteralPath (Join-Path -Path $script:Root -ChildPath 'Local State')
        Mock Start-Sleep {}
        $profiles = @(Get-ChromeProfile -DiscoveryMode Standard -Root $script:Root -Filter '*' -WarningAction SilentlyContinue)
        $profiles.Count | Should -Be 1
        $profiles[0].DisplayName | Should -Be 'Default'
        Should -Invoke Start-Sleep -Exactly -Times 2
    }
}

Describe 'Interactive menu' {
    It 'Maps menu choice <Choice> to <Expected>' -TestCases @(
        @{ Choice = '5'; Expected = 5 }
        @{ Choice = '10'; Expected = 10 }
        @{ Choice = '15'; Expected = 15 }
        @{ Choice = '20'; Expected = 20 }
        @{ Choice = 'A'; Expected = 37 }
        @{ Choice = 'all'; Expected = 37 }
        @{ Choice = 'q'; Expected = 0 }
        @{ Choice = ''; Expected = 0 }
        @{ Choice = ' 10 '; Expected = 10 }
    ) {
        param($Choice, $Expected)
        $script:MenuValue = $Choice
        Mock Read-Host { $script:MenuValue }
        Read-ChromeBatchSize -Remaining 37 | Should -Be $Expected
    }
    It 'Caps a requested batch at the remaining count' {
        Mock Read-Host { '20' }
        Read-ChromeBatchSize -Remaining 3 | Should -Be 3
    }
    It 'Re-prompts on invalid input without launching anything' {
        $script:MenuCalls = 0
        Mock Read-Host { $script:MenuCalls++; if ($script:MenuCalls -eq 1) { 'invalid' } else { '5' } }
        Mock Write-ChromeMessage {}
        Read-ChromeBatchSize -Remaining 8 | Should -Be 5
        Should -Invoke Read-Host -Exactly -Times 2
    }
    It 'Defaults initial confirmation to no' {
        Mock Read-Host { '' }
        Read-ChromeConfirmation -Prompt 'Proceed?' | Should -BeFalse
    }
    It 'Accepts an explicit yes' {
        Mock Read-Host { ' YES ' }
        Read-ChromeConfirmation -Prompt 'Proceed?' | Should -BeTrue
    }
    It 'Fails closed when interactive input is unavailable' {
        Mock Read-Host { throw 'NonInteractive' }
        { Read-ChromeConfirmation -Prompt 'Proceed?' } | Should -Throw '*unavailable*'
    }
}

Describe 'Process adapter' {
    It 'Returns LaunchRequested and disposes the local process handle' {
        $script:Process = New-TestProcess
        Mock Start-Process { $script:Process }
        $result = Invoke-ChromeLaunchRequest -Plan (New-TestPlan) -Confirm:$false
        $result.Status | Should -Be 'LaunchRequested'
        $result.RequestedProcessId | Should -Be 12345
        $script:Process.Disposed | Should -BeTrue
        Should -Invoke Start-Process -Exactly -Times 1
    }
    It 'Returns a failure record instead of pretending the browser loaded' {
        Mock Start-Process { throw 'Access denied' }
        $result = Invoke-ChromeLaunchRequest -Plan (New-TestPlan) -Confirm:$false
        $result.Status | Should -Be 'Failed'
        $result.ErrorMessage | Should -Match 'Access denied'
    }
    It 'Never calls Start-Process under WhatIf' {
        Mock Start-Process { throw 'A browser must not be launched' }
        $result = Invoke-ChromeLaunchRequest -Plan (New-TestPlan) -WhatIf
        $result.Status | Should -Be 'Skipped'
        Should -Invoke Start-Process -Exactly -Times 0
    }
}

Describe 'Windows orchestration with mocked browser processes' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeEach {
        $script:Parent = New-TestDirectory -Path (Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N')))
        $script:TempRoot = New-TestDirectory -Path (Join-Path -Path $script:Parent -ChildPath 'Sessions')
        for ($index = 1; $index -le 37; $index++) {
            [void](New-TestDirectory -Path (Join-Path -Path $script:TempRoot -ChildPath "Session$index"))
        }
        $script:FakeChrome = Join-Path -Path $script:Parent -ChildPath 'chrome.exe'
        'Not an executable; Start-Process MUST be mocked.' | Set-Content -LiteralPath $script:FakeChrome
        $script:LaunchCount = 0
        $script:Answers = [System.Collections.Generic.Queue[string]]::new()
        Mock Start-Process { $script:LaunchCount++; New-TestProcess -Id (1000 + $script:LaunchCount) }
        Mock Start-Sleep {}
        Mock Read-Host {
            if ($script:Answers.Count -eq 0) { throw 'Unexpected prompt: test answer queue is empty.' }
            $script:Answers.Dequeue()
        }
        $script:Common = @{ Mode = 'Temp'; TempDir = $script:TempRoot; ChromePath = $script:FakeChrome }
    }
    It 'Preserves preview as the default with no prompts or launches' {
        $commands = @(& $script:Sut @script:Common)
        $commands.Count | Should -Be 37
        Should -Invoke Start-Process -Exactly -Times 0
        Should -Invoke Read-Host -Exactly -Times 0
    }
    It 'Supports structured plans and natural ordering' {
        $plans = @(& $script:Sut @script:Common -PassThru)
        $plans[1].DisplayName | Should -Be 'Session2'
        $plans[9].DisplayName | Should -Be 'Session10'
        $plans[0].Arguments.Count | Should -Be 8
    }
    It 'Does not launch before confirmation and stops after the initial five on Q' {
        $script:Answers.Enqueue('Y')
        $script:Answers.Enqueue('Q')
        Mock Read-Host {
            if ($script:Answers.Count -eq 2) { $script:LaunchCount | Should -Be 0 }
            if ($script:Answers.Count -eq 1) { $script:LaunchCount | Should -Be 5 }
            $script:Answers.Dequeue()
        }
        & $script:Sut @script:Common -Run
        $script:LaunchCount | Should -Be 5
        Should -Invoke Read-Host -Exactly -Times 2
    }
    It 'Supports initial five then the requested next <Choice> profiles' -TestCases @(
        @{ Choice = '5'; Expected = 10 }
        @{ Choice = '10'; Expected = 15 }
        @{ Choice = '15'; Expected = 20 }
        @{ Choice = '20'; Expected = 25 }
    ) {
        param($Choice, $Expected)
        $script:Answers.Enqueue('Y')
        $script:Answers.Enqueue($Choice)
        $script:Answers.Enqueue('Q')
        & $script:Sut @script:Common -Run
        $script:LaunchCount | Should -Be $Expected
    }
    It 'Supports all remaining profiles from the continuation menu' {
        $script:Answers.Enqueue('Y')
        $script:Answers.Enqueue('ALL')
        & $script:Sut @script:Common -Run
        $script:LaunchCount | Should -Be 37
        Should -Invoke Read-Host -Exactly -Times 2
    }
    It 'Launches fewer than five when only three are selected' {
        $script:Answers.Enqueue('Y')
        & $script:Sut @script:Common -Run -MaxProfiles 3
        $script:LaunchCount | Should -Be 3
        Should -Invoke Read-Host -Exactly -Times 1
    }
    It 'Cancels before any launch when initial confirmation is blank' {
        $script:Answers.Enqueue('')
        & $script:Sut @script:Common -Run
        $script:LaunchCount | Should -Be 0
    }
    It 'Starts all profiles without prompts or sleeps using RunAll' {
        & $script:Sut @script:Common -RunAll
        $script:LaunchCount | Should -Be 37
        Should -Invoke Read-Host -Exactly -Times 0
        Should -Invoke Start-Sleep -Exactly -Times 0
    }
    It 'Honors an explicitly supplied RunAll delay between launches only' {
        & $script:Sut @script:Common -RunAll -MaxProfiles 3 -LaunchDelayMilliseconds 250
        Should -Invoke Start-Sleep -Exactly -Times 2 -ParameterFilter { $Milliseconds -eq 250 }
    }
    It 'Suppresses ambient confirmation preferences in RunAll' {
        $ConfirmPreference = 'Low'
        try { & $script:Sut @script:Common -RunAll -MaxProfiles 2 }
        finally { $ConfirmPreference = 'High' }
        $script:LaunchCount | Should -Be 2
        Should -Invoke Read-Host -Exactly -Times 0
    }
    It 'Honors WhatIf in interactive and unattended execution' -TestCases @(
        @{ Execution = 'Run' }
        @{ Execution = 'RunAll' }
    ) {
        param($Execution)
        $arguments = @{} + $script:Common
        $arguments[$Execution] = $true
        & $script:Sut @arguments -WhatIf
        Should -Invoke Start-Process -Exactly -Times 0
        Should -Invoke Read-Host -Exactly -Times 0
    }
    It 'Applies selection offset and limit before launch' {
        $results = @(& $script:Sut @script:Common -RunAll -StartIndex 6 -MaxProfiles 2 -PassThru)
        $results.Count | Should -Be 2
        $results[0].Index | Should -Be 6
        $results[0].DisplayName | Should -Be 'Session6'
    }
    It 'Continues after a failure and throws an aggregate error at the end' {
        Mock Start-Process {
            $script:LaunchCount++
            if ($script:LaunchCount -eq 3) { throw 'Simulated launch failure' }
            New-TestProcess -Id (1000 + $script:LaunchCount)
        }
        { & $script:Sut @script:Common -RunAll -MaxProfiles 6 -WarningAction SilentlyContinue } | Should -Throw '*1 Chrome launch request*'
        $script:LaunchCount | Should -Be 6
    }
    It 'Stops on the first error when requested' {
        Mock Start-Process { $script:LaunchCount++; throw 'Simulated failure' }
        { & $script:Sut @script:Common -RunAll -StopOnError -WarningAction SilentlyContinue } | Should -Throw '*Launch failed*'
        $script:LaunchCount | Should -Be 1
    }
    It 'Rejects Run and RunAll together' {
        { & $script:Sut @script:Common -Run -RunAll } | Should -Throw
        $script:LaunchCount | Should -Be 0
    }
    It 'Rejects contradictory RunAll and Confirm switches' {
        { & $script:Sut @script:Common -RunAll -Confirm } | Should -Throw '*conflict*'
        $script:LaunchCount | Should -Be 0
    }
    It 'Rejects a mode-incompatible parameter' {
        { & $script:Sut @script:Common -UserDataDir $script:TempRoot } | Should -Throw '*not valid*'
    }
    It 'Rejects an out-of-range start index before launching' {
        { & $script:Sut @script:Common -RunAll -StartIndex 38 } | Should -Throw '*exceeds*'
        $script:LaunchCount | Should -Be 0
    }
    It 'Never closes a browser in default Close preview mode' {
        Mock Get-Process { @() } -ParameterFilter { $Name -eq 'chrome' }
        & $script:Sut Close
        Should -Invoke Read-Host -Exactly -Times 0
        Should -Invoke Start-Process -Exactly -Times 0
    }
}

Describe 'Graceful close adapter with fake processes' {
    It 'Does nothing under WhatIf' {
        $target = New-TestProcess
        Mock Get-ChromeWindowProcess { throw 'Should not enumerate after denied operation' }
        $result = Invoke-ChromeGracefulClose -Targets @($target) -TimeoutSeconds 1 -SessionId 1 -WhatIf
        $result.Status | Should -Be 'Skipped'
        $target.CloseCount | Should -Be 0
    }
    It 'Requests close once and returns after the targeted window disappears' {
        $script:CloseTarget = New-TestProcess
        $script:Poll = 0
        Mock Get-ChromeWindowProcess {
            $script:Poll++
            if ($script:Poll -eq 1) { $script:CloseTarget }
        }
        Mock Start-Sleep {}
        $result = Invoke-ChromeGracefulClose -Targets @($script:CloseTarget) -TimeoutSeconds 1 -SessionId 1 -Confirm:$false
        $result.Status | Should -Be 'Closed'
        $script:CloseTarget.CloseCount | Should -Be 1
    }
    It 'Does not close a replacement process that reuses the original PID' {
        $original = New-TestProcess
        $script:Replacement = New-TestProcess
        $script:Replacement.StartTime = $original.StartTime.AddSeconds(10)
        Mock Get-ChromeWindowProcess { $script:Replacement }
        $result = Invoke-ChromeGracefulClose -Targets @($original) -TimeoutSeconds 1 -SessionId 1 -Confirm:$false
        $result.Status | Should -Be 'Closed'
        $script:Replacement.CloseCount | Should -Be 0
    }
    It 'Reports a timeout without repeatedly sending close to the same handle' {
        $script:Blocked = New-TestProcess
        Mock Get-ChromeWindowProcess { $script:Blocked }
        $result = Invoke-ChromeGracefulClose -Targets @($script:Blocked) -TimeoutSeconds 1 -SessionId 1 -Confirm:$false
        $result.Status | Should -Be 'TimedOut'
        $result.RemainingProcessIds | Should -Contain 12345
        $script:Blocked.CloseCount | Should -Be 1
    }
}

Describe 'Windows native argument round trip' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        if ($null -eq ('ChromeLauncherTests.NativeArguments' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace ChromeLauncherTests {
    public static class NativeArguments {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW(string command, out int count);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);
        public static string[] Split(string command) {
            int count;
            IntPtr memory = CommandLineToArgvW(command, out count);
            if (memory == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                var result = new string[count];
                for (int i = 0; i < count; i++)
                    result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size));
                return result;
            } finally { LocalFree(memory); }
        }
    }
}
'@
        }
    }
    It 'Preserves spaces, root paths, trailing slashes, quotes, empty strings, and Unicode' {
        $unicodeFolder = 'D:\Profiles\' + [char]0x00E9 + [char]0x4E2D
        $values = @('', 'C:\', 'D:\path with spaces\', '\\server\share\', "O'Brien", 'a\"b', 'https://example.com/?a=1&b=2', $unicodeFolder)
        $line = ($values | ForEach-Object { ConvertTo-ChromeNativeArgument -Value $_ }) -join ' '
        $parsed = [ChromeLauncherTests.NativeArguments]::Split('chrome.exe ' + $line)
        $parsed.Count | Should -Be ($values.Count + 1)
        for ($index = 0; $index -lt $values.Count; $index++) {
            $parsed[$index + 1] | Should -BeExactly $values[$index]
        }
    }
}
