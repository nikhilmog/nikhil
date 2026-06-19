#Requires -RunAsAdministrator
#Requires -Modules WebAdministration

<#
.SYNOPSIS
    Monitors IIS application pool states and auto-restarts stopped pools.

.DESCRIPTION
    Polls all IIS application pools every 60 seconds. If a pool is Stopped,
    captures recent Windows Event Log errors, restarts the pool, and logs all
    actions to C:\Logs\iis-monitor.log.

.PARAMETER DryRun
    Shows what the script would do without actually restarting any pool.

.PARAMETER PollIntervalSeconds
    How often to check pool states. Defaults to 60.

.EXAMPLE
    .\iis-pool-monitor.ps1
    .\iis-pool-monitor.ps1 -DryRun
    .\iis-pool-monitor.ps1 -PollIntervalSeconds 30
#>

[CmdletBinding()]
param (
    [switch]$DryRun,
    [int]$PollIntervalSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$LogDir  = 'C:\Logs'
$LogFile = Join-Path $LogDir 'iis-monitor.log'
$EventLookbackMinutes = 10

# ---------------------------------------------------------------------------
# State tracking for rollback
# ---------------------------------------------------------------------------
# Stores pool name -> state captured at script start
$script:OriginalPoolStates = @{}
$script:MonitoringActive   = $true

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DRY-RUN')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    # Write to console with colour
    $colour = switch ($Level) {
        'INFO'    { 'Cyan'    }
        'WARN'    { 'Yellow'  }
        'ERROR'   { 'Red'     }
        'DRY-RUN' { 'Magenta' }
    }
    Write-Host $line -ForegroundColor $colour

    # Append to log file (best-effort; never crash the monitor loop)
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {
        Write-Warning "Could not write to log file: $_"
    }
}

