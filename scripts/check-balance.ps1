# =============================================================================
#  check-balance.ps1 — structural sanity check for the Swift sources.
# =============================================================================
#  Intended to run on Windows/Linux CI agents that have no Swift toolchain.
#  It strips string literals and comments, then verifies that every file's braces
#  and parentheses balance. That catches the single most common editing mistake
#  (a misplaced closing brace from a mis-targeted insert) without needing a Mac.
#
#  Usage:  powershell -ExecutionPolicy Bypass -File scripts/check-balance.ps1
#  Exit code 0 = all files balanced, 1 = at least one mismatch.
# =============================================================================

$ErrorActionPreference = 'Stop'
$root = Join-Path (Split-Path -Parent $PSScriptRoot) 'RosettaStone'

function Get-CodeOnly($text) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $n = $text.Length
    $inLine = $false; $inBlock = $false; $inStr = $false
    while ($i -lt $n) {
        $ch = $text[$i]
        $next = if ($i + 1 -lt $n) { $text[$i + 1] } else { [char]0 }
        if ($inLine)  { if ($ch -eq "`n") { $inLine = $false; [void]$sb.Append($ch) }; $i++; continue }
        if ($inBlock) { if ($ch -eq '*' -and $next -eq '/') { $inBlock = $false; $i += 2; continue }; $i++; continue }
        if ($inStr)   { if ($ch -eq '\') { $i += 2; continue }; if ($ch -eq '"') { $inStr = $false; $i++; continue }; $i++; continue }
        if ($ch -eq '/' -and $next -eq '/') { $inLine = $true; $i += 2; continue }
        if ($ch -eq '/' -and $next -eq '*') { $inBlock = $true; $i += 2; continue }
        if ($ch -eq '"') { $inStr = $true; $i++; continue }
        [void]$sb.Append($ch); $i++
    }
    return $sb.ToString()
}

$failed = $false
Get-ChildItem -Recurse -Filter *.swift $root | ForEach-Object {
    $code = Get-CodeOnly (Get-Content $_.FullName -Raw)
    $ob = ([regex]::Matches($code, '\{')).Count
    $cb = ([regex]::Matches($code, '\}')).Count
    $op = ([regex]::Matches($code, '\(')).Count
    $cp = ([regex]::Matches($code, '\)')).Count
    $flag = ''
    if ($ob -ne $cb) { $flag += '  <== BRACE-MISMATCH';  $failed = $true }
    if ($op -ne $cp) { $flag += '  <== PAREN-MISMATCH'; $failed = $true }
    '{0,-42} braces {1}/{2}  parens {3}/{4}{5}' -f $_.Name, $ob, $cb, $op, $cp, $flag
}

if ($failed) {
    Write-Output "`nFAILED: unbalanced delimiters found."
    exit 1
}
Write-Output "`nOK: all Swift files have balanced delimiters."
exit 0
