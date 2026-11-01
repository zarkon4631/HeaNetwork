# Downloads what the build needs but the repository does not carry:
#   - the pinned sing-box-extended core for Windows  -> .cache/core/sing-box.exe
#   - the routing rule-sets bundled with the app      -> assets/rulesets/*.srs
# The core archive and every rule-set are verified against the SHA-256 pinned
# in tool/core.json. The SagerNet lists change upstream now and then, so a
# build fails with a checksum mismatch when they do: check that the upstream
# change is legitimate, then accept it by re-pinning:
#
#   pwsh tool/fetch_assets.ps1 -UpdateRuleSetHashes
#
#   pwsh tool/fetch_assets.ps1            # everything
#   pwsh tool/fetch_assets.ps1 -SkipCore  # rule-sets only (Android builds)
param(
    [switch]$SkipCore,
    [switch]$SkipRuleSets,
    [switch]$UpdateRuleSetHashes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = Split-Path -Parent $PSScriptRoot
$pin = Get-Content (Join-Path $PSScriptRoot 'core.json') -Raw | ConvertFrom-Json

# GitHub answers a download with a 5xx now and then; one bad answer should not
# fail the whole build.
function Get-File($url, $dest) {
    for ($try = 1; ; $try++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $dest
            return
        } catch {
            if ($try -ge 4) { throw }
            Write-Host "  attempt $try failed: $($_.Exception.Message)"
            Start-Sleep -Seconds (5 * $try)
        }
    }
}

if ($UpdateRuleSetHashes) {
    # Re-pins the rule-set hashes in core.json to what the URLs serve now.
    # Only run this after making sure the upstream lists changed legitimately.
    # The file is edited as text so its formatting stays as it was.
    $path = Join-Path $PSScriptRoot 'core.json'
    $text = Get-Content $path -Raw
    foreach ($p in $pin.rule_sets.PSObject.Properties) {
        $tmp = Join-Path $env:TEMP "$($p.Name).srs"
        Get-File $p.Value.url $tmp
        $hash = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
        Remove-Item $tmp -Force
        $text = $text.Replace("`"$($p.Value.sha256)`"", "`"$hash`"")
        Write-Host "$($p.Name): $hash"
    }
    # WriteAllText keeps the file UTF-8 without a BOM, as it is in git; the
    # utf8 encoding in Windows PowerShell 5.1 would add one.
    [System.IO.File]::WriteAllText($path, $text)
    Write-Host 'core.json now pins the new rule-set hashes'
    exit 0
}

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
        Get-File $url $zip

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

    # Xray-core, for the servers only it can reach (MASQUE, XDRIVE).
    $x = $pin.xray
    $xrayExe = Join-Path $coreDir 'xray.exe'
    $xrayStamp = Join-Path $coreDir 'xray-version.txt'
    $haveXray = if (Test-Path $xrayStamp) { (Get-Content $xrayStamp -Raw).Trim() } else { '' }
    if ((Test-Path $xrayExe) -and $haveXray -eq $x.tag) {
        Write-Host "xray $($x.tag) already present"
    } else {
        $zip = Join-Path $coreDir $x.asset
        $url = "https://github.com/$($x.repo)/releases/download/$($x.tag)/$($x.asset)"
        Write-Host "downloading $url"
        Get-File $url $zip
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $x.sha256) {
            Remove-Item $zip -Force
            throw "xray checksum mismatch: got $hash, pinned $($x.sha256)"
        }
        $tmp = Join-Path $coreDir 'unpack-xray'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $tmp
        Copy-Item (Join-Path $tmp 'xray.exe') $xrayExe -Force
        Copy-Item (Join-Path $tmp 'LICENSE') (Join-Path $coreDir 'LICENSE-xray.txt') -Force
        Remove-Item $tmp -Recurse -Force
        Remove-Item $zip -Force
        Set-Content -Path $xrayStamp -Value $x.tag -Encoding ascii
        Write-Host "xray $($x.tag) -> $xrayExe"
    }
}

if (-not $SkipRuleSets) {
    $rsDir = Join-Path $root 'assets/rulesets'
    New-Item -ItemType Directory -Force $rsDir | Out-Null
    foreach ($p in $pin.rule_sets.PSObject.Properties) {
        $dest = Join-Path $rsDir "$($p.Name).srs"
        Write-Host "downloading $($p.Value.url)"
        Get-File $p.Value.url $dest
        $hash = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $p.Value.sha256) {
            Remove-Item $dest -Force
            throw "rule-set $($p.Name) checksum mismatch: got $hash, pinned $($p.Value.sha256). If the upstream list changed legitimately, re-pin with -UpdateRuleSetHashes."
        }
    }
}