# ---------------------------------------------------------------------------
# Ensure log directory exists
# ---------------------------------------------------------------------------
function Initialize-LogDirectory {
    if (-not (Test-Path $LogDir)) {
        try {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
            Write-Log "Created log directory: $LogDir"
        } catch {
            Write-Error "Cannot create log directory '$LogDir': $_"
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# Capture Windows Event Log errors from the last N minutes
# ---------------------------------------------------------------------------
function Get-RecentEventErrors {
    [CmdletBinding()]
    param(
        [int]$MinutesBack = $EventLookbackMinutes
    )

    $since = (Get-Date).AddMinutes(-$MinutesBack)
    $logs  = @('System', 'Application')
    $entries = @()

    foreach ($log in $logs) {
        try {
            $events = Get-WinEvent -FilterHashtable @{
                LogName   = $log
                Level     = 1, 2  # Critical (1) and Error (2)
                StartTime = $since
            } -ErrorAction SilentlyContinue

            if ($events) {
                $entries += $events | Select-Object -Property TimeCreated, Id, LevelDisplayName,
                    ProviderName, Message
            }
        } catch {
            Write-Log "Could not query '$log' event log: $_" -Level WARN
        }
    }

    return $entries
}

# ---------------------------------------------------------------------------
# Snapshot current pool states (used for rollback)
# ---------------------------------------------------------------------------
function Save-PoolStates {
    Write-Log "Snapshotting current application pool states for rollback."
    try {
        $pools = Get-WebConfiguration 'system.applicationHost/applicationPools/add'
        foreach ($pool in $pools) {
            $state = (Get-WebAppPoolState -Name $pool.name).Value
            $script:OriginalPoolStates[$pool.name] = $state
            Write-Log "  Snapshot: '$($pool.name)' => $state"
        }
    } catch {
        Write-Log "Failed to snapshot pool states: $_" -Level ERROR
    }
}

# ---------------------------------------------------------------------------
# Rollback: stop monitoring and restore each pool to its original state
# ---------------------------------------------------------------------------
function Invoke-Rollback {
    Write-Log "=== ROLLBACK INITIATED ===" -Level WARN
    $script:MonitoringActive = $false

    foreach ($poolName in $script:OriginalPoolStates.Keys) {
        $originalState = $script:OriginalPoolStates[$poolName]
        try {
            $currentState = (Get-WebAppPoolState -Name $poolName).Value

            if ($currentState -eq $originalState) {
                Write-Log "Pool '$poolName' already in original state ($originalState). No action needed."
                continue
            }

            if ($DryRun) {
                Write-Log "[DRY-RUN] Would restore '$poolName' from $currentState to $originalState." -Level 'DRY-RUN'
                continue
            }

            switch ($originalState) {
                'Started' {
                    if ($currentState -ne 'Started') {
                        Start-WebAppPool -Name $poolName
                        Write-Log "Rollback: Started pool '$poolName'."
                    }
                }
                'Stopped' {
                    if ($currentState -ne 'Stopped') {
                        Stop-WebAppPool -Name $poolName
                        Write-Log "Rollback: Stopped pool '$poolName'."
                    }
                }
                default {
                    Write-Log "Rollback: Unknown original state '$originalState' for pool '$poolName'. Skipping." -Level WARN
                }
            }
        } catch {
            Write-Log "Rollback failed for pool '$poolName': $_" -Level ERROR
        }
    }

    Write-Log "=== ROLLBACK COMPLETE ===" -Level WARN
}

# ---------------------------------------------------------------------------
# Restart a single stopped pool (idempotent)
# ---------------------------------------------------------------------------
function Restart-StoppedPool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PoolName
    )

    try {
        # Idempotency check: read state immediately before acting
        $state = (Get-WebAppPoolState -Name $PoolName).Value

        if ($state -eq 'Started') {
            Write-Log "Pool '$PoolName' is already Running. No restart needed."
            return
        }

        if ($state -ne 'Stopped') {
            Write-Log "Pool '$PoolName' is in state '$state' (not Stopped). Skipping restart." -Level WARN
            return
        }

        # Capture event log context before restarting
        Write-Log "Capturing recent Event Log errors before restarting '$PoolName'..."
        $errors = Get-RecentEventErrors -MinutesBack $EventLookbackMinutes

        if ($errors.Count -gt 0) {
            Write-Log "Found $($errors.Count) error/critical event(s) in the last $EventLookbackMinutes minutes:"
            foreach ($evt in $errors | Select-Object -First 10) {
                $msg = ($evt.Message -replace '\r?\n', ' ').Substring(0, [Math]::Min(200, $evt.Message.Length))
                Write-Log "  [$($evt.TimeCreated)] [$($evt.LevelDisplayName)] $($evt.ProviderName) (ID $($evt.Id)): $msg" -Level WARN
            }
            if ($errors.Count -gt 10) {
                Write-Log "  ... and $($errors.Count - 10) more. See Event Viewer for full details." -Level WARN
            }
        } else {
            Write-Log "No error/critical events found in the last $EventLookbackMinutes minutes."
        }

        if ($DryRun) {
            Write-Log "[DRY-RUN] Would restart pool '$PoolName' (currently $state)." -Level 'DRY-RUN'
            return
        }

        # Attempt the restart
        Write-Log "Restarting pool '$PoolName'..."
        Start-WebAppPool -Name $PoolName

        # Verify the pool came up
        Start-Sleep -Seconds 3
        $newState = (Get-WebAppPoolState -Name $PoolName).Value
        if ($newState -eq 'Started') {
            Write-Log "Pool '$PoolName' successfully restarted. State: $newState"
        } else {
            Write-Log "Pool '$PoolName' restart attempted but state is now '$newState'." -Level WARN
        }

    } catch {
        Write-Log "Error restarting pool '$PoolName': $_" -Level ERROR
    }
}

# ---------------------------------------------------------------------------
# One monitoring cycle
# ---------------------------------------------------------------------------
function Invoke-MonitorCycle {
    Write-Log "--- Monitor cycle starting ---"

    try {
        $pools = Get-WebConfiguration 'system.applicationHost/applicationPools/add'
    } catch {
        Write-Log "Failed to enumerate application pools: $_" -Level ERROR
        return
    }

    if (-not $pools) {
        Write-Log "No application pools found." -Level WARN
        return
    }

    foreach ($pool in $pools) {
        $poolName = $pool.name
        try {
            $state = (Get-WebAppPoolState -Name $poolName).Value
            Write-Log "Pool '$poolName': $state"

            if ($state -eq 'Stopped') {
                Write-Log "Pool '$poolName' is STOPPED. Initiating recovery..." -Level WARN
                Restart-StoppedPool -PoolName $poolName
            }
        } catch {
            Write-Log "Error checking pool '$poolName': $_" -Level ERROR
        }
    }

    Write-Log "--- Monitor cycle complete ---"
}

# ---------------------------------------------------------------------------
# Clean exit on Ctrl+C / PowerShell.Exiting
# ---------------------------------------------------------------------------
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    # This block runs in a separate runspace; use the log file directly.
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [INFO] PowerShell.Exiting event received. IIS monitor shutting down."
    try { Add-Content -Path 'C:\Logs\iis-monitor.log' -Value $line -Encoding UTF8 } catch {}
    Write-Host $line -ForegroundColor Cyan
} | Out-Null

# Trap Ctrl+C interactively so we can log and optionally roll back
$null = [Console]::TreatControlCAsInput = $false
try {
    [Console]::CancelKeyPress  # reference to confirm the event exists
} catch {}

# ---------------------------------------------------------------------------
# MAIN ENTRY POINT
# ---------------------------------------------------------------------------
Initialize-LogDirectory

Write-Log "======================================================"
Write-Log "IIS Application Pool Monitor STARTING"
Write-Log "DryRun        : $DryRun"
Write-Log "Poll Interval : $PollIntervalSeconds seconds"
Write-Log "Log File      : $LogFile"
Write-Log "======================================================"

# Verify WebAdministration module is loaded
try {
    Import-Module WebAdministration -ErrorAction Stop
    Write-Log "WebAdministration module loaded."
} catch {
    Write-Log "Cannot load WebAdministration module: $_" -Level ERROR
    exit 1
}

# Snapshot states for potential rollback
Save-PoolStates

Write-Log "Monitoring started. Press Ctrl+C to stop."

try {
    while ($script:MonitoringActive) {
        Invoke-MonitorCycle

        # Sleep in 1-second increments so Ctrl+C is responsive
        $elapsed = 0
        while ($elapsed -lt $PollIntervalSeconds -and $script:MonitoringActive) {
            Start-Sleep -Seconds 1
            $elapsed++
        }
    }
} catch {
    Write-Log "Unhandled error in monitor loop: $_" -Level ERROR
} finally {
    Write-Log "Monitor loop exited. Running rollback..."
    Invoke-Rollback
    Write-Log "IIS Application Pool Monitor STOPPED."
}
