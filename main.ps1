# WinClean Dashboard - single-file Windows maintenance GUI
# Save as WinCleanDashboard.ps1, right-click -> Run with PowerShell.
# Built for Windows PowerShell 5.1+ on Windows 10/11. Most actions require admin rights.

param(
    [switch]$NoElevate
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Relaunch as STA + Administrator when saved as a file.
$scriptPath = $PSCommandPath
if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if ($scriptPath) {
        Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$scriptPath`"" -Verb RunAs
        exit
    }
}

if (-not $NoElevate -and -not (Test-IsAdministrator)) {
    if ($scriptPath) {
        Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$scriptPath`"" -Verb RunAs
        exit
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:LogFile = Join-Path $env:TEMP ("WinCleanDashboard_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$script:LogBox = $null

function Add-Log {
    param([Parameter(Mandatory=$true)][string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
    if ($script:LogBox -ne $null) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Show-Info {
    param([string]$Text, [string]$Title = 'WinClean Dashboard')
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', 'Information') | Out-Null
}

function Show-Warn {
    param([string]$Text, [string]$Title = 'WinClean Dashboard')
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', 'Warning') | Out-Null
}

function Confirm-Action {
    param([string]$Text, [string]$Title = 'Confirm')
    $result = [System.Windows.Forms.MessageBox]::Show($Text, $Title, 'YesNo', 'Question')
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][string]$Title
    )
    Add-Log "START: $Title"
    Add-Log "CMD: $Command"

    $outFile = Join-Path $env:TEMP ("wcd_out_{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
    $errFile = Join-Path $env:TEMP ("wcd_err_{0}.txt" -f ([Guid]::NewGuid().ToString('N')))

    try {
        $proc = Start-Process -FilePath $env:ComSpec -ArgumentList "/d /c $Command" -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -Wait -PassThru
        if (Test-Path $outFile) {
            Get-Content $outFile -ErrorAction SilentlyContinue | ForEach-Object { if ($_ -ne '') { Add-Log $_ } }
        }
        if (Test-Path $errFile) {
            Get-Content $errFile -ErrorAction SilentlyContinue | ForEach-Object { if ($_ -ne '') { Add-Log "ERR: $_" } }
        }
        Add-Log "DONE: $Title (exit code $($proc.ExitCode))"
        return $proc.ExitCode
    }
    catch {
        Add-Log "FAILED: $Title - $($_.Exception.Message)"
        return 1
    }
    finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Set-RegistryDword {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][int]$Value
    )
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
        Add-Log "Registry set: $Path\$Name = $Value"
    }
    catch {
        Add-Log "Registry failed: $Path\$Name - $($_.Exception.Message)"
    }
}

function Test-Winget {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Show-Warn "Winget was not found. Install or update 'App Installer' from Microsoft Store, then run this tool again."
        Add-Log "Winget not found."
        return $false
    }
    return $true
}

function Create-RestorePoint {
    Add-Log "Attempting to create system restore point..."
    try {
        Checkpoint-Computer -Description "WinClean Dashboard" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Add-Log "Restore point created."
        Show-Info "Restore point created."
    }
    catch {
        Add-Log "Restore point failed: $($_.Exception.Message)"
        Show-Warn "Could not create a restore point. System Protection may be disabled. The log has the details."
    }
}

function Remove-BloatAppPattern {
    param([Parameter(Mandatory=$true)][string]$Pattern)
    $like = "*$Pattern*"
    Add-Log "Removing app packages matching: $Pattern"

    try {
        $packages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like $like -or $_.PackageFullName -like $like
        }
        foreach ($pkg in $packages) {
            Add-Log "Removing installed package: $($pkg.PackageFullName)"
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
            }
            catch {
                try { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop | Out-Null }
                catch { Add-Log "Could not remove $($pkg.Name): $($_.Exception.Message)" }
            }
        }
    }
    catch {
        Add-Log "Installed package scan failed: $($_.Exception.Message)"
    }

    try {
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -like $like -or $_.PackageName -like $like
        }
        foreach ($pkg in $provisioned) {
            Add-Log "Removing provisioned package: $($pkg.PackageName)"
            try { Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null }
            catch { Add-Log "Could not remove provisioned $($pkg.DisplayName): $($_.Exception.Message)" }
        }
    }
    catch {
        Add-Log "Provisioned package scan failed: $($_.Exception.Message)"
    }
}

