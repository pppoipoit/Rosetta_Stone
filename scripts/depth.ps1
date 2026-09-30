# Prints the running brace depth for a range of lines: `outline.ps1 <file> <from> <to>`
# Used to confirm that a declaration's closing brace lands where it should.
param(
    [Parameter(Mandatory = $true)][string]$File,
    [int]$From = 1,
    [int]$To = 100000
)

$depth = 0
$lineNo = 0
Get-Content $File | ForEach-Object {
    $lineNo++
    $code = $_ -replace '//.*$', ''
    $depth += ([regex]::Matches($code, '\{')).Count - ([regex]::Matches($code, '\}')).Count
    if ($lineNo -ge $From -and $lineNo -le $To) {
        '{0,5}  depth={1,2}  {2}' -f $lineNo, $depth, $_
    }
}
