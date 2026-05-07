#Requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
# 1. SCRIPT ENVIRONMENT & BOOTSTRAP
# ============================================================
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrWhiteSpace($script:ScriptDir)) {
    $script:ScriptDir = (Get-Location).Path
}
$script:ScriptDirName   = Split-Path -Leaf $script:ScriptDir
$script:ConfigFileName  = "SnapVault.config.json"
$script:ConfigPath      = Join-Path $script:ScriptDir $script:ConfigFileName
$script:LastBrowsePath  = $script:ScriptDir
$script:7zPath          = $null

# Locked timestamps for a run (set on Create Snapshot)
$script:LockedUtcTimestamp  = $null      # yyyy-MM-ddTHH:mm:ssZ
$script:FileNameTimestamp   = $null      # yyyyMMddTHHmmssZ

function Find-7Zip {
    $pathExe = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($pathExe) { return $pathExe.Source }
    $candidates = @(
        "C:\Program Files\7-Zip\7z.exe",
        "C:\Program Files (x86)\7-Zip\7z.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}
$script:7zPath = Find-7Zip

# ============================================================
# 2. HELPER FUNCTIONS (UTC TIMESTAMPS & DISPLAY)
# ============================================================

function Get-DisplayString {
    param([string]$RawPath)
    $normalized = $RawPath.Replace('${APPDIR}', $script:ScriptDir)
    if ($normalized.StartsWith($script:ScriptDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "..." + $normalized.Substring($script:ScriptDir.Length)
    }
    if ($RawPath.StartsWith('${APPDIR}', [System.StringComparison]::OrdinalIgnoreCase)) {
        return "..." + $RawPath.Substring('${APPDIR}'.Length)
    }
    return $RawPath
}

function Convert-ToPortablePath {
    param([string]$Path)
    if ($Path.StartsWith($script:ScriptDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '${APPDIR}' + $Path.Substring($script:ScriptDir.Length)
    }
    return $Path
}

function Resolve-VariablePath {
    param([string]$Path)
    return $Path.Replace('${APPDIR}', $script:ScriptDir)
}

function Test-InvalidSnapshotName {
    param([string]$Name)
    return $Name -match '[/\\:\*\?"<>\|]'
}

# UTC helpers
function Get-UtcNowForFileName {
    # yyyyMMddTHHmmssZ
    return (Get-Date).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'")
}
function Get-UtcNowForLog {
    # yyyy-MM-ddTHH:mm:ssZ
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}
function Get-LocalNowForLabel {
    # yyyy-MM-ddTHH:mm:ss (local, no Z)
    return (Get-Date).ToString("yyyy-MM-dd'T'HH:mm:ss")
}
function Get-UtcNowForLabel {
    # yyyy-MM-ddTHH:mm:ssZ
    return Get-UtcNowForLog
}

function Add-LogMessage {
    param(
        [string]$Level,
        [string]$Message,
        [System.Collections.ArrayList]$LogList,
        [System.Windows.Forms.TextBox]$LogBox
    )
    # Use current UTC for UI/system logs
    $entry = "[$(Get-UtcNowForLog)] [$Level] $Message"
    if ($null -ne $LogList) {
        [void]$LogList.Add($entry)
    }
    if ($null -ne $LogBox) {
        if ($LogBox.InvokeRequired) {
            $LogBox.Invoke([Action]{ $LogBox.AppendText($entry + "`r`n") })
        }
        else {
            $LogBox.AppendText($entry + "`r`n")
        }
    }
}

function Get-SourceItemType {
    param([string]$RawPath)
    $resolved = Resolve-VariablePath -Path $RawPath
    if ($resolved -match '[\*\?]') { return "FILE" }
    if (Test-Path $resolved -PathType Container) { return "FOLDER" }
    return "FILE"
}

# ============================================================
# 3. CONFIGURATION MODULE
# ============================================================

function Load-ConfigFromFile {
    param([string]$FilePath)
    $result = @{
        SourceItems              = @()
        SnapshotName             = ""
        OutputLocation           = ""
        CreateArchive            = $true
        DeleteFolderAfterArchive = $false
        Success                  = $false
        ErrorMessage             = ""
    }
    if (-not (Test-Path $FilePath)) {
        $result.ErrorMessage = "File not found: $FilePath"
        return $result
    }
    try {
        $content = Get-Content -Path $FilePath -Raw -Encoding UTF8 -ErrorAction Stop
        $json = $content | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $json.SourceItems -and $json.SourceItems -is [array]) {
            $result.SourceItems = @($json.SourceItems)
        }
        if ($null -ne $json.SnapshotName -and $json.SnapshotName -is [string]) {
            $result.SnapshotName = $json.SnapshotName
        }
        if ($null -ne $json.OutputLocation -and $json.OutputLocation -is [string]) {
            $result.OutputLocation = $json.OutputLocation
        }
        if ($null -ne $json.CreateArchive -and $json.CreateArchive -is [bool]) {
            $result.CreateArchive = $json.CreateArchive
        }
        if ($null -ne $json.DeleteFolderAfterArchive -and $json.DeleteFolderAfterArchive -is [bool]) {
            $result.DeleteFolderAfterArchive = $json.DeleteFolderAfterArchive
        }
        $result.Success = $true
    }
    catch {
        $result.ErrorMessage = $_.Exception.Message
    }
    return $result
}

function Save-ConfigToFile {
    param(
        [string]$FilePath,
        [string[]]$SourceItems,
        [string]$SnapshotName,
        [string]$OutputLocation,
        [bool]$CreateArchive,
        [bool]$DeleteFolderAfterArchive
    )
    $portableItems = @()
    foreach ($item in $SourceItems) {
        $portableItems += Convert-ToPortablePath -Path $item
    }
    $config = @{
        SourceItems              = $portableItems
        SnapshotName             = $SnapshotName
        OutputLocation           = $OutputLocation
        CreateArchive            = $CreateArchive
        DeleteFolderAfterArchive = $DeleteFolderAfterArchive
    }
    try {
        $json = $config | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($FilePath, $json, [System.Text.Encoding]::UTF8)
        return @{ Success = $true; ErrorMessage = "" }
    }
    catch {
        return @{ Success = $false; ErrorMessage = $_.Exception.Message }
    }
}

# ============================================================
# 4. BUILD UI
# ============================================================

$script:MainForm = New-Object System.Windows.Forms.Form
$script:MainForm.Text = "SnapVault"
$script:MainForm.Size = New-Object System.Drawing.Size(900, 1200)
$script:MainForm.MinimumSize = New-Object System.Drawing.Size(720, 900)
$script:MainForm.StartPosition = "CenterScreen"
$script:MainForm.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$yPos = 15
$leftMargin = 20
$controlWidth = 840

# --- Source Items label with counts ---
$script:lblSourceItems = New-Object System.Windows.Forms.Label
$script:lblSourceItems.Text = "Source Items:  [Folders: 0 | Files: 0 | Total: 0]"
$script:lblSourceItems.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$script:lblSourceItems.Size = New-Object System.Drawing.Size($controlWidth, 22)
$script:MainForm.Controls.Add($script:lblSourceItems)
$yPos += 26

# Give more vertical space to Source Items list (now 280)
$script:lstSourceItems = New-Object System.Windows.Forms.ListBox
$script:lstSourceItems.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$script:lstSourceItems.Size = New-Object System.Drawing.Size($controlWidth, 280)
$script:lstSourceItems.SelectionMode = "MultiExtended"
$script:lstSourceItems.HorizontalScrollbar = $true
$script:lstSourceItems.Font = New-Object System.Drawing.Font("Consolas", 10)
$script:MainForm.Controls.Add($script:lstSourceItems)
$yPos += 286

$script:RawSourceItems = [System.Collections.ArrayList]::new()

# --- Manual input row ---
$script:txtManualInput = New-Object System.Windows.Forms.TextBox
$script:txtManualInput.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$script:txtManualInput.Size = New-Object System.Drawing.Size(($controlWidth - 110), 28)
$script:txtManualInput.Font = New-Object System.Drawing.Font("Consolas", 10)
$script:MainForm.Controls.Add($script:txtManualInput)

$script:btnManualAdd = New-Object System.Windows.Forms.Button
$script:btnManualAdd.Text = "Add"
$script:btnManualAdd.Size = New-Object System.Drawing.Size(100, 32)
$script:btnManualAdd.Location = New-Object System.Drawing.Point(($leftMargin + $controlWidth - 100), ($yPos - 2))
$script:MainForm.Controls.Add($script:btnManualAdd)
$yPos += 38

# --- Button row 1 ---
$script:btnAddFile = New-Object System.Windows.Forms.Button
$script:btnAddFile.Text = "+ Add File"
$script:btnAddFile.Size = New-Object System.Drawing.Size(160, 36)
$script:btnAddFile.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$script:MainForm.Controls.Add($script:btnAddFile)

$script:btnAddFolder = New-Object System.Windows.Forms.Button
$script:btnAddFolder.Text = "+ Add Folder"
$script:btnAddFolder.Size = New-Object System.Drawing.Size(160, 36)
$script:btnAddFolder.Location = New-Object System.Drawing.Point(($leftMargin + 170), $yPos)
$script:MainForm.Controls.Add($script:btnAddFolder)

$script:btnRemoveSelected = New-Object System.Windows.Forms.Button
$script:btnRemoveSelected.Text = "- Remove Selected"
$script:btnRemoveSelected.Size = New-Object System.Drawing.Size(200, 36)
$script:btnRemoveSelected.Location = New-Object System.Drawing.Point(($leftMargin + 440), $yPos)
$script:MainForm.Controls.Add($script:btnRemoveSelected)

$script:btnRemoveAll = New-Object System.Windows.Forms.Button
$script:btnRemoveAll.Text = "x Remove All"
$script:btnRemoveAll.Size = New-Object System.Drawing.Size(160, 36)
$script:btnRemoveAll.Location = New-Object System.Drawing.Point(($leftMargin + $controlWidth - 160), $yPos)
$script:MainForm.Controls.Add($script:btnRemoveAll)
$yPos += 44

$lblSymbolExplain = New-Object System.Windows.Forms.Label
$lblSymbolExplain.Text = "Symbol & Variable: ... = Current Folder (`${APPDIR}) = $($script:ScriptDir)"
$lblSymbolExplain.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$lblSymbolExplain.Size = New-Object System.Drawing.Size($controlWidth, 20)
$lblSymbolExplain.ForeColor = [System.Drawing.Color]::DarkBlue
$script:MainForm.Controls.Add($lblSymbolExplain)
$yPos += 22

$lblWildcardHint = New-Object System.Windows.Forms.Label
$lblWildcardHint.Text = "Wildcard: Supports * / ? / (optional) **   Examples: ...*.txt, ...\data\**\*.log"
$lblWildcardHint.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$lblWildcardHint.Size = New-Object System.Drawing.Size($controlWidth, 20)
$lblWildcardHint.ForeColor = [System.Drawing.Color]::DarkBlue
$script:MainForm.Controls.Add($lblWildcardHint)
$yPos += 30

$lblSnapshotName = New-Object System.Windows.Forms.Label
$lblSnapshotName.Text = "Snapshot Name:"
$lblSnapshotName.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$lblSnapshotName.Size = New-Object System.Drawing.Size(140, 22)
$script:MainForm.Controls.Add($lblSnapshotName)

$script:txtSnapshotName = New-Object System.Windows.Forms.TextBox
$script:txtSnapshotName.Location = New-Object System.Drawing.Point(($leftMargin + 145), $yPos)
$script:txtSnapshotName.Size = New-Object System.Drawing.Size(($controlWidth - 145), 26)
$script:txtSnapshotName.Text = $script:ScriptDirName
$script:MainForm.Controls.Add($script:txtSnapshotName)
$yPos += 34

$lblOutputLocation = New-Object System.Windows.Forms.Label
$lblOutputLocation.Text = "Output Location:"
$lblOutputLocation.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$lblOutputLocation.Size = New-Object System.Drawing.Size(140, 22)
$script:MainForm.Controls.Add($lblOutputLocation)

$script:txtOutputLocation = New-Object System.Windows.Forms.TextBox
$script:txtOutputLocation.Location = New-Object System.Drawing.Point(($leftMargin + 145), $yPos)
$script:txtOutputLocation.Size = New-Object System.Drawing.Size(($controlWidth - 145 - 110), 26)
$script:txtOutputLocation.Text = $script:ScriptDir
$script:MainForm.Controls.Add($script:txtOutputLocation)

$script:btnBrowseOutput = New-Object System.Windows.Forms.Button
$script:btnBrowseOutput.Text = "Browse"
$script:btnBrowseOutput.Size = New-Object System.Drawing.Size(100, 32)
$script:btnBrowseOutput.Location = New-Object System.Drawing.Point(($leftMargin + $controlWidth - 100), ($yPos - 3))
$script:MainForm.Controls.Add($script:btnBrowseOutput)
$yPos += 40

$lblArchiveOptions = New-Object System.Windows.Forms.Label
$lblArchiveOptions.Text = "Archive Options:"
$lblArchiveOptions.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$lblArchiveOptions.Size = New-Object System.Drawing.Size(140, 22)
$script:MainForm.Controls.Add($lblArchiveOptions)
$yPos += 26

# Place the two checkboxes HORIZONTALLY on the same row to save vertical space
$script:chkCreateArchive = New-Object System.Windows.Forms.CheckBox
$script:chkCreateArchive.Text = "Create archive (.7z)"
$script:chkCreateArchive.Location = New-Object System.Drawing.Point(($leftMargin + 20), $yPos)
$script:chkCreateArchive.Size = New-Object System.Drawing.Size(250, 24)
$script:chkCreateArchive.Checked = $true
if ($null -eq $script:7zPath) {
    $script:chkCreateArchive.Checked = $false
    $script:chkCreateArchive.Enabled = $false
}
$script:MainForm.Controls.Add($script:chkCreateArchive)

$script:chkDeleteFolder = New-Object System.Windows.Forms.CheckBox
$script:chkDeleteFolder.Text = "Delete folder after archive"
# place to the right on the same Y
$script:chkDeleteFolder.Location = New-Object System.Drawing.Point(($leftMargin + 320), $yPos)
$script:chkDeleteFolder.Size = New-Object System.Drawing.Size(260, 24)
$script:chkDeleteFolder.Checked = $false
if (-not $script:chkCreateArchive.Checked) {
    $script:chkDeleteFolder.Enabled = $false
}
$script:MainForm.Controls.Add($script:chkDeleteFolder)
$yPos += 34

if ($null -eq $script:7zPath) {
    $lbl7zWarn = New-Object System.Windows.Forms.Label
    $lbl7zWarn.Text = "[!] 7-Zip not found. Archive option disabled."
    $lbl7zWarn.Location = New-Object System.Drawing.Point(($leftMargin + 20), $yPos)
    $lbl7zWarn.Size = New-Object System.Drawing.Size(400, 20)
    $lbl7zWarn.ForeColor = [System.Drawing.Color]::Red
    $script:MainForm.Controls.Add($lbl7zWarn)
    $yPos += 24
}

# --- Dual time labels (Local & UTC, refresh every second) ---
$script:lblNowLocalTime = New-Object System.Windows.Forms.Label
$script:lblNowLocalTime.Text = "Current Local Time: " + (Get-LocalNowForLabel)
$script:lblNowLocalTime.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$script:lblNowLocalTime.Size = New-Object System.Drawing.Size($controlWidth, 22)
$script:MainForm.Controls.Add($script:lblNowLocalTime)
$yPos += 22

$script:lblNowUtcTime = New-Object System.Windows.Forms.Label
$script:lblNowUtcTime.Text = "Current UTC Time: " + (Get-UtcNowForLabel)
$script:lblNowUtcTime.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$script:lblNowUtcTime.Size = New-Object System.Drawing.Size($controlWidth, 22)
$script:MainForm.Controls.Add($script:lblNowUtcTime)
$yPos += 26

$lblPreview = New-Object System.Windows.Forms.Label
$lblPreview.Text = "Preview:"
$lblPreview.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$lblPreview.Size = New-Object System.Drawing.Size($controlWidth, 22)
$script:MainForm.Controls.Add($lblPreview)
$yPos += 24

$script:txtPreview = New-Object System.Windows.Forms.TextBox
$script:txtPreview.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$script:txtPreview.Size = New-Object System.Drawing.Size($controlWidth, 80)
$script:txtPreview.Multiline = $true
$script:txtPreview.ReadOnly = $true
$script:txtPreview.ScrollBars = "Vertical"
$script:txtPreview.BackColor = [System.Drawing.Color]::WhiteSmoke
$script:MainForm.Controls.Add($script:txtPreview)
$yPos += 86

$script:btnCreateSnapshot = New-Object System.Windows.Forms.Button
$script:btnCreateSnapshot.Text = "Create Snapshot"
$script:btnCreateSnapshot.Size = New-Object System.Drawing.Size(260, 42)
$script:btnCreateSnapshot.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$script:btnCreateSnapshot.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$script:MainForm.Controls.Add($script:btnCreateSnapshot)

$script:btnSaveConfig = New-Object System.Windows.Forms.Button
$script:btnSaveConfig.Text = "Save Config"
$script:btnSaveConfig.Size = New-Object System.Drawing.Size(260, 42)
$script:btnSaveConfig.Location = New-Object System.Drawing.Point(($leftMargin + 290), $yPos)
$script:MainForm.Controls.Add($script:btnSaveConfig)

$script:btnLoadConfig = New-Object System.Windows.Forms.Button
$script:btnLoadConfig.Text = "Load Config"
$script:btnLoadConfig.Size = New-Object System.Drawing.Size(260, 42)
$script:btnLoadConfig.Location = New-Object System.Drawing.Point(($leftMargin + 580), $yPos)
$script:MainForm.Controls.Add($script:btnLoadConfig)
$yPos += 52

$lblProgress = New-Object System.Windows.Forms.Label
$lblProgress.Text = "Progress:"
$lblProgress.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$lblProgress.Size = New-Object System.Drawing.Size(80, 22)
$script:MainForm.Controls.Add($lblProgress)

$script:lblPercent = New-Object System.Windows.Forms.Label
$script:lblPercent.Text = "0%"
$script:lblPercent.Location = New-Object System.Drawing.Point(($leftMargin + 80), $yPos)
$script:lblPercent.Size = New-Object System.Drawing.Size(60, 22)
$script:MainForm.Controls.Add($script:lblPercent)

$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Text = ""
$script:lblStatus.Location = New-Object System.Drawing.Point(($leftMargin + 145), $yPos)
$script:lblStatus.Size = New-Object System.Drawing.Size(($controlWidth - 145), 22)
$script:MainForm.Controls.Add($script:lblStatus)
$yPos += 24

$script:progressBar = New-Object System.Windows.Forms.ProgressBar
$script:progressBar.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$script:progressBar.Size = New-Object System.Drawing.Size($controlWidth, 26)
$script:progressBar.Minimum = 0
$script:progressBar.Maximum = 100
$script:progressBar.Value = 0
$script:MainForm.Controls.Add($script:progressBar)
$yPos += 34

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Log:"
$lblLog.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$lblLog.Size = New-Object System.Drawing.Size($controlWidth, 22)
$script:MainForm.Controls.Add($lblLog)
$yPos += 24

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$script:txtLog.Size = New-Object System.Drawing.Size($controlWidth, 200)
$script:txtLog.Multiline = $true
$script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = "Both"
$script:txtLog.WordWrap = $false
$script:txtLog.BackColor = [System.Drawing.Color]::White
$script:MainForm.Controls.Add($script:txtLog)
$yPos += 206

$script:lblCurrentFolder = New-Object System.Windows.Forms.Label
$script:lblCurrentFolder.Text = "Current Folder: $($script:ScriptDir)"
$script:lblCurrentFolder.Location = New-Object System.Drawing.Point($leftMargin, $yPos)
$script:lblCurrentFolder.Size = New-Object System.Drawing.Size($controlWidth, 22)
$script:lblCurrentFolder.ForeColor = [System.Drawing.Color]::DarkGreen
$script:MainForm.Controls.Add($script:lblCurrentFolder)

# ============================================================
# 5. PREVIEW TIMER (dual time + preview path)
# ============================================================

function Update-Preview {
    $name = $script:txtSnapshotName.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $script:ScriptDirName }
    $outDir = $script:txtOutputLocation.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = $script:ScriptDir }

    # Use a running (live) UTC ts for preview; when executing we lock new UTC
    $ts = if ($script:IsExecuting -and -not [string]::IsNullOrWhiteSpace($script:FileNameTimestamp)) {
        $script:FileNameTimestamp
    } else {
        Get-UtcNowForFileName
    }

    $folderName  = "${name}_${ts}"
    $archiveName = "${name}_${ts}.7z"
    $logName     = "${name}_${ts}.log"
    $configName  = "${name}_${ts}.config.json"

    $previewText = "Folder:  $outDir\$folderName`r`n"
    if ($script:chkCreateArchive.Checked) {
        $previewText += "Archive: $outDir\$archiveName`r`n"
    }
    $previewText += "Log:     $outDir\$folderName\$logName`r`n"
    $previewText += "Config:  $outDir\$folderName\$configName"
    $script:txtPreview.Text = $previewText
}

$script:PreviewTimer = New-Object System.Windows.Forms.Timer
$script:PreviewTimer.Interval = 1000
$script:PreviewTimer.Add_Tick({
    # Dual time labels refresh
    $script:lblNowLocalTime.Text = "Current Local Time: " + (Get-LocalNowForLabel)
    $script:lblNowUtcTime.Text   = "Current UTC Time: "   + (Get-UtcNowForLabel)
    # Preview refresh
    Update-Preview
})
$script:PreviewTimer.Start()

# ============================================================
# 6. UI HELPER FUNCTIONS
# ============================================================

function Update-SourceItemCounts {
    $folderCount = 0
    $fileCount   = 0
    foreach ($entry in $script:RawSourceItems) {
        if ($entry.Type -eq "FOLDER") { $folderCount++ }
        else { $fileCount++ }
    }
    $totalCount = $folderCount + $fileCount
    $script:lblSourceItems.Text = "Source Items:  [Folders: $folderCount | Files: $fileCount | Total: $totalCount]"
}

function Update-ButtonStates {
    $itemCount     = $script:lstSourceItems.Items.Count
    $selectedCount = $script:lstSourceItems.SelectedItems.Count
    $script:btnRemoveSelected.Enabled = ($selectedCount -gt 0)
    $script:btnRemoveAll.Enabled      = ($itemCount -gt 0)
}

function Refresh-SourceItemsList {
    $script:lstSourceItems.Items.Clear()
    $folders = [System.Collections.ArrayList]::new()
    $files   = [System.Collections.ArrayList]::new()
    for ($i = 0; $i -lt $script:RawSourceItems.Count; $i++) {
        $entry = $script:RawSourceItems[$i]
        if ($entry.Type -eq "FOLDER") { [void]$folders.Add($entry) }
        else { [void]$files.Add($entry) }
    }
    $sortedFolders = $folders | Sort-Object { (Get-DisplayString -RawPath $_.Raw).ToLowerInvariant() }
    $sortedFiles   = $files   | Sort-Object { (Get-DisplayString -RawPath $_.Raw).ToLowerInvariant() }
    $script:RawSourceItems = [System.Collections.ArrayList]::new()
    foreach ($entry in $sortedFolders) {
        [void]$script:RawSourceItems.Add($entry)
        [void]$script:lstSourceItems.Items.Add("[FOLDER] " + (Get-DisplayString -RawPath $entry.Raw))
    }
    foreach ($entry in $sortedFiles) {
        [void]$script:RawSourceItems.Add($entry)
        [void]$script:lstSourceItems.Items.Add("[FILE]   " + (Get-DisplayString -RawPath $entry.Raw))
    }
    Update-SourceItemCounts
    Update-ButtonStates
}

function Add-SourceItem {
    param([string]$Path, [string]$ItemType)
    $portable = Convert-ToPortablePath -Path $Path
    $display  = Get-DisplayString -RawPath $portable
    foreach ($existing in $script:RawSourceItems) {
        $existingDisplay = Get-DisplayString -RawPath $existing.Raw
        if ($existingDisplay.Equals($display, [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-LogMessage -Level "WARN" -Message "Duplicate path skipped: $display" -LogList $null -LogBox $script:txtLog
            return
        }
    }
    [void]$script:RawSourceItems.Add(@{ Raw = $portable; Type = $ItemType })
    Refresh-SourceItemsList
}

function Add-ManualInputItem {
    $inputText = $script:txtManualInput.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($inputText)) { return }
    $itemType = Get-SourceItemType -RawPath $inputText
    Add-SourceItem -Path $inputText -ItemType $itemType
    $script:txtManualInput.Clear()
    Update-Preview
}

function Apply-ConfigToUI {
    param($Config)
    $script:RawSourceItems.Clear()
    $script:lstSourceItems.Items.Clear()
    foreach ($item in $Config.SourceItems) {
        if (-not [string]::IsNullOrWhiteSpace($item)) {
            $display = Get-DisplayString -RawPath $item
            $isDup = $false
            foreach ($existing in $script:RawSourceItems) {
                if ((Get-DisplayString -RawPath $existing.Raw).Equals($display, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isDup = $true; break
                }
            }
            if (-not $isDup) {
                [void]$script:RawSourceItems.Add(@{ Raw = $item; Type = (Get-SourceItemType -RawPath $item) })
            }
        }
    }
    Refresh-SourceItemsList
    if (-not [string]::IsNullOrWhiteSpace($Config.SnapshotName)) { $script:txtSnapshotName.Text = $Config.SnapshotName }
    else { $script:txtSnapshotName.Text = $script:ScriptDirName }
    if (-not [string]::IsNullOrWhiteSpace($Config.OutputLocation)) { $script:txtOutputLocation.Text = $Config.OutputLocation }
    else { $script:txtOutputLocation.Text = $script:ScriptDir }
    if ($null -ne $script:7zPath) {
        $script:chkCreateArchive.Checked = $Config.CreateArchive
        $script:chkDeleteFolder.Checked  = $Config.DeleteFolderAfterArchive
        $script:chkDeleteFolder.Enabled  = $Config.CreateArchive
    }
    else {
        $script:chkCreateArchive.Checked = $false; $script:chkCreateArchive.Enabled = $false
        $script:chkDeleteFolder.Checked  = $false; $script:chkDeleteFolder.Enabled  = $false
    }
    Update-Preview; Update-ButtonStates
}

# ============================================================
# 7. EVENT HANDLERS (incl. keyboard shortcuts)
# ============================================================

# ListBox shortcuts: Ctrl+A (select all), Ctrl+C (copy), Delete (remove selected)
$script:lstSourceItems.Add_KeyDown({
    param($sender, $e)
    # Ctrl+A
    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::A) {
        for ($i = 0; $i -lt $script:lstSourceItems.Items.Count; $i++) {
            $script:lstSourceItems.SetSelected($i, $true)
        }
        $e.SuppressKeyPress = $true
        return
    }
    # Ctrl+C
    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::C) {
        if ($script:lstSourceItems.SelectedItems.Count -gt 0) {
            $lines = @()
            foreach ($it in $script:lstSourceItems.SelectedItems) { $lines += $it.ToString() }
            [System.Windows.Forms.Clipboard]::SetText(($lines -join "`r`n"))
        }
        $e.SuppressKeyPress = $true
        return
    }
    # Delete
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
        $sel = @($script:lstSourceItems.SelectedIndices)
        if ($sel.Count -gt 0) {
            foreach ($idx in ($sel | Sort-Object -Descending)) { $script:RawSourceItems.RemoveAt($idx) }
            Refresh-SourceItemsList; Update-Preview
        }
        $e.SuppressKeyPress = $true
        return
    }
})

