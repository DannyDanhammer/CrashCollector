
# CrashCollector

CrashCollector is a PowerShell-based Windows crash evidence collector designed for situations where a system suddenly reboots, hard-locks, appears to power off, or comes back from an unexpected crash without an obvious blue screen.

It collects the evidence Windows usually leaves behind after an unclean restart: filtered event logs, high-value crash indicators, Reliability Monitor records, Windows Error Reporting data, crash dump metadata, driver inventory, storage and power diagnostics, scheduled task context, services, installed software, and system information. The goal is not to magically tell you “the cause” from one event. The goal is to preserve enough evidence to separate normal reboot noise from real root-cause signals.

CrashCollector is especially useful when Event Viewer only shows the classic vague pair:

```text
Kernel-Power 41
EventLog 6008
```

Those events confirm that Windows detected an unclean restart, but they do not explain why it happened. CrashCollector gives you a structured way to gather the surrounding context.

---

## What CrashCollector Collects

CrashCollector creates a timestamped evidence folder and ZIP archive containing:

- System information from `systeminfo`, CIM/WMI classes, driver inventory, BIOS details, memory, disks, GPUs, and Windows build data.
- Filtered Windows Event Logs around the suspected crash time.
- A high-value crash event report focusing on common crash, reboot, driver, disk, power, WHEA, and service failure events.
- A quick triage report with the most important events pulled to the top.
- Reliability Monitor records around the crash window.
- Windows Error Reporting files from `ReportArchive` and `ReportQueue`, where accessible.
- Crash dump metadata from `C:\Windows\Minidump`, `C:\Windows\MEMORY.DMP`, and `C:\Windows\LiveKernelReports`.
- Optional dump copying for minidumps and large kernel/live dumps.
- Storage health information from `Get-Disk`, `Get-Volume`, `Get-PhysicalDisk`, and `Get-StorageReliabilityCounter`.
- Power diagnostics from `powercfg`, including wake timers, power requests, battery report, sleep study, and system sleep diagnostics.
- Scheduled task inventory and task run metadata.
- Service inventory and installed software inventory.

By default, the current stable version avoids collectors that commonly hang or produce excessive data, such as raw EVTX export, Security log queries, registry export, and unsupported legacy SMART WMI classes.

---

## Why This Exists

Windows crash triage is often frustrating because the most visible events are symptoms, not causes.

For example:

```text
Kernel-Power 41
The system has rebooted without cleanly shutting down first.
```

That event does not mean the power supply failed. It means Windows noticed that it did not shut down cleanly. The real cause could be a BSOD, firmware reset, EC reset, GPU driver hang, USB-C controller failure, storage timeout, RAM instability, thermal shutdown, user hard reset, AC power loss, or something else below the level where normal logging survives.

CrashCollector exists to preserve the surrounding evidence quickly so you can determine whether the event looks like:

- A clean Windows-initiated reboot.
- A Windows Update or installer reboot.
- A BSOD with a dump.
- A kernel hang without a dump.
- A hardware error such as WHEA.
- A storage/controller timeout.
- A GPU watchdog failure.
- A USB-C/UCSI/driver framework problem.
- A power/thermal/firmware-level reset.
- A suspicious scheduled task or service event near the crash.

---

## Requirements

- Windows 10 or Windows 11.
- PowerShell 5.1 or newer.
- Administrator PowerShell recommended.
- Local disk space for logs and optional crash dumps.
- A system-managed page file is recommended if you want Windows to create useful crash dumps.

CrashCollector does not require third-party modules.

---

## Quick Start

