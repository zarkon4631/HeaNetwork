# Downloads what the build needs but the repository does not carry:
#   - the pinned sing-box-extended core for Windows  -> .cache/core/sing-box.exe
#   - the routing rule-sets bundled with the app      -> assets/rulesets/*.srs
# The core archive is verified against the SHA-256 pinned in tool/core.json.
#
#   pwsh tool/fetch_assets.ps1            # everything
#   pwsh tool/fetch_assets.ps1 -SkipCore  # rule-sets only (Android builds)
param(
    [switch]$SkipCore,
    [switch]$SkipRuleSets
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = Split-Path -Parent $PSScriptRoot
$pin = Get-Content (Join-Path $PSScriptRoot 'core.json') -Raw | ConvertFrom-Json

if (-not $SkipCore) {
    $coreDir = Join-Path $root '.cache/core'
    $exe = Join-Path $coreDir 'sing-box.exe'
    $stamp = Join-Path $coreDir 'version.txt'
    $have = if (Test-Path $stamp) { (Get-Content $stamp -Raw).Trim() } else { '' }

    if ((Test-Path $exe) -and $have -eq $pin.tag) {
        Write-Host "core $($pin.tag) already present"
    } else {
        New-Item -ItemType Directory -Force $coreDir | Out-Null
        $zip = Join-Path $coreDir $pin.windows_amd64.asset
        $url = "https://github.com/$($pin.repo)/releases/download/$($pin.tag)/$($pin.windows_amd64.asset)"
        Write-Host "downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $zip

        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $pin.windows_amd64.sha256) {
            Remove-Item $zip -Force
            throw "core checksum mismatch: got $hash, pinned $($pin.windows_amd64.sha256)"
        }

        $tmp = Join-Path $coreDir 'unpack'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $tmp
        $found = Get-ChildItem $tmp -Recurse -Filter 'sing-box.exe' | Select-Object -First 1
        if (-not $found) { throw 'sing-box.exe not found in the core archive' }
        Copy-Item $found.FullName $exe -Force
        $license = Get-ChildItem $tmp -Recurse -Filter 'LICENSE' | Select-Object -First 1
        if ($license) { Copy-Item $license.FullName (Join-Path $coreDir 'LICENSE-sing-box.txt') -Force }
        Remove-Item $tmp -Recurse -Force
        Remove-Item $zip -Force
        Set-Content -Path $stamp -Value $pin.tag -Encoding ascii
        Write-Host "core $($pin.tag) -> $exe"
    }
}

if (-not $SkipRuleSets) {
    $rsDir = Join-Path $root 'assets/rulesets'
    New-Item -ItemType Directory -Force $rsDir | Out-Null
    foreach ($p in $pin.rule_sets.PSObject.Properties) {
        $dest = Join-Path $rsDir "$($p.Name).srs"
        Write-Host "downloading $($p.Value)"
        Invoke-WebRequest -Uri $p.Value -OutFile $dest
        if ((Get-Item $dest).Length -lt 64) { throw "rule-set $($p.Name) looks truncated" }
    }
}
