"""Supplemental source and algorithm checks. NOT a PowerShell or Windows test.

Run with Python 3.9+. Uses only the standard library. The native quoting regexes
are extracted from the delivered PowerShell source and exercised against an
independent model of Microsoft's native argument parsing rules.
"""
from __future__ import annotations
import json
from pathlib import Path
import random
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "chrome.ps1").read_text(encoding="utf-8-sig")


def lexical_balance(source: str) -> None:
    """Check balanced delimiters outside comments/strings, not PS grammar."""
    pairs = {')': '(', ']': '[', '}': '{'}
    stack = []
    i = 0
    while i < len(source):
        if source.startswith('<#', i):
            end = source.find('#>', i + 2)
            assert end >= 0, f"Unterminated block comment at {i}"
            i = end + 2
        elif source[i] == '#':
            end = source.find('\n', i)
            i = len(source) if end < 0 else end + 1
        elif source[i] in ('"', "'"):
            quote = source[i]
            begin = i
            i += 1
            while i < len(source):
                if quote == '"' and source[i] == '`':
                    i += 2
                    continue
                if source[i] == quote:
                    if quote == "'" and i + 1 < len(source) and source[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            else:
                raise AssertionError(f"Unterminated string at {begin}")
        elif source[i] == '`':
            i += 2
        elif source[i] in '([{':
            stack.append((source[i], i))
            i += 1
        elif source[i] in ')]}':
            assert stack and stack[-1][0] == pairs[source[i]], f"Mismatched delimiter at {i}"
            stack.pop()
            i += 1
        else:
            i += 1
    assert not stack, f"Unclosed delimiters: {stack}"


replacement_rules = re.findall(
    r"\$escaped = \[regex\]::Replace\(\$(?:Value|escaped), '([^']*)', '([^']*)'\)", SOURCE
)
assert len(replacement_rules) == 2


def source_quote(value: str) -> str:
    for pattern, replacement in replacement_rules:
        # Preserve .NET's literal backslashes while expanding $1 references.
        pieces = re.split(r'(\$\d+)', replacement)
        def expand(match: re.Match) -> str:
            return ''.join(match.group(int(p[1:])) if re.fullmatch(r'\$\d+', p) else p for p in pieces)
        value = re.sub(pattern, expand, value)
    return '"' + value + '"'


def native_parse(command: str) -> list[str]:
    """Reference Windows argument parser (arguments after argv[0])."""
    result = []
    i = 0
    n = len(command)
    while i < n:
        while i < n and command[i] in ' \t':
            i += 1
        if i == n:
            break
        arg = []
        quoted = False
        while i < n:
            if command[i] in ' \t' and not quoted:
                break
            slashes = 0
            while i < n and command[i] == '\\':
                slashes += 1
                i += 1
            if i < n and command[i] == '"':
                arg.extend('\\' * (slashes // 2))
                if slashes % 2:
                    arg.append('"')
                    i += 1
                elif quoted and i + 1 < n and command[i + 1] == '"':
                    arg.append('"')
                    i += 2
                else:
                    quoted = not quoted
                    i += 1
            else:
                arg.extend('\\' * slashes)
                if i >= n or (command[i] in ' \t' and not quoted):
                    break
                arg.append(command[i])
                i += 1
        result.append(''.join(arg))
    return result


def main() -> None:
    checked_files = []
    for extension in ('*.ps1', '*.psd1'):
        for path in ROOT.rglob(extension):
            lexical_balance(path.read_text(encoding='utf-8-sig'))
            checked_files.append(str(path.relative_to(ROOT)))

    samples = [
        '', 'Default', 'Profile 1', 'C:\\', 'C:\\Users\\Example\\',
        'D:\\Temp\\Chrome\\Session 1', '\\\\server\\share\\',
        'a"b', 'a\\"b', 'a\\\\"b', "O'Brien", '$(Get-Process)',
        'https://example.com/?a=1&b=2', 'C:\\Example[1]\\',
    ]
    rng = random.Random(20260920)
    alphabet = 'abZ09 \\"\t&;$()[]\u00e9\u4e2d'
    for _ in range(20000):
        samples.append(''.join(rng.choice(alphabet) for _ in range(rng.randrange(0, 70))))
    for value in samples:
        assert native_parse(source_quote(value)) == [value], repr(value)
        assert native_parse(subprocess.list2cmdline([value])) == [value], repr(value)
    vector_cases = 5000
    for _ in range(vector_cases):
        values = [rng.choice(samples) for _ in range(rng.randrange(1, 12))]
        assert native_parse(' '.join(map(source_quote, values))) == values

    # Independent model check: no gaps/duplicates and no batch overruns.
    # This models the orchestration loop, not execution of its PowerShell code.
    batch_cases = 0
    for count in range(1, 101):
        for choice in (0, 5, 10, 15, 20, 'all'):
            next_index = 0
            batch_size = min(5, count)
            attempted = []
            while next_index < count and batch_size > 0:
                end = min(next_index + batch_size, count)
                while next_index < end:
                    attempted.append(next_index)
                    next_index += 1
                remaining = count - next_index
                batch_size = remaining if choice == 'all' else min(choice, remaining)
            assert attempted == list(range(len(attempted)))
            assert len(attempted) == (min(5, count) if choice == 0 else count)
            batch_cases += 1

    # Targeted source regression assertions, not a substitute for an AST analyzer.
    assert "ParameterSetName = 'Interactive'" in SOURCE
    assert "ParameterSetName = 'Unattended'" in SOURCE
    assert "[Math]::Min(5, $plans.Count)" in SOURCE
    assert "if (-not $PSBoundParameters.ContainsKey('LaunchDelayMilliseconds')) { $LaunchDelayMilliseconds = 0 }" in SOURCE
    assert "--user-data-dir=' + $ProfileRecord.UserDataDir" in SOURCE
    assert "--profile-directory=' + $ProfileRecord.ProfileDirectory" in SOURCE
    assert "$timer.Elapsed.TotalSeconds -ge $TimeoutSeconds" in SOURCE
    assert not re.search(r'^\s*(?:Invoke-Expression|Stop-Process|Remove-Item)\b', SOURCE, re.MULTILINE)
    assert not re.search(r'\$global:', SOURCE, re.IGNORECASE)
    result = {
        'scope': 'Supplemental Python source/algorithm checks only; PowerShell and Windows were NOT executed.',
        'lexically_checked_files': checked_files,
        'single_argument_model_cases_passed': len(samples),
        'multi_argument_model_cases_passed': vector_cases,
        'batch_model_cases_passed': batch_cases,
        'source_regression_assertions_passed': 9,
        'pester_execution': 'NOT RUN',
        'psscriptanalyzer_execution': 'NOT RUN',
        'windows_chrome_integration': 'NOT RUN',
    }
    report_path = ROOT / 'STATIC_CHECK_RESULTS.json'
    report_path.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