# TextBox shortcuts: ensure Ctrl+A works on all text boxes
foreach ($tb in @($script:txtManualInput, $script:txtSnapshotName, $script:txtOutputLocation, $script:txtLog)) {
    $tb.Add_KeyDown({
        param($sender, $e)
        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::A) {
            $sender.SelectAll()
            $e.SuppressKeyPress = $true
        }
    })
}

$script:lstSourceItems.Add_SelectedIndexChanged({ Update-ButtonStates })
$script:btnManualAdd.Add_Click({ Add-ManualInputItem })
$script:txtManualInput.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -or $e.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
        $e.SuppressKeyPress = $true
        Add-ManualInputItem
    }
})

$script:btnAddFile.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Select Files to Add"; $dlg.Multiselect = $true
    $dlg.InitialDirectory = $script:LastBrowsePath; $dlg.Filter = "All Files (*.*)|*.*"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($f in $dlg.FileNames) {
            $script:LastBrowsePath = Split-Path -Parent $f
            Add-SourceItem -Path $f -ItemType "FILE"
        }
        Update-Preview
    }
})

$script:btnAddFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select a Folder to Add"; $dlg.SelectedPath = $script:LastBrowsePath
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:LastBrowsePath = $dlg.SelectedPath
        Add-SourceItem -Path $dlg.SelectedPath -ItemType "FOLDER"
        Update-Preview
    }
})

