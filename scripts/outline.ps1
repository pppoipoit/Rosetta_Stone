# Lists every top-level declaration in each Swift file so the module's structure can be
# reviewed without a compiler. Indentation is measured after leading whitespace.
$root = 'e:\Project\Rosetta_Stone\RosettaStone'

Get-ChildItem -Recurse -Filter *.swift $root | ForEach-Object {
    $rel = $_.FullName.Substring($root.Length + 1)
    Write-Output "===== $rel ====="
    $depth = 0
    Get-Content $_.FullName | ForEach-Object {
        $line = $_
        $code = $line.TrimEnd()
        if ($code -match '^(?:@[\w().," ]+\s+)?(?:public |internal |private |fileprivate |final |static |@discardableResult |@objc |@State |@Published |@ObservedObject |@available|@NSApplicationDelegateAdaptor|@main )*(class|struct|enum|extension|protocol|actor|func|var|let)\b') {
            $indent = ($line.Length - ($line.TrimStart()).Length)
            if ($depth -le 1) {
                Write-Output ("  {0}{1}" -f (' ' * ($indent)), $code.Trim())
            }
        }
        $opens  = ([regex]::Matches(($code -replace '//.*$',''), '\{')).Count
        $closes = ([regex]::Matches(($code -replace '//.*$',''), '\}')).Count
        $depth += $opens - $closes
        if ($depth -lt 0) { $depth = 0 }
    }
    Write-Output ""
}