Open PowerShell as Administrator.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Collect-CrashEvidence.ps1
```

By default, CrashCollector assumes the crash happened at the most recent `11:56 PM`. This default was chosen for the original investigation that produced the script. For general use, pass the actual crash time explicitly.

Example with exact crash time:

```powershell
.\Collect-CrashEvidence.ps1 -CrashTime "2026-06-29 23:56" -WindowMinutes 180
```

The output will be written to:

```text
C:\Users\<user>\Desktop\CrashEvidence\CrashEvidence_<COMPUTERNAME>_<timestamp>
```

A ZIP archive is created next to the evidence folder:

```text
C:\Users\<user>\Desktop\CrashEvidence\CrashEvidence_<COMPUTERNAME>_<timestamp>.zip
```

---

## Recommended Usage

For a normal crash triage run:

```powershell
.\Collect-CrashEvidence.ps1 -CrashTime "2026-06-29 23:56" -WindowMinutes 180
```

For a wider window:

```powershell
.\Collect-CrashEvidence.ps1 -CrashTime "2026-06-29 23:56" -WindowMinutes 360
```

For a faster run with shorter job timeouts:

```powershell
.\Collect-CrashEvidence.ps1 -CrashTime "2026-06-29 23:56" -WindowMinutes 180 -NativeTimeoutSeconds 20 -JobTimeoutSeconds 30
```

For a deeper run that exports raw EVTX files:

```powershell
.\Collect-CrashEvidence.ps1 -CrashTime "2026-06-29 23:56" -WindowMinutes 180 -ExportRawEvtx
```

For a run that includes the Security log:

```powershell
.\Collect-CrashEvidence.ps1 -CrashTime "2026-06-29 23:56" -WindowMinutes 180 -IncludeSecurityLog
```

For a run that copies large dump files:

```powershell
.\Collect-CrashEvidence.ps1 -CrashTime "2026-06-29 23:56" -WindowMinutes 180 -CopyLargeDumps
```

Use `-CopyLargeDumps` carefully. `MEMORY.DMP` and LiveKernelReports can be several gigabytes.

---

## Parameters

| Parameter | Type | Default | Purpose |
|---|---:|---:|---|
| `-CrashTime` | String | Most recent 11:56 PM | Suspected crash time. Use a parseable date/time string such as `2026-06-29 23:56`. |
| `-WindowMinutes` | Int | `120` | Minutes before and after `CrashTime` to query event logs. |
| `-OutputRoot` | String | `$env:USERPROFILE\Desktop\CrashEvidence` | Root directory for evidence folders and ZIP files. |
| `-CopyLargeDumps` | Switch | Off | Copies large dumps such as `MEMORY.DMP` or large LiveKernelReports dumps. |
| `-ExportRawEvtx` | Switch | Off | Exports raw EVTX files with `wevtutil`. Disabled by default to avoid hangs and huge output. |
| `-IncludeSecurityLog` | Switch | Off | Includes the Security event log. Disabled by default because it can be large and slow. |
| `-NativeTimeoutSeconds` | Int | `30` | Timeout for native commands such as `systeminfo`, `driverquery`, `powercfg`, and `wevtutil`. |
| `-JobTimeoutSeconds` | Int | `45` | Timeout for PowerShell jobs such as CIM queries, scheduled tasks, services, and event queries. |

---

## Output Layout

A typical output folder looks like this:

```text
CrashEvidence_<COMPUTERNAME>_<timestamp>\
├── README_FIRST.txt
├── collection.log
├── command_output\
│   ├── systeminfo.txt
│   ├── driverquery_verbose.csv
│   ├── pnputil_enum_drivers.txt
│   └── whoami_all.txt
├── dumps\
│   ├── dump_file_metadata.csv
│   ├── dump_file_metadata.txt
│   └── copied_dump_hashes_sha256.csv
├── events_filtered\
│   ├── System.filtered.csv
│   ├── Application.filtered.csv
│   ├── Microsoft-Windows-Kernel-Boot_Operational.filtered.csv
│   └── ...
├── hardware\
│   ├── Win32_OperatingSystem.csv
│   ├── Win32_ComputerSystem.csv
│   ├── Win32_BIOS.csv
│   ├── Win32_DiskDrive.csv
│   ├── Win32_VideoController.csv
│   ├── Get-Disk.csv
│   ├── Get-PhysicalDisk.csv
│   └── StorageReliabilityCounter.csv
├── power\
│   ├── powercfg_lastwake.txt
│   ├── powercfg_requests.txt
│   ├── powercfg_waketimers.txt
│   ├── battery-report.html
│   └── sleepstudy.html
├── reports\
│   ├── SUMMARY.txt
│   ├── 03_QuickTriage.txt
│   ├── 03_QuickTriage.csv
│   ├── 00_HighValueCrashEvents.txt
│   ├── 00_HighValueCrashEvents.csv
│   ├── 01_AllFilteredEvents.csv
│   ├── 02_ReliabilityRecords.txt
│   ├── ScheduledTasks.csv
│   ├── Services.csv
│   └── InstalledSoftware.csv
└── wer_reports\
    └── copied Windows Error Reporting files, when available