$script:btnRemoveSelected.Add_Click({
    $sel = @($script:lstSourceItems.SelectedIndices)
    if ($sel.Count -eq 0) { return }
    foreach ($idx in ($sel | Sort-Object -Descending)) { $script:RawSourceItems.RemoveAt($idx) }
    Refresh-SourceItemsList; Update-Preview
})

$script:btnRemoveAll.Add_Click({
    if ($script:lstSourceItems.Items.Count -eq 0) { return }
    if ([System.Windows.Forms.MessageBox]::Show("Remove all source items?","Confirm",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:RawSourceItems.Clear(); $script:lstSourceItems.Items.Clear()
        Update-SourceItemCounts; Update-ButtonStates; Update-Preview
    }
})

$script:btnBrowseOutput.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select Output Location"; $dlg.SelectedPath = $script:txtOutputLocation.Text
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:txtOutputLocation.Text = $dlg.SelectedPath; Update-Preview
    }
})

$script:txtSnapshotName.Add_TextChanged({
    if (Test-InvalidSnapshotName -Name $script:txtSnapshotName.Text) {
        $script:txtSnapshotName.BackColor = [System.Drawing.Color]::MistyRose
        $script:btnCreateSnapshot.Enabled = $false
    }
    else {
        $script:txtSnapshotName.BackColor = [System.Drawing.Color]::White
        $script:btnCreateSnapshot.Enabled = $true
    }
    Update-Preview
})

