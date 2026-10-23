param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [string]$ExeName = 'PullYard'
)

$ErrorActionPreference = 'Stop'

$deps = Join-Path $AppDir "$ExeName.deps.json"
$notices = Join-Path $AppDir 'THIRD-PARTY-NOTICES.txt'
if (-not (Test-Path $deps)) { throw "Missing $deps" }
if (-not (Test-Path $notices)) { throw "Missing $notices" }

$root = $env:NUGET_PACKAGES
if (-not $root) {
    $line = (& dotnet nuget locals global-packages --list) | Select-Object -First 1
    $root = ($line -replace '^\s*global-packages:\s*', '').Trim()
}
if (-not (Test-Path $root)) { throw "NuGet packages folder not found: $root" }

$out = Join-Path $AppDir 'licenses'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force -Path $out | Out-Null

$pattern = '^(license|licence|notice|third-?party-?notices)'
$inventory = @()
$missing = @()
$libraries = (Get-Content $deps -Raw | ConvertFrom-Json).libraries
foreach ($entry in $libraries.PSObject.Properties) {
    $type = $entry.Value.type
    if ($type -ne 'package' -and $type -ne 'runtimepack') { continue }
    $name, $version = $entry.Name -split '/', 2
    $id = $name -replace '^runtimepack\.', ''
    $folder = if ($entry.Value.path) { Join-Path $root $entry.Value.path } else { Join-Path $root ("{0}/{1}" -f $id.ToLowerInvariant(), $version) }
    $files = @()
    if (Test-Path $folder) {
        $files = Get-ChildItem -Path $folder -File | Where-Object { $_.Name -match $pattern }
    }
    if ($files.Count -gt 0) {
        $dest = New-Item -ItemType Directory -Force -Path (Join-Path $out $id)
        foreach ($f in $files) { Copy-Item $f.FullName -Destination $dest.FullName }
        $inventory += "- $id $version  (licenses\$id\: $(($files | ForEach-Object Name) -join ', '))"
    }
    else {
        $missing += "$id $version"
        $inventory += "- $id $version"
    }
}

$header = @(
    '',
    ('=' * 79),
    'Packages included in this build',
    '',
    'Resolved from the published dependency manifest. License and notice files',
    'shipped inside each package are copied to the "licenses" folder.',
    ''
)
Add-Content -Path $notices -Value ($header + ($inventory | Sort-Object)) -Encoding utf8

Write-Host "Collected license files for $($inventory.Count - $missing.Count) of $($inventory.Count) packages into $out"
foreach ($m in $missing) { Write-Host "::warning::No license file found in NuGet package $m" }