```

---

## First Files to Review

Start here:

```text
reports\SUMMARY.txt
```

Then review:

```text
reports\03_QuickTriage.txt
reports\00_HighValueCrashEvents.txt
reports\01_AllFilteredEvents.csv
reports\02_ReliabilityRecords.txt
dumps\dump_file_metadata.txt
```

The quick triage file is intentionally short and biased toward crash-related events. The full filtered event CSV is useful when the cause is subtle or when you need to build a second-by-second timeline.

---

## Interpreting Common Events

### Kernel-Power 41

`Kernel-Power 41` means Windows restarted without a clean shutdown.

It does not prove the power supply failed. It does not prove the battery failed. It does not prove the user held the power button. It only proves Windows did not complete a normal shutdown sequence.

Common causes include:

- Power loss.
- Battery or AC adapter interruption.
- Thermal or embedded-controller reset.
- Firmware reset.
- Kernel hang.
- BSOD without a usable dump.
- GPU/driver hang.
- Storage/controller deadlock.
- User hard reset.

### EventLog 6008

`EventLog 6008` means Windows detected that the previous shutdown was unexpected.

It usually appears after reboot, not at the exact moment of failure.

### BugCheck 1001

`BugCheck 1001` usually indicates a BSOD. The message often contains the stop code and parameters.

If you see BugCheck 1001 near the crash time, look for:

```text
C:\Windows\MEMORY.DMP
C:\Windows\Minidump\*.dmp
```

### volmgr 161 / 162 / 46

These events indicate crash dump configuration or dump-writing problems.

They matter because they explain why you may have had a BSOD or kernel failure but no dump file.

### WHEA-Logger 17 / 18 / 19 / 47

WHEA events indicate hardware error reporting.

`WHEA-Logger 18` is especially important. It often points toward CPU, memory, PCIe, motherboard, firmware, or power instability.

### Disk 7 / 51 / 129 / 153 / 157

These indicate disk, storage, or controller trouble.

`Disk 129` and `Disk 153` are especially useful for NVMe/SATA timeout or retry behavior.

### Display 4101

`Display 4101` commonly indicates the display driver stopped responding and recovered.

If paired with LiveKernelEvent 141 or 117, suspect GPU driver, GPU hardware, power management, external display paths, hybrid graphics, or thermal instability.

### LiveKernelEvent 141

Often associated with GPU hangs or display watchdog events.

This does not always crash the entire system, but repeated 141 events are strong evidence of graphics subsystem instability.

### LiveKernelEvent 193

Often associated with watchdog or hardware/driver timeout conditions.

Interpret it in context with dump paths, driver names, and device activity.

### LiveKernelEvent 1d4 / UcmUcsiCx.sys

This can point toward USB-C/UCSI behavior, USB-C controller firmware, docking, charging negotiation, Type-C devices, or USB-C power/display paths.

If this appears, test without docks, hubs, USB-C displays, phones, capture cards, or third-party chargers.

### Event 1074

`Event 1074` usually indicates a planned shutdown or restart.

It often names the process and user that initiated the reboot. If 1074 appears shortly before the reboot, the incident may be a legitimate Windows-initiated restart rather than a hard crash.

---

## Building a Timeline

For hard crashes, the absence of evidence can matter.

A normal shutdown often has a visible chain of events before reboot:

- Event 1074 indicating who or what initiated shutdown.
- Services stopping cleanly.
- Windows Update or installer events.
- Event log shutdown events.
- Planned reboot records.

A hard crash often looks different:

```text
Normal activity
[gap]
Boot events begin
Kernel-Power 41 appears after boot
EventLog 6008 reports previous shutdown was unexpected
Startup services begin
Post-boot application/service errors appear
```

Post-boot crashes should not automatically be blamed for the reboot. A service crashing after Windows starts is often downstream noise.

---

## Crash Dumps

CrashCollector does not analyze dumps directly. It collects dump metadata and optionally copies dump files.

Relevant locations:

```text
C:\Windows\MEMORY.DMP
C:\Windows\Minidump\*.dmp
C:\Windows\LiveKernelReports\*.dmp
C:\Windows\LiveKernelReports\WATCHDOG\*.dmp
C:\Windows\LiveKernelReports\WHEA\*.dmp
C:\Windows\LiveKernelReports\USBXHCI\*.dmp
```

If no fresh dump exists after a crash, that usually means one of the following:

- The crash was not a BSOD.
- The system lost power or reset below the OS level.
- Dump writing failed.
- Pagefile configuration prevented dump creation.
- The disk was unavailable during crash handling.
- Crash dump settings were disabled or misconfigured.

---

## Recommended Dump Configuration

To improve the chances of capturing the next crash, run this from Administrator PowerShell or Command Prompt:

```powershell
New-Item -ItemType Directory -Force -Path C:\CrashDumps | Out-Null