$script:txtOutputLocation.Add_TextChanged({ Update-Preview })

$script:chkCreateArchive.Add_CheckedChanged({
    if ($script:chkCreateArchive.Checked) { $script:chkDeleteFolder.Enabled = $true }
    else { $script:chkDeleteFolder.Checked = $false; $script:chkDeleteFolder.Enabled = $false }
    Update-Preview
})

$script:btnSaveConfig.Add_Click({
    $items = @(); foreach ($e in $script:RawSourceItems) { $items += (Resolve-VariablePath -Path $e.Raw) }
    $n = $script:txtSnapshotName.Text.Trim(); if ([string]::IsNullOrWhiteSpace($n)) { $n = "" }
    $r = Save-ConfigToFile -FilePath $script:ConfigPath -SourceItems $items -SnapshotName $n `
        -OutputLocation $script:txtOutputLocation.Text.Trim() `
        -CreateArchive $script:chkCreateArchive.Checked -DeleteFolderAfterArchive $script:chkDeleteFolder.Checked
    if ($r.Success) { Add-LogMessage -Level "INFO" -Message "Config saved to: $($script:ConfigPath)" -LogList $null -LogBox $script:txtLog }
    else {
        [System.Windows.Forms.MessageBox]::Show("Failed to save config: $($r.ErrorMessage)","Save Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
        Add-LogMessage -Level "ERROR" -Message "Config save failed: $($r.ErrorMessage)" -LogList $null -LogBox $script:txtLog
    }
})

$script:btnLoadConfig.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Select Configuration File"; $dlg.Filter = "JSON Files (*.json)|*.json|All Files (*.*)|*.*"
    $dlg.InitialDirectory = $script:ScriptDir; $dlg.CheckFileExists = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $cfg = Load-ConfigFromFile -FilePath $dlg.FileName
        if ($cfg.Success) { Apply-ConfigToUI -Config $cfg; Add-LogMessage -Level "INFO" -Message "Config loaded from: $($dlg.FileName)" -LogList $null -LogBox $script:txtLog }
        else { [System.Windows.Forms.MessageBox]::Show("Failed to load config: $($cfg.ErrorMessage)","Load Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) }
    }
})