function Clear-TemporaryFiles {
    Add-Log "Cleaning temporary files..."
    $targets = @(
        $env:TEMP,
        "$env:WINDIR\Temp",
        "$env:LOCALAPPDATA\Temp"
    ) | Select-Object -Unique

    foreach ($target in $targets) {
        if (Test-Path $target) {
            Add-Log "Cleaning: $target"
            try {
                Get-ChildItem -Path $target -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            catch { Add-Log "Temp cleanup warning: $($_.Exception.Message)" }
        }
    }
    Add-Log "Temporary cleanup finished."
}

function Reset-WindowsUpdateCache {
    if (-not (Confirm-Action "This will stop Windows Update services and rename the update cache folders. Continue?" "Reset Windows Update cache")) { return }
    Add-Log "Resetting Windows Update cache..."
    $services = @('wuauserv','bits','cryptsvc','msiserver')
    foreach ($svc in $services) {
        try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue; Add-Log "Stopped service: $svc" } catch {}
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $sd = Join-Path $env:WINDIR 'SoftwareDistribution'
    $cr = Join-Path $env:WINDIR 'System32\catroot2'
    try { if (Test-Path $sd) { Rename-Item -Path $sd -NewName "SoftwareDistribution.old.$stamp" -ErrorAction Stop; Add-Log "Renamed SoftwareDistribution" } } catch { Add-Log "Could not rename SoftwareDistribution: $($_.Exception.Message)" }
    try { if (Test-Path $cr) { Rename-Item -Path $cr -NewName "catroot2.old.$stamp" -ErrorAction Stop; Add-Log "Renamed catroot2" } } catch { Add-Log "Could not rename catroot2: $($_.Exception.Message)" }

    foreach ($svc in $services) {
        try { Start-Service -Name $svc -ErrorAction SilentlyContinue; Add-Log "Started service: $svc" } catch {}
    }
    Add-Log "Windows Update cache reset finished."
    Show-Info "Windows Update cache reset finished. Reboot is recommended."
}

$Apps = @(
    [pscustomobject]@{Category='Browsers'; Name='Google Chrome'; Id='Google.Chrome'},
    [pscustomobject]@{Category='Browsers'; Name='Mozilla Firefox'; Id='Mozilla.Firefox'},
    [pscustomobject]@{Category='Browsers'; Name='Brave Browser'; Id='Brave.Brave'},
    [pscustomobject]@{Category='Browsers'; Name='Vivaldi'; Id='Vivaldi.Vivaldi'},
    [pscustomobject]@{Category='Browsers'; Name='Opera'; Id='Opera.Opera'},

    [pscustomobject]@{Category='Developer'; Name='Visual Studio Code'; Id='Microsoft.VisualStudioCode'},
    [pscustomobject]@{Category='Developer'; Name='Git'; Id='Git.Git'},
    [pscustomobject]@{Category='Developer'; Name='GitHub Desktop'; Id='GitHub.GitHubDesktop'},
    [pscustomobject]@{Category='Developer'; Name='PowerShell 7'; Id='Microsoft.PowerShell'},
    [pscustomobject]@{Category='Developer'; Name='Python 3.12'; Id='Python.Python.3.12'},
    [pscustomobject]@{Category='Developer'; Name='Node.js LTS'; Id='OpenJS.NodeJS.LTS'},
    [pscustomobject]@{Category='Developer'; Name='Docker Desktop'; Id='Docker.DockerDesktop'},
    [pscustomobject]@{Category='Developer'; Name='Windows Terminal'; Id='Microsoft.WindowsTerminal'},
    [pscustomobject]@{Category='Developer'; Name='Postman'; Id='Postman.Postman'},
    [pscustomobject]@{Category='Developer'; Name='WinSCP'; Id='WinSCP.WinSCP'},
    [pscustomobject]@{Category='Developer'; Name='PuTTY'; Id='PuTTY.PuTTY'},

    [pscustomobject]@{Category='Utilities'; Name='7-Zip'; Id='7zip.7zip'},
    [pscustomobject]@{Category='Utilities'; Name='Notepad++'; Id='Notepad++.Notepad++'},
    [pscustomobject]@{Category='Utilities'; Name='PowerToys'; Id='Microsoft.PowerToys'},
    [pscustomobject]@{Category='Utilities'; Name='Everything Search'; Id='voidtools.Everything'},
    [pscustomobject]@{Category='Utilities'; Name='ShareX'; Id='ShareX.ShareX'},
    [pscustomobject]@{Category='Utilities'; Name='WizTree'; Id='AntibodySoftware.WizTree'},
    [pscustomobject]@{Category='Utilities'; Name='Rufus'; Id='Rufus.Rufus'},
    [pscustomobject]@{Category='Utilities'; Name='balenaEtcher'; Id='Balena.Etcher'},
    [pscustomobject]@{Category='Utilities'; Name='Ventoy'; Id='Ventoy.Ventoy'},
    [pscustomobject]@{Category='Utilities'; Name='CrystalDiskInfo'; Id='CrystalDewWorld.CrystalDiskInfo'},
    [pscustomobject]@{Category='Utilities'; Name='CrystalDiskMark'; Id='CrystalDewWorld.CrystalDiskMark'},
    [pscustomobject]@{Category='Utilities'; Name='HWiNFO'; Id='REALiX.HWiNFO'},
    [pscustomobject]@{Category='Utilities'; Name='Malwarebytes'; Id='Malwarebytes.Malwarebytes'},
    [pscustomobject]@{Category='Utilities'; Name='Bitwarden'; Id='Bitwarden.Bitwarden'},

    [pscustomobject]@{Category='Media'; Name='VLC Media Player'; Id='VideoLAN.VLC'},
    [pscustomobject]@{Category='Media'; Name='MPC-HC'; Id='clsid2.mpc-hc'},
    [pscustomobject]@{Category='Media'; Name='OBS Studio'; Id='OBSProject.OBSStudio'},
    [pscustomobject]@{Category='Media'; Name='Audacity'; Id='Audacity.Audacity'},
    [pscustomobject]@{Category='Media'; Name='Spotify'; Id='Spotify.Spotify'},
    [pscustomobject]@{Category='Media'; Name='GIMP'; Id='GIMP.GIMP'},
    [pscustomobject]@{Category='Media'; Name='Blender'; Id='BlenderFoundation.Blender'},
    [pscustomobject]@{Category='Media'; Name='qBittorrent'; Id='qBittorrent.qBittorrent'},

    [pscustomobject]@{Category='Communication'; Name='Discord'; Id='Discord.Discord'},
    [pscustomobject]@{Category='Communication'; Name='Steam'; Id='Valve.Steam'},
    [pscustomobject]@{Category='Communication'; Name='Zoom'; Id='Zoom.Zoom'},
    [pscustomobject]@{Category='Communication'; Name='Slack'; Id='SlackTechnologies.Slack'},
    [pscustomobject]@{Category='Communication'; Name='Telegram Desktop'; Id='Telegram.TelegramDesktop'},
    [pscustomobject]@{Category='Communication'; Name='Signal'; Id='OpenWhisperSystems.Signal'},
    [pscustomobject]@{Category='Communication'; Name='WhatsApp'; Id='WhatsApp.WhatsApp'}
)

$BloatApps = @(
    [pscustomobject]@{Name='Clipchamp'; Pattern='Clipchamp.Clipchamp'},
    [pscustomobject]@{Name='Microsoft Teams Personal'; Pattern='MSTeams'},
    [pscustomobject]@{Name='Microsoft Teams Legacy'; Pattern='MicrosoftTeams'},
    [pscustomobject]@{Name='News'; Pattern='Microsoft.BingNews'},
    [pscustomobject]@{Name='Weather'; Pattern='Microsoft.BingWeather'},
    [pscustomobject]@{Name='Get Help'; Pattern='Microsoft.GetHelp'},
    [pscustomobject]@{Name='Tips / Get Started'; Pattern='Microsoft.Getstarted'},
    [pscustomobject]@{Name='Solitaire Collection'; Pattern='Microsoft.MicrosoftSolitaireCollection'},
    [pscustomobject]@{Name='Microsoft To Do'; Pattern='Microsoft.Todos'},
    [pscustomobject]@{Name='New Outlook for Windows'; Pattern='Microsoft.OutlookForWindows'},
    [pscustomobject]@{Name='People'; Pattern='Microsoft.People'},
    [pscustomobject]@{Name='Maps'; Pattern='Microsoft.WindowsMaps'},
    [pscustomobject]@{Name='Feedback Hub'; Pattern='Microsoft.WindowsFeedbackHub'},
    [pscustomobject]@{Name='Sound Recorder'; Pattern='Microsoft.WindowsSoundRecorder'},
    [pscustomobject]@{Name='Movies & TV'; Pattern='Microsoft.ZuneVideo'},
    [pscustomobject]@{Name='Groove / Media Player Music'; Pattern='Microsoft.ZuneMusic'},
    [pscustomobject]@{Name='Phone Link'; Pattern='Microsoft.YourPhone'},
    [pscustomobject]@{Name='Xbox App'; Pattern='Microsoft.XboxApp'},
    [pscustomobject]@{Name='Gaming App'; Pattern='Microsoft.GamingApp'},
    [pscustomobject]@{Name='Xbox Game Bar Overlay'; Pattern='Microsoft.XboxGamingOverlay'},
    [pscustomobject]@{Name='Xbox TCUI'; Pattern='Microsoft.Xbox.TCUI'},
    [pscustomobject]@{Name='Xbox Identity Provider'; Pattern='Microsoft.XboxIdentityProvider'},
    [pscustomobject]@{Name='Xbox Speech Overlay'; Pattern='Microsoft.XboxSpeechToTextOverlay'},
    [pscustomobject]@{Name='Office Hub'; Pattern='Microsoft.MicrosoftOfficeHub'},
    [pscustomobject]@{Name='Cortana'; Pattern='Microsoft.549981C3F5F10'},
    [pscustomobject]@{Name='Mixed Reality Portal'; Pattern='Microsoft.MixedReality.Portal'},
    [pscustomobject]@{Name='Power Automate Desktop'; Pattern='Microsoft.PowerAutomateDesktop'},
    [pscustomobject]@{Name='LinkedIn'; Pattern='LinkedInforWindows'},
    [pscustomobject]@{Name='Copilot App'; Pattern='Microsoft.Copilot'}
)

# ---------- UI ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'WinClean Dashboard'
$form.Size = New-Object System.Drawing.Size(980, 680)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$form.Controls.Add($tabs)

function New-TabPage {
    param([string]$Title)
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = $Title
    $tab.BackColor = [System.Drawing.Color]::White
    $tabs.TabPages.Add($tab) | Out-Null
    return $tab
}

$tabInstall = New-TabPage 'Install'
$tabTweaks = New-TabPage 'Tweaks'
$tabFixes = New-TabPage 'Fixes'
$tabUpdates = New-TabPage 'Updates'
$tabLog = New-TabPage 'Log'

# Install tab
$installHeader = New-Object System.Windows.Forms.Label
$installHeader.Text = 'Select apps and install them in one batch.'
$installHeader.AutoSize = $true
$installHeader.Location = New-Object System.Drawing.Point(16, 14)
$installHeader.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$tabInstall.Controls.Add($installHeader)

$appList = New-Object System.Windows.Forms.ListView
$appList.Location = New-Object System.Drawing.Point(16, 48)
$appList.Size = New-Object System.Drawing.Size(925, 470)
$appList.Anchor = 'Top,Bottom,Left,Right'
$appList.View = 'Details'
$appList.CheckBoxes = $true
$appList.FullRowSelect = $true
$appList.GridLines = $false
$appList.Columns.Add('Category', 140) | Out-Null
$appList.Columns.Add('App', 260) | Out-Null
$appList.Columns.Add('Winget ID', 440) | Out-Null
foreach ($app in $Apps) {
    $item = New-Object System.Windows.Forms.ListViewItem($app.Category)
    $item.SubItems.Add($app.Name) | Out-Null
    $item.SubItems.Add($app.Id) | Out-Null
    $item.Tag = $app
    $appList.Items.Add($item) | Out-Null
}
$tabInstall.Controls.Add($appList)

$btnInstallSelected = New-Object System.Windows.Forms.Button
$btnInstallSelected.Text = 'Install selected'
$btnInstallSelected.Size = New-Object System.Drawing.Size(135, 34)
$btnInstallSelected.Location = New-Object System.Drawing.Point(16, 532)
$btnInstallSelected.Anchor = 'Bottom,Left'
$tabInstall.Controls.Add($btnInstallSelected)

$btnSelectAllApps = New-Object System.Windows.Forms.Button
$btnSelectAllApps.Text = 'Select all'
$btnSelectAllApps.Size = New-Object System.Drawing.Size(95, 34)
$btnSelectAllApps.Location = New-Object System.Drawing.Point(160, 532)
$btnSelectAllApps.Anchor = 'Bottom,Left'
$tabInstall.Controls.Add($btnSelectAllApps)

$btnClearApps = New-Object System.Windows.Forms.Button
$btnClearApps.Text = 'Clear'
$btnClearApps.Size = New-Object System.Drawing.Size(95, 34)
$btnClearApps.Location = New-Object System.Drawing.Point(263, 532)
$btnClearApps.Anchor = 'Bottom,Left'
$tabInstall.Controls.Add($btnClearApps)

$btnUpgradeAll = New-Object System.Windows.Forms.Button
$btnUpgradeAll.Text = 'Upgrade all Winget apps'
$btnUpgradeAll.Size = New-Object System.Drawing.Size(170, 34)
$btnUpgradeAll.Location = New-Object System.Drawing.Point(370, 532)
$btnUpgradeAll.Anchor = 'Bottom,Left'
$tabInstall.Controls.Add($btnUpgradeAll)

# Tweaks tab
$tweakHeader = New-Object System.Windows.Forms.Label
$tweakHeader.Text = 'Debloat, privacy and performance tweaks. Create a restore point first.'
$tweakHeader.AutoSize = $true
$tweakHeader.Location = New-Object System.Drawing.Point(16, 14)
$tweakHeader.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$tabTweaks.Controls.Add($tweakHeader)

$debloatBox = New-Object System.Windows.Forms.CheckedListBox
$debloatBox.CheckOnClick = $true
$debloatBox.Location = New-Object System.Drawing.Point(16, 52)
$debloatBox.Size = New-Object System.Drawing.Size(390, 410)
$debloatBox.Anchor = 'Top,Bottom,Left'
foreach ($b in $BloatApps) { [void]$debloatBox.Items.Add($b.Name, $true) }
$tabTweaks.Controls.Add($debloatBox)

$privacyGroup = New-Object System.Windows.Forms.GroupBox
$privacyGroup.Text = 'Privacy / tracking'
$privacyGroup.Location = New-Object System.Drawing.Point(430, 52)
$privacyGroup.Size = New-Object System.Drawing.Size(500, 190)
$privacyGroup.Anchor = 'Top,Left,Right'
$tabTweaks.Controls.Add($privacyGroup)

$chkTelemetry = New-Object System.Windows.Forms.CheckBox
$chkTelemetry.Text = 'Reduce telemetry + disable diagnostic tracking services'
$chkTelemetry.AutoSize = $true
$chkTelemetry.Checked = $true
$chkTelemetry.Location = New-Object System.Drawing.Point(16, 30)
$privacyGroup.Controls.Add($chkTelemetry)

$chkAds = New-Object System.Windows.Forms.CheckBox
$chkAds.Text = 'Disable advertising ID, tailored experiences, suggestions'
$chkAds.AutoSize = $true
$chkAds.Checked = $true
$chkAds.Location = New-Object System.Drawing.Point(16, 62)
$privacyGroup.Controls.Add($chkAds)

$chkActivity = New-Object System.Windows.Forms.CheckBox
$chkActivity.Text = 'Disable activity history upload/publishing'
$chkActivity.AutoSize = $true
$chkActivity.Checked = $true
$chkActivity.Location = New-Object System.Drawing.Point(16, 94)
$privacyGroup.Controls.Add($chkActivity)

$chkFeedback = New-Object System.Windows.Forms.CheckBox
$chkFeedback.Text = 'Disable feedback frequency prompts'
$chkFeedback.AutoSize = $true
$chkFeedback.Checked = $true
$chkFeedback.Location = New-Object System.Drawing.Point(16, 126)
$privacyGroup.Controls.Add($chkFeedback)

$perfGroup = New-Object System.Windows.Forms.GroupBox
$perfGroup.Text = 'Performance / cleanup'
$perfGroup.Location = New-Object System.Drawing.Point(430, 260)
$perfGroup.Size = New-Object System.Drawing.Size(500, 202)
$perfGroup.Anchor = 'Top,Left,Right'
$tabTweaks.Controls.Add($perfGroup)

$chkStartupDelay = New-Object System.Windows.Forms.CheckBox
$chkStartupDelay.Text = 'Disable startup app launch delay'
$chkStartupDelay.AutoSize = $true
$chkStartupDelay.Checked = $true
$chkStartupDelay.Location = New-Object System.Drawing.Point(16, 30)
$perfGroup.Controls.Add($chkStartupDelay)

$chkGameDvr = New-Object System.Windows.Forms.CheckBox
$chkGameDvr.Text = 'Disable Xbox Game DVR background capture'
$chkGameDvr.AutoSize = $true
$chkGameDvr.Checked = $true
$chkGameDvr.Location = New-Object System.Drawing.Point(16, 62)
$perfGroup.Controls.Add($chkGameDvr)

$chkBackgroundApps = New-Object System.Windows.Forms.CheckBox
$chkBackgroundApps.Text = 'Limit background app access'
$chkBackgroundApps.AutoSize = $true
$chkBackgroundApps.Checked = $true
$chkBackgroundApps.Location = New-Object System.Drawing.Point(16, 94)
$perfGroup.Controls.Add($chkBackgroundApps)

$chkTempClean = New-Object System.Windows.Forms.CheckBox
$chkTempClean.Text = 'Clean temporary folders'
$chkTempClean.AutoSize = $true
$chkTempClean.Checked = $true
$chkTempClean.Location = New-Object System.Drawing.Point(16, 126)
$perfGroup.Controls.Add($chkTempClean)

$chkHibernateOff = New-Object System.Windows.Forms.CheckBox
$chkHibernateOff.Text = 'Disable hibernation / Fast Startup file'
$chkHibernateOff.AutoSize = $true
$chkHibernateOff.Checked = $false
$chkHibernateOff.Location = New-Object System.Drawing.Point(16, 158)
$perfGroup.Controls.Add($chkHibernateOff)

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = 'Create restore point'
$btnRestore.Size = New-Object System.Drawing.Size(160, 34)
$btnRestore.Location = New-Object System.Drawing.Point(16, 482)
$btnRestore.Anchor = 'Bottom,Left'
$tabTweaks.Controls.Add($btnRestore)

$btnRemoveBloat = New-Object System.Windows.Forms.Button
$btnRemoveBloat.Text = 'Remove selected bloat'
$btnRemoveBloat.Size = New-Object System.Drawing.Size(170, 34)
$btnRemoveBloat.Location = New-Object System.Drawing.Point(188, 482)
$btnRemoveBloat.Anchor = 'Bottom,Left'
$tabTweaks.Controls.Add($btnRemoveBloat)

$btnApplyTweaks = New-Object System.Windows.Forms.Button
$btnApplyTweaks.Text = 'Apply selected tweaks'
$btnApplyTweaks.Size = New-Object System.Drawing.Size(170, 34)
$btnApplyTweaks.Location = New-Object System.Drawing.Point(430, 482)
$btnApplyTweaks.Anchor = 'Bottom,Left'
$tabTweaks.Controls.Add($btnApplyTweaks)

# Fixes tab
$fixHeader = New-Object System.Windows.Forms.Label
$fixHeader.Text = 'Essential system repair commands.'
$fixHeader.AutoSize = $true
$fixHeader.Location = New-Object System.Drawing.Point(16, 14)
$fixHeader.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$tabFixes.Controls.Add($fixHeader)

$fixPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$fixPanel.Location = New-Object System.Drawing.Point(16, 52)
$fixPanel.Size = New-Object System.Drawing.Size(920, 460)
$fixPanel.Anchor = 'Top,Bottom,Left,Right'
$fixPanel.FlowDirection = 'TopDown'
$fixPanel.WrapContents = $false
$tabFixes.Controls.Add($fixPanel)

function Add-FixButton {
    param([string]$Text, [scriptblock]$Action)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Size = New-Object System.Drawing.Size(330, 38)
    $btn.Margin = New-Object System.Windows.Forms.Padding(0,0,0,10)
    $btn.Add_Click($Action)
    $fixPanel.Controls.Add($btn) | Out-Null
}

Add-FixButton 'Run DISM RestoreHealth' { Invoke-LoggedCommand 'DISM.exe /Online /Cleanup-Image /RestoreHealth' 'DISM RestoreHealth' | Out-Null }
Add-FixButton 'Run SFC /scannow' { Invoke-LoggedCommand 'sfc /scannow' 'System File Checker' | Out-Null }
Add-FixButton 'Run CHKDSK online scan' { Invoke-LoggedCommand 'chkdsk C: /scan' 'CHKDSK online scan' | Out-Null }
Add-FixButton 'Clean component store' { Invoke-LoggedCommand 'DISM.exe /Online /Cleanup-Image /StartComponentCleanup' 'Component store cleanup' | Out-Null }
Add-FixButton 'Flush DNS' { Invoke-LoggedCommand 'ipconfig /flushdns' 'Flush DNS' | Out-Null }
Add-FixButton 'Reset Winsock' { if (Confirm-Action 'Resetting Winsock may require a reboot. Continue?' 'Reset Winsock') { Invoke-LoggedCommand 'netsh winsock reset' 'Winsock reset' | Out-Null } }
Add-FixButton 'Clean temporary folders' { Clear-TemporaryFiles }

# Updates tab
$updHeader = New-Object System.Windows.Forms.Label
$updHeader.Text = 'Windows Update and app update tools.'
$updHeader.AutoSize = $true
$updHeader.Location = New-Object System.Drawing.Point(16, 14)
$updHeader.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$tabUpdates.Controls.Add($updHeader)

$updatePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$updatePanel.Location = New-Object System.Drawing.Point(16, 52)
$updatePanel.Size = New-Object System.Drawing.Size(920, 470)
$updatePanel.Anchor = 'Top,Bottom,Left,Right'
$updatePanel.FlowDirection = 'TopDown'
$updatePanel.WrapContents = $false
$tabUpdates.Controls.Add($updatePanel)

function Add-UpdateButton {
    param([string]$Text, [scriptblock]$Action)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Size = New-Object System.Drawing.Size(360, 38)
    $btn.Margin = New-Object System.Windows.Forms.Padding(0,0,0,10)
    $btn.Add_Click($Action)
    $updatePanel.Controls.Add($btn) | Out-Null
}

Add-UpdateButton 'Open Windows Update settings' { Start-Process 'ms-settings:windowsupdate' }
Add-UpdateButton 'Check for Windows updates' {
    Add-Log 'Starting Windows Update scan...'
    try { Start-Process 'ms-settings:windowsupdate-action' -ErrorAction SilentlyContinue } catch { Start-Process 'ms-settings:windowsupdate' }
    Invoke-LoggedCommand 'UsoClient StartScan' 'Windows Update scan trigger' | Out-Null
}
Add-UpdateButton 'Reset Windows Update cache' { Reset-WindowsUpdateCache }
Add-UpdateButton 'Set Windows Update service to default/manual + start' {
    try { Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue; Start-Service -Name wuauserv -ErrorAction SilentlyContinue; Add-Log 'Windows Update service set to Manual and started.' } catch { Add-Log $_.Exception.Message }
}
Add-UpdateButton 'Exclude driver updates from Windows Update' {
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
    Show-Info 'Driver updates are now excluded from Windows Update policy. Reboot may be required.'
}
Add-UpdateButton 'Allow driver updates from Windows Update' {
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 0
    Show-Info 'Driver updates are now allowed by Windows Update policy. Reboot may be required.'
}
Add-UpdateButton 'Upgrade all Winget apps' {
    if (Test-Winget) {
        Invoke-LoggedCommand 'winget upgrade --all --accept-source-agreements --accept-package-agreements --disable-interactivity' 'Winget upgrade all' | Out-Null
    }
}

# Log tab
$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.ReadOnly = $true
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:LogBox.Dock = 'Fill'
$tabLog.Controls.Add($script:LogBox)

$bottomLogPanel = New-Object System.Windows.Forms.Panel
$bottomLogPanel.Height = 46
$bottomLogPanel.Dock = 'Bottom'
$tabLog.Controls.Add($bottomLogPanel)
$bottomLogPanel.BringToFront()

$btnOpenLog = New-Object System.Windows.Forms.Button
$btnOpenLog.Text = 'Open log file'
$btnOpenLog.Size = New-Object System.Drawing.Size(120, 30)
$btnOpenLog.Location = New-Object System.Drawing.Point(10, 8)
$bottomLogPanel.Controls.Add($btnOpenLog)

$btnCopyLogPath = New-Object System.Windows.Forms.Button
$btnCopyLogPath.Text = 'Copy log path'
$btnCopyLogPath.Size = New-Object System.Drawing.Size(120, 30)
$btnCopyLogPath.Location = New-Object System.Drawing.Point(140, 8)
$bottomLogPanel.Controls.Add($btnCopyLogPath)

# Events
$btnSelectAllApps.Add_Click({ foreach ($item in $appList.Items) { $item.Checked = $true } })
$btnClearApps.Add_Click({ foreach ($item in $appList.Items) { $item.Checked = $false } })

$btnInstallSelected.Add_Click({
    if (-not (Test-Winget)) { return }
    $selected = @()
    foreach ($item in $appList.CheckedItems) { $selected += $item.Tag }
    if ($selected.Count -eq 0) { Show-Info 'No apps selected.'; return }
    if (-not (Confirm-Action "Install $($selected.Count) selected app(s) with Winget?" 'Install apps')) { return }
    foreach ($app in $selected) {
        $cmd = 'winget install --id "{0}" -e --accept-source-agreements --accept-package-agreements --silent --disable-interactivity' -f $app.Id
        Invoke-LoggedCommand $cmd "Install $($app.Name)" | Out-Null
    }
    Show-Info 'Selected app install batch finished. Check the Log tab for details.'
})

$btnUpgradeAll.Add_Click({
    if (Test-Winget) {
        if (Confirm-Action 'Upgrade all Winget-detected apps?' 'Winget upgrade') {
            Invoke-LoggedCommand 'winget upgrade --all --accept-source-agreements --accept-package-agreements --disable-interactivity' 'Winget upgrade all' | Out-Null
            Show-Info 'Winget upgrade finished. Check the Log tab for details.'
        }
    }
})

$btnRestore.Add_Click({ Create-RestorePoint })

$btnRemoveBloat.Add_Click({
    $selectedNames = @()
    foreach ($item in $debloatBox.CheckedItems) { $selectedNames += [string]$item }
    if ($selectedNames.Count -eq 0) { Show-Info 'No bloat apps selected.'; return }
    if (-not (Confirm-Action "Remove $($selectedNames.Count) selected app package pattern(s)? This may affect all users and future profiles." 'Remove bloat')) { return }

    foreach ($name in $selectedNames) {
        $entry = $BloatApps | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($entry) { Remove-BloatAppPattern -Pattern $entry.Pattern }
    }
    Show-Info 'Debloat pass finished. Reboot is recommended. Check the Log tab for details.'
})

$btnApplyTweaks.Add_Click({
    if (-not (Confirm-Action 'Apply selected registry/service tweaks? A reboot is recommended afterward.' 'Apply tweaks')) { return }

    if ($chkTelemetry.Checked) {
        Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
        Set-RegistryDword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
        foreach ($svc in @('DiagTrack','dmwappushservice')) {
            try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue; Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue; Add-Log "Disabled service: $svc" } catch { Add-Log "Service tweak failed for ${svc}: $($_.Exception.Message)" }
        }
    }

    if ($chkAds.Checked) {
        Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
        Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0
        Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0
        Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 0
        Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
        Set-RegistryDword 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1
        Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerFeatures' 1
    }

    if ($chkActivity.Checked) {
        Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
        Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
        Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    }

    if ($chkFeedback.Checked) {
        Set-RegistryDword 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
        Set-RegistryDword 'HKCU:\Software\Microsoft\Siuf\Rules' 'PeriodInNanoSeconds' 0
    }

    if ($chkStartupDelay.Checked) {
        Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0
    }

    if ($chkGameDvr.Checked) {
        Set-RegistryDword 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
        Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
        Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    }

    if ($chkBackgroundApps.Checked) {
        Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    }

    if ($chkTempClean.Checked) { Clear-TemporaryFiles }

    if ($chkHibernateOff.Checked) {
        Invoke-LoggedCommand 'powercfg -h off' 'Disable hibernation' | Out-Null
    }

    Add-Log 'Selected tweaks applied.'
    Show-Info 'Selected tweaks applied. Reboot is recommended.'
})

$btnOpenLog.Add_Click({
    if (Test-Path $script:LogFile) { Start-Process notepad.exe $script:LogFile }
})
$btnCopyLogPath.Add_Click({
    [System.Windows.Forms.Clipboard]::SetText($script:LogFile)
    Show-Info 'Log path copied to clipboard.'
})

Add-Log 'WinClean Dashboard started.'
Add-Log "Admin: $(Test-IsAdministrator)"
Add-Log "Log file: $script:LogFile"

if (-not (Test-IsAdministrator)) {
    Show-Warn 'Some actions require Administrator rights. Restart this script as Administrator for best results.'
}

[void]$form.ShowDialog()
