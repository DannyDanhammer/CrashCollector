<#
Collect-CrashEvidence.ps1

Fast/stable crash evidence collector.

Default crash time:
- Most recent 11:56 PM

Run from elevated PowerShell:
    Set-ExecutionPolicy -Scope Process Bypass
    .\Collect-CrashEvidence.ps1

Exact crash time:
    .\Collect-CrashEvidence.ps1 -CrashTime "2026-06-29 23:56" -WindowMinutes 180

Optional:
    -CopyLargeDumps      Copies MEMORY.DMP and large LiveKernelReports dumps.
    -ExportRawEvtx       Exports raw EVTX files. Disabled by default to avoid hangs.
    -IncludeSecurityLog  Queries Security log. Disabled by default because it can be large/slow.
#>

param(
    [string]$CrashTime = "",
    [int]$WindowMinutes = 120,
    [string]$OutputRoot = "$env:USERPROFILE\Desktop\CrashEvidence",
    [switch]$CopyLargeDumps,
    [switch]$ExportRawEvtx,
    [switch]$IncludeSecurityLog,
    [int]$NativeTimeoutSeconds = 30,
    [int]$JobTimeoutSeconds = 45
)

$ErrorActionPreference = "Continue"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Safe-Name {
    param([string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_')
}

function Write-Log {
    param([string]$Message)

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line

    if ($script:RunLog) {
        Add-Content -Path $script:RunLog -Value $line
    }
}

function Export-Data {
    param(
        [object]$Data,
        [string]$BasePath
    )

    if ($null -eq $Data) {
        "No data returned." | Out-File -FilePath "$BasePath.empty.txt" -Encoding UTF8
        return
    }

    try {
        @($Data) |
            Export-Csv -Path "$BasePath.csv" -NoTypeInformation -Encoding UTF8
    }
    catch {
        "CSV export failed: $($_.Exception.Message)" |
            Out-File "$BasePath.csv.error.txt" -Encoding UTF8
    }

    try {
        @($Data) |
            ConvertTo-Json -Depth 10 |
            Out-File -FilePath "$BasePath.json" -Encoding UTF8 -Width 4096
    }
    catch {
        "JSON export failed: $($_.Exception.Message)" |
            Out-File "$BasePath.json.error.txt" -Encoding UTF8
    }

    try {
        @($Data) |
            Format-List * |
            Out-File -FilePath "$BasePath.txt" -Encoding UTF8 -Width 4096
    }
    catch {
        "TXT export failed: $($_.Exception.Message)" |
            Out-File "$BasePath.txt.error.txt" -Encoding UTF8
    }
}

function Invoke-JobWithTimeout {
    param(
        [string]$Name,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 45
    )

    Write-Log "Running job: $Name"

    $job = $null

    try {
        $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList

        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds

        if ($null -eq $completed) {
            Write-Log "Timeout: $Name exceeded $TimeoutSeconds seconds. Stopping job."

            Stop-Job -Job $job -Force -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

            return $null
        }

        $result = Receive-Job -Job $job -ErrorAction Continue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

        return $result
    }
    catch {
        Write-Log "Failed job: $Name - $($_.Exception.Message)"

        if ($null -ne $job) {
            Stop-Job -Job $job -Force -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }

        return $null
    }
}

function Run-NativeCommand {
    param(
        [string]$Name,
        [string]$Exe,
        [string[]]$ArgList,
        [string]$OutFile,
        [int]$TimeoutSeconds = 30
    )

    Write-Log "Running native command: $Name"

    $tempOut = "$OutFile.stdout.tmp"
    $tempErr = "$OutFile.stderr.tmp"

    try {
        Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
        Remove-Item $tempErr -Force -ErrorAction SilentlyContinue

        $proc = Start-Process `
            -FilePath $Exe `
            -ArgumentList $ArgList `
            -RedirectStandardOutput $tempOut `
            -RedirectStandardError $tempErr `
            -NoNewWindow `
            -PassThru

        $finished = $proc.WaitForExit($TimeoutSeconds * 1000)

        if (-not $finished) {
            Write-Log "Timeout: $Name exceeded $TimeoutSeconds seconds. Killing PID $($proc.Id)."
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

            "TIMEOUT: $Name exceeded $TimeoutSeconds seconds and was killed.`r`n" |
                Out-File -FilePath $OutFile -Encoding UTF8
        }
        else {
            "Command: $Exe $($ArgList -join ' ')`r`nExitCode: $($proc.ExitCode)`r`n" |
                Out-File -FilePath $OutFile -Encoding UTF8
        }

        if (Test-Path $tempOut) {
            "`r`n--- STDOUT ---`r`n" | Add-Content -Path $OutFile
            Get-Content $tempOut -ErrorAction SilentlyContinue | Add-Content -Path $OutFile
        }

        if (Test-Path $tempErr) {
            "`r`n--- STDERR ---`r`n" | Add-Content -Path $OutFile
            Get-Content $tempErr -ErrorAction SilentlyContinue | Add-Content -Path $OutFile
        }
    }
    catch {
        "FAILED: $Name`r`n$($_.Exception.Message)" |
            Out-File -FilePath $OutFile -Encoding UTF8

        Write-Log "Failed native command: $Name - $($_.Exception.Message)"
    }
    finally {
        Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
        Remove-Item $tempErr -Force -ErrorAction SilentlyContinue
    }
}

function Copy-FileSafe {
    param(
        [string]$Source,
        [string]$DestinationDirectory
    )

    try {
        if (Test-Path $Source) {
            New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
            Copy-Item -Path $Source -Destination $DestinationDirectory -Force -ErrorAction Stop
            Write-Log "Copied: $Source"
        }
    }
    catch {
        Write-Log "Failed to copy $Source - $($_.Exception.Message)"
    }
}

function Convert-ReliabilityTime {
    param([string]$TimeGenerated)

    try {
        return [Management.ManagementDateTimeConverter]::ToDateTime($TimeGenerated)
    }
    catch {
        return $null
    }
}

# Resolve crash time.
if ([string]::IsNullOrWhiteSpace($CrashTime)) {
    $candidate = [datetime]::Today.AddHours(23).AddMinutes(56)

    if ($candidate -gt (Get-Date)) {
        $candidate = $candidate.AddDays(-1)
    }

    $CrashDate = $candidate
}
else {
    try {
        $CrashDate = [datetime]::Parse($CrashTime)
    }
    catch {
        throw "Could not parse CrashTime '$CrashTime'. Use format like: 2026-06-29 23:56"
    }
}

$StartTime = $CrashDate.AddMinutes(-1 * $WindowMinutes)
$EndTime   = $CrashDate.AddMinutes($WindowMinutes)

$stamp = $CrashDate.ToString("yyyyMMdd_HHmmss")
$OutDir = Join-Path $OutputRoot "CrashEvidence_$($env:COMPUTERNAME)_$stamp"

$Dirs = @{
    Root     = $OutDir
    Reports  = Join-Path $OutDir "reports"
    Events   = Join-Path $OutDir "events_filtered"
    RawEvtx  = Join-Path $OutDir "events_raw_evtx"
    Dumps    = Join-Path $OutDir "dumps"
    WER      = Join-Path $OutDir "wer_reports"
    Commands = Join-Path $OutDir "command_output"
    Hardware = Join-Path $OutDir "hardware"
    Power    = Join-Path $OutDir "power"
}

foreach ($dir in $Dirs.Values) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$script:RunLog = Join-Path $OutDir "collection.log"

Write-Log "Crash evidence collection started."
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User: $env:USERNAME"
Write-Log "Admin: $(Test-IsAdmin)"
Write-Log "Crash time: $CrashDate"
Write-Log "Window start: $StartTime"
Write-Log "Window end: $EndTime"
Write-Log "Native timeout seconds: $NativeTimeoutSeconds"
Write-Log "Job timeout seconds: $JobTimeoutSeconds"
Write-Log "Output: $OutDir"

@"
Crash Evidence Collection

Computer:       $env:COMPUTERNAME
User:           $env:USERNAME
Admin:          $(Test-IsAdmin)
Crash time:     $CrashDate
Window start:   $StartTime
Window end:     $EndTime
Window minutes: $WindowMinutes

This is the fast/stable collector.

It intentionally skips:
- Registry collection
- WMI SMART MSStorageDriver_FailurePredictStatus
- Raw EVTX export unless -ExportRawEvtx is specified
- Security log unless -IncludeSecurityLog is specified

Start review here:

1. reports\SUMMARY.txt
2. reports\03_QuickTriage.txt
3. reports\00_HighValueCrashEvents.txt
4. reports\01_AllFilteredEvents.csv
5. reports\02_ReliabilityRecords.txt
6. dumps\dump_file_metadata.txt
7. wer_reports\

Likely crash indicators:

- Kernel-Power 41: unclean restart
- EventLog 6008: unexpected shutdown
- BugCheck 1001: BSOD / stop code
- WHEA-Logger 17/18/19/47: hardware error
- Disk 7/51/129/153/157: storage trouble
- volmgr 46/161/162: dump creation problem
- Display 4101: GPU driver timeout/recovery
- Event 1074: planned restart/shutdown
"@ | Out-File -FilePath (Join-Path $OutDir "README_FIRST.txt") -Encoding UTF8

# Native system info.
Write-Log "Collecting native system information."

Run-NativeCommand -Name "systeminfo" -Exe "systeminfo.exe" -ArgList @("/FO", "LIST") -OutFile (Join-Path $Dirs.Commands "systeminfo.txt") -TimeoutSeconds $NativeTimeoutSeconds
Run-NativeCommand -Name "driverquery verbose" -Exe "driverquery.exe" -ArgList @("/v", "/fo", "csv") -OutFile (Join-Path $Dirs.Commands "driverquery_verbose.csv") -TimeoutSeconds $NativeTimeoutSeconds
Run-NativeCommand -Name "whoami all" -Exe "whoami.exe" -ArgList @("/all") -OutFile (Join-Path $Dirs.Commands "whoami_all.txt") -TimeoutSeconds $NativeTimeoutSeconds
Run-NativeCommand -Name "pnputil enum-drivers" -Exe "pnputil.exe" -ArgList @("/enum-drivers") -OutFile (Join-Path $Dirs.Commands "pnputil_enum_drivers.txt") -TimeoutSeconds $NativeTimeoutSeconds

# CIM system info.
Write-Log "Collecting CIM system information."

$CimClasses = @(
    "Win32_OperatingSystem",
    "Win32_ComputerSystem",
    "Win32_BIOS",
    "Win32_Processor",
    "Win32_PhysicalMemory",
    "Win32_DiskDrive",
    "Win32_LogicalDisk",
    "Win32_VideoController",
    "Win32_PnPSignedDriver",
    "Win32_QuickFixEngineering"
)

foreach ($class in $CimClasses) {
    $data = Invoke-JobWithTimeout `
        -Name "CIM $class" `
        -TimeoutSeconds $JobTimeoutSeconds `
        -ArgumentList @($class) `
        -ScriptBlock {
            param($ClassName)
            Get-CimInstance -ClassName $ClassName -ErrorAction Stop
        }

    Export-Data -Data $data -BasePath (Join-Path $Dirs.Hardware $class)
}

# Storage health.
Write-Log "Collecting storage health."

$data = Invoke-JobWithTimeout `
    -Name "Get-Disk" `
    -TimeoutSeconds $JobTimeoutSeconds `
    -ScriptBlock {
        Get-Disk | Select-Object *
    }

Export-Data -Data $data -BasePath (Join-Path $Dirs.Hardware "Get-Disk")

$data = Invoke-JobWithTimeout `
    -Name "Get-Volume" `
    -TimeoutSeconds $JobTimeoutSeconds `
    -ScriptBlock {
        Get-Volume | Select-Object *
    }

Export-Data -Data $data -BasePath (Join-Path $Dirs.Hardware "Get-Volume")

$data = Invoke-JobWithTimeout `
    -Name "Get-PhysicalDisk" `
    -TimeoutSeconds $JobTimeoutSeconds `
    -ScriptBlock {
        Get-PhysicalDisk | Select-Object *
    }

Export-Data -Data $data -BasePath (Join-Path $Dirs.Hardware "Get-PhysicalDisk")

$data = Invoke-JobWithTimeout `
    -Name "StorageReliabilityCounter" `
    -TimeoutSeconds $JobTimeoutSeconds `
    -ScriptBlock {
        $physicalDisks = Get-PhysicalDisk
        Get-StorageReliabilityCounter -PhysicalDisk $physicalDisks | Select-Object *
    }

Export-Data -Data $data -BasePath (Join-Path $Dirs.Hardware "StorageReliabilityCounter")

# Power diagnostics.
Write-Log "Collecting power diagnostics."

Run-NativeCommand -Name "powercfg lastwake" -Exe "powercfg.exe" -ArgList @("/lastwake") -OutFile (Join-Path $Dirs.Power "powercfg_lastwake.txt") -TimeoutSeconds $NativeTimeoutSeconds
Run-NativeCommand -Name "powercfg requests" -Exe "powercfg.exe" -ArgList @("/requests") -OutFile (Join-Path $Dirs.Power "powercfg_requests.txt") -TimeoutSeconds $NativeTimeoutSeconds
Run-NativeCommand -Name "powercfg waketimers" -Exe "powercfg.exe" -ArgList @("/waketimers") -OutFile (Join-Path $Dirs.Power "powercfg_waketimers.txt") -TimeoutSeconds $NativeTimeoutSeconds
Run-NativeCommand -Name "powercfg available sleep states" -Exe "powercfg.exe" -ArgList @("/a") -OutFile (Join-Path $Dirs.Power "powercfg_available_sleep_states.txt") -TimeoutSeconds $NativeTimeoutSeconds
Run-NativeCommand -Name "powercfg batteryreport" -Exe "powercfg.exe" -ArgList @("/batteryreport", "/output", (Join-Path $Dirs.Power "battery-report.html")) -OutFile (Join-Path $Dirs.Power "batteryreport_command.txt") -TimeoutSeconds $NativeTimeoutSeconds
Run-NativeCommand -Name "powercfg sleepstudy" -Exe "powercfg.exe" -ArgList @("/sleepstudy", "/output", (Join-Path $Dirs.Power "sleepstudy.html")) -OutFile (Join-Path $Dirs.Power "sleepstudy_command.txt") -TimeoutSeconds $NativeTimeoutSeconds
Run-NativeCommand -Name "powercfg systemsleepdiagnostics" -Exe "powercfg.exe" -ArgList @("/systemsleepdiagnostics", "/output", (Join-Path $Dirs.Power "systemsleepdiagnostics.html")) -OutFile (Join-Path $Dirs.Power "systemsleepdiagnostics_command.txt") -TimeoutSeconds $NativeTimeoutSeconds

# Event logs.
Write-Log "Collecting Windows event logs."

$LogsToQuery = @(
    "System",
    "Application",
    "Microsoft-Windows-Kernel-Boot/Operational",
    "Microsoft-Windows-Kernel-Power/Thermal-Operational",
    "Microsoft-Windows-Diagnostics-Performance/Operational",
    "Microsoft-Windows-WER-SystemErrorReporting/Operational",
    "Microsoft-Windows-Windows Error Reporting/Operational",
    "Microsoft-Windows-DriverFrameworks-UserMode/Operational",
    "Microsoft-Windows-TaskScheduler/Operational",
    "Microsoft-Windows-WindowsUpdateClient/Operational",
    "Microsoft-Windows-Power-Troubleshooter/Operational"
)

if ($IncludeSecurityLog) {
    $LogsToQuery += "Security"
}

$AllEvents = New-Object System.Collections.Generic.List[object]

foreach ($log in $LogsToQuery) {
    $safe = Safe-Name $log

    $exists = Invoke-JobWithTimeout `
        -Name "Check log $log" `
        -TimeoutSeconds 15 `
        -ArgumentList @($log) `
        -ScriptBlock {
            param($LogName)
            Get-WinEvent -ListLog $LogName -ErrorAction Stop | Select-Object LogName, RecordCount, IsEnabled
        }

    if ($null -eq $exists) {
        Write-Log "Skipping unavailable/inaccessible log: $log"
        continue
    }

    Export-Data -Data $exists -BasePath (Join-Path $Dirs.Events "$safe.loginfo")

    if ($ExportRawEvtx) {
        Run-NativeCommand `
            -Name "wevtutil export $log" `
            -Exe "wevtutil.exe" `
            -ArgList @("epl", "$log", (Join-Path $Dirs.RawEvtx "$safe.evtx"), "/ow:true") `
            -OutFile (Join-Path $Dirs.RawEvtx "$safe.export.txt") `
            -TimeoutSeconds $NativeTimeoutSeconds
    }

    $rows = Invoke-JobWithTimeout `
        -Name "Filtered events $log" `
        -TimeoutSeconds $JobTimeoutSeconds `
        -ArgumentList @($log, $StartTime, $EndTime) `
        -ScriptBlock {
            param($LogName, $Start, $End)

            $events = Get-WinEvent -FilterHashtable @{
                LogName   = $LogName
                StartTime = $Start
                EndTime   = $End
            } -ErrorAction Stop

            foreach ($ev in $events) {
                [pscustomobject]@{
                    TimeCreated      = $ev.TimeCreated
                    LogName          = $ev.LogName
                    ProviderName     = $ev.ProviderName
                    Id               = $ev.Id
                    LevelDisplayName = $ev.LevelDisplayName
                    MachineName      = $ev.MachineName
                    ProcessId        = $ev.ProcessId
                    ThreadId         = $ev.ThreadId
                    RecordId         = $ev.RecordId
                    Message          = $ev.Message
                }
            }
        }

    Export-Data -Data $rows -BasePath (Join-Path $Dirs.Events "$safe.filtered")

    foreach ($row in @($rows)) {
        if ($null -ne $row) {
            $AllEvents.Add($row)
        }
    }
}

$AllEventsSorted = @($AllEvents | Sort-Object TimeCreated)

$AllEventsSorted |
    Export-Csv -Path (Join-Path $Dirs.Reports "01_AllFilteredEvents.csv") -NoTypeInformation -Encoding UTF8

$AllEventsSorted |
    Format-List * |
    Out-File -FilePath (Join-Path $Dirs.Reports "01_AllFilteredEvents.txt") -Encoding UTF8 -Width 4096

# High-value event extraction.
Write-Log "Extracting high-value crash events."

$InterestingIds = @(
    41,
    42,
    1074,
    6005,
    6006,
    6008,
    1001,
    1000,
    1002,
    10110,
    10111,
    17,
    18,
    19,
    47,
    7,
    11,
    15,
    51,
    55,
    57,
    129,
    153,
    157,
    46,
    161,
    162,
    4101,
    219,
    7000,
    7001,
    7011,
    7022,
    7023,
    7031,
    7034,
    7040
)

$InterestingProviderPatterns = @(
    "Kernel-Power",
    "WHEA-Logger",
    "WER-SystemErrorReporting",
    "Windows Error Reporting",
    "EventLog",
    "BugCheck",
    "Disk",
    "Ntfs",
    "volmgr",
    "Service Control Manager",
    "DriverFrameworks",
    "Display",
    "Kernel-Boot",
    "Power-Troubleshooter"
)

$HighValue = @(
    $AllEventsSorted |
        Where-Object {
            $event = $_
            ($InterestingIds -contains $event.Id) -or
            ($InterestingProviderPatterns | Where-Object { $event.ProviderName -like "*$_*" })
        } |
        Sort-Object TimeCreated
)

$HighValue |
    Export-Csv -Path (Join-Path $Dirs.Reports "00_HighValueCrashEvents.csv") -NoTypeInformation -Encoding UTF8

$HighValue |
    Format-List * |
    Out-File -FilePath (Join-Path $Dirs.Reports "00_HighValueCrashEvents.txt") -Encoding UTF8 -Width 4096

$QuickTriage = @(
    $HighValue |
        Where-Object {
            $_.Id -in @(41, 6008, 1001, 1074, 18, 19, 47, 129, 153, 161, 162, 4101)
        } |
        Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message |
        Sort-Object TimeCreated
)

$QuickTriage |
    Export-Csv -Path (Join-Path $Dirs.Reports "03_QuickTriage.csv") -NoTypeInformation -Encoding UTF8

$QuickTriage |
    Format-List * |
    Out-File -FilePath (Join-Path $Dirs.Reports "03_QuickTriage.txt") -Encoding UTF8 -Width 4096

# Reliability Monitor records.
Write-Log "Collecting Reliability Monitor records."

$ReliabilityRaw = Invoke-JobWithTimeout `
    -Name "Reliability Records" `
    -TimeoutSeconds $JobTimeoutSeconds `
    -ScriptBlock {
        Get-CimInstance -ClassName Win32_ReliabilityRecords -ErrorAction Stop
    }

$Reliability = foreach ($record in @($ReliabilityRaw)) {
    $recordTime = Convert-ReliabilityTime -TimeGenerated $record.TimeGenerated

    if ($null -ne $recordTime -and $recordTime -ge $StartTime -and $recordTime -le $EndTime) {
        [pscustomobject]@{
            TimeCreated     = $recordTime
            SourceName      = $record.SourceName
            EventIdentifier = $record.EventIdentifier
            ProductName     = $record.ProductName
            User            = $record.User
            Message         = $record.Message
        }
    }
}

$Reliability = @($Reliability | Sort-Object TimeCreated)

Export-Data -Data $Reliability -BasePath (Join-Path $Dirs.Reports "02_ReliabilityRecords")

# WER reports.
Write-Log "Collecting Windows Error Reporting files."

$WerRoots = @(
    "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
    "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
    "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive",
    "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue"
) | Where-Object { Test-Path $_ }

$WerStart = $StartTime.AddHours(-12)
$WerEnd   = $EndTime.AddHours(12)

foreach ($root in $WerRoots) {
    try {
        Write-Log "Scanning WER root: $root"

        $werFiles = Get-ChildItem -Path $root -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LastWriteTime -ge $WerStart -and $_.LastWriteTime -le $WerEnd
            }

        foreach ($file in @($werFiles)) {
            $relative = $file.FullName.Substring($root.Length).TrimStart("\")
            $destRoot = Join-Path $Dirs.WER (Safe-Name $root)
            $destFile = Join-Path $destRoot $relative
            $destDir = Split-Path $destFile -Parent

            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            Copy-Item -Path $file.FullName -Destination $destFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log "WER collection failed for $root - $($_.Exception.Message)"
    }
}

# Dumps.
Write-Log "Collecting crash dump metadata and minidumps."

$DumpCandidates = @(
    "C:\Windows\Minidump\*.dmp",
    "C:\Windows\MEMORY.DMP",
    "C:\Windows\LiveKernelReports\*.dmp",
    "C:\Windows\LiveKernelReports\WATCHDOG\*.dmp",
    "C:\Windows\LiveKernelReports\WHEA\*.dmp",
    "C:\Windows\LiveKernelReports\USBXHCI\*.dmp"
)

$DumpFiles = foreach ($pattern in $DumpCandidates) {
    Get-ChildItem -Path $pattern -Force -ErrorAction SilentlyContinue
}

$DumpFiles = @($DumpFiles)

$DumpMetadata = @(
    $DumpFiles |
        Select-Object FullName, Length, CreationTime, LastWriteTime
)

Export-Data -Data $DumpMetadata -BasePath (Join-Path $Dirs.Dumps "dump_file_metadata")

$RecentDumps = @(
    $DumpFiles |
        Where-Object {
            $_.LastWriteTime -ge $StartTime.AddHours(-12) -and
            $_.LastWriteTime -le $EndTime.AddHours(12)
        }
)

foreach ($dump in $RecentDumps) {
    $isLarge = $dump.Length -gt 200MB

    if ($dump.FullName -like "C:\Windows\Minidump\*" -or $CopyLargeDumps -or -not $isLarge) {
        Copy-FileSafe -Source $dump.FullName -DestinationDirectory $Dirs.Dumps
    }
    else {
        Write-Log "Skipped large dump without -CopyLargeDumps: $($dump.FullName) size=$($dump.Length)"
    }
}

$CopiedDumps = @(
    Get-ChildItem -Path $Dirs.Dumps -Filter "*.dmp" -File -ErrorAction SilentlyContinue
)

$CopiedDumpHashes = foreach ($d in $CopiedDumps) {
    Get-FileHash -Algorithm SHA256 -Path $d.FullName
}

Export-Data -Data $CopiedDumpHashes -BasePath (Join-Path $Dirs.Dumps "copied_dump_hashes_sha256")

# Scheduled tasks.
Write-Log "Collecting scheduled task information."

$TaskRows = Invoke-JobWithTimeout `
    -Name "Scheduled Tasks" `
    -TimeoutSeconds $JobTimeoutSeconds `
    -ScriptBlock {
        Get-ScheduledTask | ForEach-Object {
            $task = $_

            try {
                $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath

                [pscustomobject]@{
                    TaskName       = $task.TaskName
                    TaskPath       = $task.TaskPath
                    State          = $task.State
                    Author         = $task.Author
                    LastRunTime    = $info.LastRunTime
                    LastTaskResult = $info.LastTaskResult
                    NextRunTime    = $info.NextRunTime
                }
            }
            catch {
                [pscustomobject]@{
                    TaskName       = $task.TaskName
                    TaskPath       = $task.TaskPath
                    State          = $task.State
                    Author         = $task.Author
                    LastRunTime    = $null
                    LastTaskResult = $null
                    NextRunTime    = $null
                }
            }
        }
    }

Export-Data -Data $TaskRows -BasePath (Join-Path $Dirs.Reports "ScheduledTasks")

# Services and installed software.
Write-Log "Collecting service and installed software context."

$Services = Invoke-JobWithTimeout `
    -Name "Services" `
    -TimeoutSeconds $JobTimeoutSeconds `
    -ScriptBlock {
        Get-CimInstance Win32_Service |
            Select-Object Name, DisplayName, State, StartMode, StartName, PathName
    }

Export-Data -Data $Services -BasePath (Join-Path $Dirs.Reports "Services")

$Installed = Invoke-JobWithTimeout `
    -Name "Installed Software" `
    -TimeoutSeconds $JobTimeoutSeconds `
    -ScriptBlock {
        $UninstallRoots = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )

        foreach ($root in $UninstallRoots) {
            Get-ItemProperty $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName } |
                Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation, UninstallString
        }
    }

Export-Data -Data $Installed -BasePath (Join-Path $Dirs.Reports "InstalledSoftware")

# Last boot.
$LastBoot = Invoke-JobWithTimeout `
    -Name "Last Boot Time" `
    -TimeoutSeconds 20 `
    -ScriptBlock {
        (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    }

# Summary.
Write-Log "Writing summary."

$summaryPath = Join-Path $Dirs.Reports "SUMMARY.txt"

@"
Crash Evidence Summary

Computer:              $env:COMPUTERNAME
Crash Time:            $CrashDate
Window:                $StartTime through $EndTime
Last Boot Time:        $LastBoot
Admin:                 $(Test-IsAdmin)

High-value event count: $(@($HighValue).Count)
All filtered count:      $(@($AllEventsSorted).Count)
Quick triage count:      $(@($QuickTriage).Count)
Reliability count:       $(@($Reliability).Count)
Dump file count:         $(@($DumpFiles).Count)
Recent dump count:       $(@($RecentDumps).Count)

Review order:

1. reports\03_QuickTriage.txt
2. reports\00_HighValueCrashEvents.txt
3. reports\01_AllFilteredEvents.csv
4. reports\02_ReliabilityRecords.txt
5. dumps\dump_file_metadata.txt
6. wer_reports\
7. hardware\Get-PhysicalDisk.txt
8. hardware\StorageReliabilityCounter.txt
9. power\*.txt

Interpretation hints:

Kernel-Power 41:
    Windows detected an unclean restart. This confirms the symptom, not the root cause.

EventLog 6008:
    Windows noticed that the prior shutdown was unexpected.

BugCheck 1001:
    Usually means BSOD. The stop code and parameters in the message matter.

WHEA-Logger 18:
    Strong hardware signal: CPU, memory, PCIe, motherboard, firmware, or power instability.

Disk 129 / 153:
    Storage timeout/reset/retry. Possible disk, NVMe, SATA, controller, driver, firmware, or power issue.

volmgr 161 / 162:
    Dump creation problem. Important if there was a BSOD but no dump.

Display 4101:
    GPU timeout/recovery.

Event 1074:
    Planned restart/shutdown. Check the process and user in the message.

Skipped by design:
    Registry collection was skipped because registry access hung on this system.
    SMART MSStorageDriver_FailurePredictStatus was skipped because it returned "Not supported."
    Raw EVTX export was skipped unless -ExportRawEvtx was specified.
    Security log was skipped unless -IncludeSecurityLog was specified.

Important:
    Crash dumps and WER files can contain sensitive data. Do not post the zip publicly.
"@ | Out-File -FilePath $summaryPath -Encoding UTF8

# Zip.
Write-Log "Compressing evidence."

$ZipPath = "$OutDir.zip"

try {
    if (Test-Path $ZipPath) {
        Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
    }

    Compress-Archive -Path (Join-Path $OutDir "*") -DestinationPath $ZipPath -Force
    Write-Log "Created zip: $ZipPath"
}
catch {
    Write-Log "Compress-Archive failed: $($_.Exception.Message)"
    Write-Log "Evidence still exists uncompressed at: $OutDir"
}

Write-Host ""
Write-Host "Done."
Write-Host "Evidence folder: $OutDir"
Write-Host "Evidence zip:    $ZipPath"
Write-Host ""
Write-Host "Open first:"
Write-Host "  $summaryPath"
Write-Host ""
Write-Host "Then open:"
Write-Host "  $(Join-Path $Dirs.Reports "03_QuickTriage.txt")"
Write-Host "  $(Join-Path $Dirs.Reports "00_HighValueCrashEvents.txt")"