reg add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v CrashDumpEnabled /t REG_DWORD /d 2 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v DumpFile /t REG_EXPAND_SZ /d "C:\Windows\MEMORY.DMP" /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v MinidumpDir /t REG_EXPAND_SZ /d "C:\Windows\Minidump" /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v AlwaysKeepMemoryDump /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v Overwrite /t REG_DWORD /d 1 /f

wmic computersystem where name="%computername%" set AutomaticManagedPagefile=True
```

Reboot after changing dump settings.

After the next crash, check for new dumps:

```powershell
Get-ChildItem C:\Windows\MEMORY.DMP,C:\Windows\Minidump\*.dmp,C:\Windows\LiveKernelReports\*.dmp -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object FullName, Length, LastWriteTime
```

---

## Optional Dump Analysis with WinDbg

Install WinDbg from Microsoft Store or Windows SDK, then open the dump and run:

```text
.symfix
.reload
!analyze -v
lm
```

Useful commands:

```text
!analyze -v
kv
lmtn
!thread
!process 0 1
!sysinfo machineid
!sysinfo cpuspeed
```

For LiveKernelReports related to display or USB-C, pay close attention to the faulting module, device stack, and bugcheck/live-kernel code.

---

## Stability Isolation Workflow

CrashCollector is evidence collection, not a cure. After a hard crash with no dump, use the evidence to isolate suspects.

A practical workflow:

1. Configure kernel dumps.
2. Run CrashCollector after each crash.
3. Compare timelines across incidents.
4. Disable or remove obvious post-boot crashers only as a test.
5. Disconnect docks, USB-C hubs, capture cards, external displays, and non-OEM chargers.
6. Update BIOS/UEFI and vendor firmware.
7. Clean-install GPU drivers if WATCHDOG or LiveKernelEvent 141 appears.
8. Run memory testing if WHEA or random hard resets continue.
9. Check storage firmware and SMART tooling if Disk 129/153/157 appears.
10. Use Driver Verifier only when prepared for forced BSODs and possible Safe Mode recovery.

---

## Driver Verifier Warning

Driver Verifier can help identify bad third-party kernel drivers, but it can also make a system unbootable until disabled.

To enable standard checks:

```powershell
verifier /standard /all
```

To disable:

```powershell
verifier /reset
```

If the system boot-loops, boot into Safe Mode and run:

```powershell
verifier /reset
```

Do not enable Driver Verifier casually on a production system without backups.

---

## Troubleshooting CrashCollector

### The script hangs

The stable version runs most risky collectors in jobs or native process timeouts. If a system still hangs, reduce the timeouts:

```powershell
.\Collect-CrashEvidence.ps1 -CrashTime "2026-06-29 23:56" -WindowMinutes 180 -NativeTimeoutSeconds 15 -JobTimeoutSeconds 20
```

### Some event logs are missing

That is normal. Not all Windows editions/builds expose the same logs.

You may see messages such as:

```text
NoMatchingLogsFound
No events were found that match the specified selection criteria.
```

These are not fatal.

### WER copy errors

Windows Error Reporting folders sometimes contain long paths, locked files, or transient report queue items. A partial WER copy is still useful.

### No dumps were copied

If `copied_dump_hashes_sha256.empty.txt` exists, CrashCollector did not copy a dump. Check `dumps\dump_file_metadata.txt` to see whether any dumps exist but were too large or outside the selected time window.

Use `-CopyLargeDumps` if you need large dumps copied.

### The ZIP is huge

Large dump files and raw EVTX exports can make the archive huge. Avoid `-CopyLargeDumps` and `-ExportRawEvtx` unless you need them.

---

## Security and Privacy Notes

CrashCollector output may contain sensitive data, including:

- Hostname and username.
- Installed software inventory.
- Driver inventory.
- Service paths.
- Scheduled task actions.
- Event log messages.
- Windows Error Reporting metadata.
- Dump file paths.
- Crash dumps, if copied.

Crash dumps can contain memory fragments, paths, command lines, tokens, document names, URLs, and other sensitive material.

Do not post the ZIP publicly. Redact before sharing.

---

## What CrashCollector Does Not Do

CrashCollector does not:

- Prove root cause by itself.
- Replace WinDbg analysis.
- Replace vendor diagnostics.
- Perform full forensic acquisition.
- Preserve volatile memory.
- Guarantee dump creation after a crash.
- Fix drivers, firmware, BIOS, RAM, storage, or power issues.
- Guarantee that Windows logged the original failure.

For sudden hard resets, the key evidence may not exist inside Windows logs. In those cases, repeated collection plus controlled isolation is the right method.

---

## Suggested Repository Layout

```text
CrashCollector\
├── README.md
├── Collect-CrashEvidence.ps1
├── LICENSE
└── examples\
    ├── basic-run.txt
    ├── deep-run-with-evtx.txt
    └── dump-settings.ps1