# ============================================================
# 8. CREATE SNAPSHOT - EXECUTION ENGINE (UTC locked timestamps)
# ============================================================

$script:Runspace = $null; $script:PowerShell = $null; $script:ExecutionTimer = $null
$script:SyncHash = $null; $script:IsExecuting = $false

function Lock-UI {
    $script:IsExecuting = $true
    foreach ($ctrl in @(
        $script:btnCreateSnapshot, $script:btnSaveConfig, $script:btnLoadConfig,
        $script:btnAddFile, $script:btnAddFolder, $script:btnRemoveSelected, $script:btnRemoveAll,
        $script:btnBrowseOutput, $script:btnManualAdd, $script:txtManualInput, $script:lstSourceItems,
        $script:txtSnapshotName, $script:txtOutputLocation, $script:chkCreateArchive, $script:chkDeleteFolder
    )) {
        $ctrl.Enabled = $false
    }
}

function Unlock-UI {
    $script:IsExecuting = $false
    foreach ($ctrl in @(
        $script:btnCreateSnapshot, $script:btnSaveConfig, $script:btnLoadConfig,
        $script:btnAddFile, $script:btnAddFolder, $script:btnBrowseOutput, $script:btnManualAdd,
        $script:txtManualInput, $script:lstSourceItems, $script:txtSnapshotName, $script:txtOutputLocation
    )) {
        $ctrl.Enabled = $true
    }
    if ($null -ne $script:7zPath) {
        $script:chkCreateArchive.Enabled = $true
        $script:chkDeleteFolder.Enabled  = $script:chkCreateArchive.Checked
    }
    else { $script:chkCreateArchive.Enabled = $false; $script:chkDeleteFolder.Enabled = $false }
    Update-ButtonStates
}

