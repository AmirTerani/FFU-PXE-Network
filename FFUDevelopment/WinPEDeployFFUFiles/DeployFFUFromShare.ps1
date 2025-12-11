param(
    [string]$DefaultSharePath = "##PXE_SHARE_PATH##",
    [string]$RelativeFFUPath  = "##PXE_REL_FFU##"
)

function New-ShareMapping {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SharePath
    )

    if (-not $SharePath.StartsWith('\\')) {
        Write-Host "Configured share path is not a UNC path: $SharePath"
        exit 1
    }

    $drive = 'S'

    $existing = Get-PSDrive -Name $drive -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-PSDrive -Name $drive -Force
    }

    $cred = Get-Credential -Message "Enter credentials to access $SharePath"

    New-PSDrive -Name $drive -PSProvider FileSystem -Root $SharePath -Credential $cred -Scope Global | Out-Null
    return $drive
}

try {
    Write-Host "Starting FFU deployment from network share..."
    $sharePath = $DefaultSharePath
    if ([string]::IsNullOrWhiteSpace($sharePath)) {
        $sharePath = Read-Host "Enter the UNC path to the deployment share (for example \\server\FFUDeploy)"
    }

    $drive = New-ShareMapping -SharePath $sharePath
    $ffuPath = Join-Path "$drive`:" $RelativeFFUPath

    if (-not (Test-Path $ffuPath)) {
        Write-Host "FFU file not found at $ffuPath"
        exit 1
    }

    Write-Host "FFU file: $ffuPath"
    Write-Host "This will apply the FFU to disk 0. All data on that disk will be lost."
    $confirm = Read-Host "Type YES to continue"
    if ($confirm -ne 'YES') {
        Write-Host "Deployment cancelled."
        exit 0
    }

    Write-Host "Applying FFU to disk 0..."
    DISM /Apply-Image /ImageFile:"$ffuPath" /ApplyDrive:0 /SkipPlatformCheck

    Write-Host "FFU deployment complete. You can now reboot the device."
}
catch {
    Write-Host "Deployment failed: $($_.Exception.Message)"
}