```

---

## Example Investigation Flow

After a crash:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Collect-CrashEvidence.ps1 -CrashTime "2026-06-29 23:56" -WindowMinutes 180
```

Open:

```text
reports\SUMMARY.txt
reports\03_QuickTriage.txt
reports\00_HighValueCrashEvents.txt
```

Ask these questions:

1. Is there Event 1074 before reboot?
   - Yes: likely planned shutdown/reboot. Identify process and user.
   - No: continue.

2. Is there BugCheck 1001?
   - Yes: look for a matching minidump or MEMORY.DMP.
   - No: continue.

3. Is there WHEA-Logger 18/19?
   - Yes: suspect hardware/firmware/power/PCIe/RAM/CPU.
   - No: continue.

4. Are there Disk 129/153/157 events?
   - Yes: suspect storage/controller/firmware/driver/power.
   - No: continue.

5. Are there Display 4101 or LiveKernelEvent 141/193 reports?
   - Yes: suspect GPU/display driver/hybrid graphics/external display path.
   - No: continue.

6. Are there USB/UCSI/DriverFrameworks events?
   - Yes: suspect USB-C, docks, hubs, charging negotiation, or device firmware.
   - No: continue.

7. Is there only Kernel-Power 41 and EventLog 6008?
   - Treat it as a hard reset or kernel/firmware-level failure until proven otherwise.

---

## Known Design Choices

### Registry collection is skipped by default

Some systems can hang on registry export or even registry reads during unstable post-crash conditions. CrashCollector prioritizes completing the evidence run over collecting every possible artifact.

### Raw EVTX export is optional

Raw EVTX files are valuable, but they can be large and slow. Use `-ExportRawEvtx` only when you need archival-quality event logs.

### Security log is optional

The Security log can be large and noisy. Use `-IncludeSecurityLog` when you suspect user logon, privilege, task, or process activity matters.

### SMART legacy WMI collection is skipped

`MSStorageDriver_FailurePredictStatus` is not supported on many modern systems, especially NVMe systems. CrashCollector relies on modern storage cmdlets where possible.

---

## Naming

The project is called **CrashCollector**.

The default script name is:

```text
Collect-CrashEvidence.ps1
```

You can rename it to `CrashCollector.ps1` if preferred.

---

## Disclaimer

CrashCollector is a diagnostic evidence collector. It is provided as-is. Review the script before running it, especially in enterprise environments. Test in a safe environment before using it during incident response or on production systems.