$script:btnCreateSnapshot.Add_Click({
    if ($script:RawSourceItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Source Items list is empty.","Validation Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $snapshotName = $script:txtSnapshotName.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($snapshotName)) { $snapshotName = $script:ScriptDirName }
    if (Test-InvalidSnapshotName -Name $snapshotName) {
        [System.Windows.Forms.MessageBox]::Show("Snapshot name contains invalid characters.","Validation Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $outputLocation = $script:txtOutputLocation.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($outputLocation)) { $outputLocation = $script:ScriptDir }

    $rawPaths = @(); foreach ($e in $script:RawSourceItems) { $rawPaths += $e.Raw }

    # Lock UTC timestamps for this run
    $script:LockedUtcTimestamp = Get-UtcNowForLog
    $script:FileNameTimestamp  = Get-UtcNowForFileName

    Lock-UI
    $script:progressBar.Value = 0; $script:progressBar.Style = "Continuous"
    $script:lblPercent.Text = "0%"; $script:lblStatus.Text = "Preparing..."
    $script:txtLog.Clear()

    # SyncHash: LogMessages (UI queue), AllLogEntries (authoritative, append-only)
    $script:SyncHash = [hashtable]::Synchronized(@{
        Progress       = 0
        StatusText     = "Preparing..."
        LogMessages    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        AllLogEntries  = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        IsCompleted    = $false
        IsError        = $false
        ErrorMessage   = ""
        ResultFolder   = ""
        ResultArchive  = ""
    })

    $params = @{
        ScriptDir           = $script:ScriptDir
        ScriptDirName       = $script:ScriptDirName
        RawSourceItems      = $rawPaths
        SnapshotName        = $snapshotName
        OutputLocation      = $outputLocation
        CreateArchive       = $script:chkCreateArchive.Checked
        DeleteFolderAfterArchive = $script:chkDeleteFolder.Checked
        SevenZipPath        = $script:7zPath
        SyncHash            = $script:SyncHash
        LockedUtcTimestamp  = $script:LockedUtcTimestamp     # yyyy-MM-ddTHH:mm:ssZ
        FileNameTimestamp   = $script:FileNameTimestamp      # yyyyMMddTHHmmssZ
    }

    $script:Runspace = [runspacefactory]::CreateRunspace()
    $script:Runspace.ApartmentState = "STA"; $script:Runspace.ThreadOptions = "ReuseThread"
    $script:Runspace.Open()
    $script:PowerShell = [powershell]::Create()
    $script:PowerShell.Runspace = $script:Runspace

    [void]$script:PowerShell.AddScript({
        param($P)
        $sync      = $P.SyncHash
        $sDir      = $P.ScriptDir
        $sDirName  = $P.ScriptDirName
        $rawItems  = $P.RawSourceItems
        $snapName  = $P.SnapshotName
        $outLoc    = $P.OutputLocation
        $doArchive = $P.CreateArchive
        $doDelete  = $P.DeleteFolderAfterArchive
        $z7Path    = $P.SevenZipPath
        $lockedTs  = $P.LockedUtcTimestamp     # yyyy-MM-ddTHH:mm:ssZ (fixed for run, for log lines)
        $fnameTs   = $P.FileNameTimestamp      # yyyyMMddTHHmmssZ    (fixed for run, for names)

        # Capture locked timestamp value for inner function
        $tsFixed = $lockedTs
        function Write-Log {
            param([string]$Lvl, [string]$Msg)
            $line = "[$tsFixed] [$Lvl] $Msg"
            [void]$sync.LogMessages.Add($line)
            [void]$sync.AllLogEntries.Add($line)
        }

        function Set-Prog {
            param([int]$Val, [string]$Txt)
            $sync.Progress = $Val
            if ($Txt) { $sync.StatusText = $Txt }
        }

        function Res-Var { param([string]$P) return $P.Replace('${APPDIR}', $sDir) }

        function Get-Disp {
            param([string]$R)
            $n = $R.Replace('${APPDIR}', $sDir)
            if ($n.StartsWith($sDir, [System.StringComparison]::OrdinalIgnoreCase)) { return "..." + $n.Substring($sDir.Length) }
            if ($R.StartsWith('${APPDIR}', [System.StringComparison]::OrdinalIgnoreCase)) { return "..." + $R.Substring('${APPDIR}'.Length) }
            return $R
        }

        try {
            Write-Log "INFO" "SnapVault started."
            Write-Log "INFO" "APPDIR = $sDir"
            Set-Prog 2 "Validating..."

            if ($rawItems.Count -eq 0) {
                $sync.IsError = $true; $sync.ErrorMessage = "Source Items list is empty."
                $sync.IsCompleted = $true; return
            }

            Set-Prog 3 "Determining names..."

            # Use locked filename timestamp for names
            $fldName    = "${snapName}_${fnameTs}"
            $tgtFolder  = Join-Path $outLoc $fldName
            $cfgName    = "${snapName}_${fnameTs}.config.json"
            $logName    = "${snapName}_${fnameTs}.log"

            if (Test-Path $tgtFolder) {
                $sfx = 1
                while (Test-Path "${tgtFolder}_${sfx}") { $sfx++ }
                $tgtFolder = "${tgtFolder}_${sfx}"; $fldName = "${fldName}_${sfx}"
                $cfgName   = "${snapName}_${fnameTs}_${sfx}.config.json"
                $logName   = "${snapName}_${fnameTs}_${sfx}.log"
                Write-Log "WARN" "Target folder exists, rename to: $fldName"
            }

            Write-Log "INFO" "Snapshot folder: $fldName"
            Write-Log "INFO" "Log file: $logName"
            Write-Log "INFO" "Config file: $cfgName"
            Set-Prog 4 "Creating output directory..."

            if (-not (Test-Path $outLoc)) {
                try { New-Item -Path $outLoc -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-Log "INFO" "Created output dir: $outLoc" }
                catch { $sync.IsError = $true; $sync.ErrorMessage = "Failed to create output dir: $_"; $sync.IsCompleted = $true; return }
            }
            try { New-Item -Path $tgtFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null }
            catch { $sync.IsError = $true; $sync.ErrorMessage = "Failed to create snapshot folder: $_"; $sync.IsCompleted = $true; return }

            Set-Prog 5 "Expanding variables and wildcards..."
            $expList = [System.Collections.ArrayList]::new()
            Write-Log "INFO" "=== Source Item Expansion ==="

            foreach ($item in $rawItems) {
                $resolved = Res-Var -P $item
                $dsp      = Get-Disp -R $item
                $hasWC    = ($resolved -match '[\*\?]')
                $hasDbl   = ($resolved -match '\\\*\*\\')
                $cnt      = 0

                if ($hasWC -or $hasDbl) {
                    if ($hasDbl) {
                        $parts = $resolved -split '\\\*\*\\'; $pDir = $parts[0]
                        $flt = if ($parts.Count -gt 1) { $parts[1] } else { "*" }
                        if (Test-Path $pDir -PathType Container) {
                            try {
                                $fnd = @(Get-ChildItem -Path $pDir -Filter $flt -Recurse -File -ErrorAction Stop)
                                foreach ($f in $fnd) { [void]$expList.Add(@{ Path=$f.FullName; IsFolder=$false; Src=$dsp }) }
                                $cnt = $fnd.Count
                            } catch { Write-Log "WARN" "  Error expanding: $dsp - $_" }
                        } else { Write-Log "WARN" "  No match: $dsp (parent not found)" }
                    }
                    else {
                        $pDir = Split-Path -Parent $resolved; $flt = Split-Path -Leaf $resolved
                        if (Test-Path $pDir -PathType Container) {
                            try {
                                $fnd = @(Get-ChildItem -Path $pDir -Filter $flt -File -ErrorAction Stop)
                                foreach ($f in $fnd) { [void]$expList.Add(@{ Path=$f.FullName; IsFolder=$false; Src=$dsp }) }
                                $cnt = $fnd.Count
                            } catch { Write-Log "WARN" "  Error expanding: $dsp - $_" }
                        } else { Write-Log "WARN" "  No match: $dsp" }
                    }
                }
                else {
                    if (Test-Path $resolved) {
                        $isD = (Get-Item $resolved -ErrorAction SilentlyContinue).PSIsContainer
                        [void]$expList.Add(@{ Path=$resolved; IsFolder=$isD; Src=$dsp }); $cnt = 1
                    } else { Write-Log "WARN" "  Path not found, skipped: $dsp" }
                }
                Write-Log "INFO" "  $dsp -> $cnt match(es)"
            }

            $seen = @{}; $dedup = [System.Collections.ArrayList]::new()
            foreach ($e in $expList) {
                $k = $e.Path.ToLowerInvariant()
                if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$dedup.Add($e) }
                else { Write-Log "WARN" "  Duplicate skipped: $($e.Path)" }
            }
            $total = $dedup.Count
            Write-Log "INFO" "=== Expansion Complete: $total item(s) ==="
            if ($total -eq 0) { Write-Log "WARN" "No items to copy after expansion." }

            # Copy phase
            $cpStart = 5; $cpEnd = if ($doArchive) { 70 } else { 85 }; $cpRange = $cpEnd - $cpStart
            $okCnt = 0; $failCnt = 0; $skipCnt = 0
            Set-Prog $cpStart "Copying..."
            Write-Log "INFO" "=== Copy Phase Start ($total item(s)) ==="

            for ($i = 0; $i -lt $dedup.Count; $i++) {
                $e    = $dedup[$i]; $src = $e.Path; $isF = $e.IsFolder
                $seq  = "$($i+1)/$total"
                $rel  = $src
                if ($src.StartsWith($sDir, [System.StringComparison]::OrdinalIgnoreCase)) { $rel = "..." + $src.Substring($sDir.Length) }
                $tag  = if ($isF) { "FOLDER" } else { "FILE" }
                $pct  = $cpStart + [int](($i / [Math]::Max($total,1)) * $cpRange)
                Set-Prog $pct "Copying: $rel ($seq)"

                try {
                    if ($isF) {
                        $leaf = Split-Path -Leaf $src; $dst = Join-Path $tgtFolder $leaf
                        if (-not (Test-Path $dst)) { New-Item -Path $dst -ItemType Directory -Force -ErrorAction Stop | Out-Null }
                        Copy-Item -Path "$src\*" -Destination $dst -Recurse -Force -ErrorAction Stop
                    }
                    else {
                        $fn = Split-Path -Leaf $src; $dst = Join-Path $tgtFolder $fn
                        if (Test-Path $dst) {
                            $pn = Split-Path -Leaf (Split-Path -Parent $src)
                            $sd = Join-Path $tgtFolder $pn
                            if (-not (Test-Path $sd)) { New-Item -Path $sd -ItemType Directory -Force -ErrorAction Stop | Out-Null }
                            $dst = Join-Path $sd $fn
                        }
                        Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
                    }
                    $okCnt++
                    Write-Log "INFO" "  ($seq) [$tag] COMPLETED: $rel"
                }
                catch {
                    $em = $_.Exception.Message
                    if ($em -match 'used by another process|access is denied|cannot access|locked') {
                        $skipCnt++; Write-Log "WARN" "  ($seq) [$tag] SKIPPED: $rel -> $em"
                    }
                    else {
                        $failCnt++; Write-Log "ERROR" "  ($seq) [$tag] FAILED: $rel -> $em"
                    }
                }
            }
            Write-Log "INFO" "=== Copy Phase End ==="
            Write-Log "INFO" "Copy Summary: $okCnt completed, $failCnt failed, $skipCnt skipped (Total: $total)"
            Set-Prog $cpEnd "Copy done: $okCnt ok, $failCnt failed, $skipCnt skipped."

            # Metadata phase
            $mStart = $cpEnd; $mEnd = if ($doArchive) { 80 } else { 95 }
            Set-Prog $mStart "Saving config and log..."
            Write-Log "INFO" "Saving config and log."

            # Save config copy (timestamped name - locked ts)
            $cfgPath = Join-Path $tgtFolder $cfgName
            try {
                $pItems = @(); foreach ($it in $rawItems) { $pItems += $it }
                $cObj = @{ SourceItems=$pItems; SnapshotName=$snapName; OutputLocation=$outLoc; CreateArchive=$doArchive; DeleteFolderAfterArchive=$doDelete }
                [System.IO.File]::WriteAllText($cfgPath, ($cObj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)
                Write-Log "INFO" "Config copy saved: $cfgName"
            } catch { Write-Log "WARN" "Failed to save config copy: $_" }

            Set-Prog ([int](($mStart+$mEnd)/2)) "Saving log..."

            # Save log (timestamped name) - AllLogEntries contains all messages
            $logPath = Join-Path $tgtFolder $logName
            try {
                $logText = ($sync.AllLogEntries | ForEach-Object { $_ }) -join "`r`n"
                [System.IO.File]::WriteAllText($logPath, $logText, [System.Text.Encoding]::UTF8)
                Write-Log "INFO" "Log saved: $logName"
            } catch { Write-Log "WARN" "Failed to save log file: $_" }

            Set-Prog $mEnd "Metadata saved."

            # Compression phase
            $arcPath = ""
            if ($doArchive -and $null -ne $z7Path) {
                Set-Prog 80 "Creating archive (Ultra mode)..."
                Write-Log "INFO" "Creating archive (Ultra mode)..."
                $arcPath = Join-Path $outLoc "${fldName}.7z"
                $z7Args  = "a -t7z -mx=9 -m0=lzma2 -md=64m -ms=on `"$arcPath`" `"$tgtFolder\*`""
                try {
                    $proc = Start-Process -FilePath $z7Path -ArgumentList $z7Args -Wait -PassThru -NoNewWindow -ErrorAction Stop
                    if ($proc.ExitCode -eq 0) {
                        Write-Log "INFO" "Archive created: $arcPath"; Set-Prog 95 "Archive created."
                        if ($doDelete) {
                            Set-Prog 96 "Deleting source folder..."
                            try { Remove-Item -Path $tgtFolder -Recurse -Force -ErrorAction Stop; Write-Log "INFO" "Snapshot folder deleted." }
                            catch { Write-Log "WARN" "Failed to delete folder: $_" }
                        }
                    }
                    else {
                        Write-Log "ERROR" "7-Zip exit code: $($proc.ExitCode)"
                        $sync.IsError = $true; $sync.ErrorMessage = "Compression failed (exit $($proc.ExitCode)). Folder preserved."
                    }
                }
                catch { Write-Log "ERROR" "Compression failed: $_"; $sync.IsError = $true; $sync.ErrorMessage = "Compression failed: $_" }
            }
            else { Set-Prog 95 "Skipping archive." }

            # Finalize
            Set-Prog 98 "Finalizing..."
            Write-Log "INFO" "DONE"

            # Final log flush - rewrite ALL log entries to disk one last time
            try {
                if (Test-Path $tgtFolder) {
                    $finalLog = ($sync.AllLogEntries | ForEach-Object { $_ }) -join "`r`n"
                    [System.IO.File]::WriteAllText($logPath, $finalLog, [System.Text.Encoding]::UTF8)
                }
            } catch { }

            $sync.ResultFolder = $tgtFolder; $sync.ResultArchive = $arcPath
            Set-Prog 100 "Snapshot completed."
        }
        catch {
            $line = "[$tsFixed] [ERROR] Unexpected error: $_"
            [void]$sync.LogMessages.Add($line)
            [void]$sync.AllLogEntries.Add($line)
            $sync.IsError = $true; $sync.ErrorMessage = "Unexpected error: $_"
        }
        finally { $sync.IsCompleted = $true }
    })

    [void]$script:PowerShell.AddArgument($params)
    $script:AsyncResult = $script:PowerShell.BeginInvoke()

    # Execution polling timer - consumes LogMessages for UI display only
    $script:ExecutionTimer = New-Object System.Windows.Forms.Timer
    $script:ExecutionTimer.Interval = 100
    $script:ExecutionTimer.Add_Tick({
        $pct = $script:SyncHash.Progress
        if ($pct -lt 0) { $pct = 0 }; if ($pct -gt 100) { $pct = 100 }
        $script:progressBar.Value = $pct
        $script:lblPercent.Text   = "$pct%"
        $script:lblStatus.Text    = $script:SyncHash.StatusText

        # Drain UI log queue
        while ($script:SyncHash.LogMessages.Count -gt 0) {
            $msg = $null
            try { $msg = $script:SyncHash.LogMessages[0]; $script:SyncHash.LogMessages.RemoveAt(0) }
            catch { break }
            if ($null -ne $msg) { $script:txtLog.AppendText($msg + "`r`n") }
        }

        if ($script:SyncHash.IsCompleted) {
            $script:ExecutionTimer.Stop(); $script:ExecutionTimer.Dispose(); $script:ExecutionTimer = $null
            $script:progressBar.Value = $script:SyncHash.Progress
            $script:lblPercent.Text   = "$($script:SyncHash.Progress)%"
            $script:lblStatus.Text    = $script:SyncHash.StatusText
            try { $script:PowerShell.EndInvoke($script:AsyncResult); $script:PowerShell.Dispose(); $script:Runspace.Close(); $script:Runspace.Dispose() } catch { }
            Unlock-UI

            # Clear locked timestamps for next run's preview
            $script:LockedUtcTimestamp = $null
            $script:FileNameTimestamp  = $null

            if ($script:SyncHash.IsError) {
                [System.Windows.Forms.MessageBox]::Show($script:SyncHash.ErrorMessage,"Snapshot Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
            }
            else {
                $rm = "Snapshot completed successfully!`n"
                if (Test-Path $script:SyncHash.ResultFolder) { $rm += "Folder: $($script:SyncHash.ResultFolder)`n" }
                if (-not [string]::IsNullOrWhiteSpace($script:SyncHash.ResultArchive) -and (Test-Path $script:SyncHash.ResultArchive)) { $rm += "Archive: $($script:SyncHash.ResultArchive)" }
                [System.Windows.Forms.MessageBox]::Show($rm,"Snapshot Complete",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
            }
        }
    })
    $script:ExecutionTimer.Start()
})

# ============================================================
# 9. WINDOW CLOSE HANDLER
# ============================================================

$script:MainForm.Add_FormClosing({
    param($sender, $e)
    if ($script:IsExecuting) {
        $c = [System.Windows.Forms.MessageBox]::Show("A snapshot is in progress. Close anyway?","Confirm",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($c -eq [System.Windows.Forms.DialogResult]::No) { $e.Cancel = $true; return }
        try {
            if ($null -ne $script:ExecutionTimer) { $script:ExecutionTimer.Stop(); $script:ExecutionTimer.Dispose() }
            $script:PowerShell.Stop(); $script:PowerShell.Dispose()
            $script:Runspace.Close(); $script:Runspace.Dispose()
        } catch { }
    }
    if ($null -ne $script:PreviewTimer) { $script:PreviewTimer.Stop(); $script:PreviewTimer.Dispose() }
})

# ============================================================
# 10. STARTUP: LOAD DEFAULT CONFIG
# ============================================================

if (Test-Path $script:ConfigPath) {
    $sc = Load-ConfigFromFile -FilePath $script:ConfigPath
    if ($sc.Success) { Apply-ConfigToUI -Config $sc; Add-LogMessage -Level "INFO" -Message "Config loaded" -LogList $null -LogBox $script:txtLog }
    else { Add-LogMessage -Level "WARN" -Message "Config parse failed. Using defaults." -LogList $null -LogBox $script:txtLog }
}
else { Add-LogMessage -Level "INFO" -Message "No config found. Using defaults." -LogList $null -LogBox $script:txtLog }

Add-LogMessage -Level "INFO" -Message "APPDIR = $($script:ScriptDir)" -LogList $null -LogBox $script:txtLog
Update-Preview; Update-SourceItemCounts; Update-ButtonStates

# ============================================================
# 11. RUN APPLICATION
# ============================================================

[System.Windows.Forms.Application]::EnableVisualStyles()
[void]$script:MainForm.ShowDialog()
