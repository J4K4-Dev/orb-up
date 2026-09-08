[CmdletBinding()]
param(
	[Parameter(Position = 0)]
	[string]$Command,

	[Parameter(Position = 1, ValueFromRemainingArguments = $true)]
	[string[]]$CommandArguments
)

$ErrorActionPreference = 'Stop'

$Session = if ($env:ORB_UP_SESSION) { $env:ORB_UP_SESSION } else { 'amp-runner' }
$StateDirectory = if ($env:ORB_UP_STATE_DIR) {
	$env:ORB_UP_STATE_DIR
} else {
	Join-Path $env:LOCALAPPDATA 'orb-up'
}
$SafeSession = $Session -replace '[^A-Za-z0-9_.-]', '_'
$RunnerStateFile = Join-Path $StateDirectory "$SafeSession.state"
$RunnerMetadataFile = Join-Path $StateDirectory "$SafeSession.runner.json"
$RestartPendingFile = Join-Path $StateDirectory "$SafeSession.restart-pending"
$UpdateLockFile = Join-Path $StateDirectory "$SafeSession.update-lock"
$UpdateLogFile = Join-Path $StateDirectory 'update.log'
$TaskName = "orb-up-$SafeSession-update"
$UpdateLock = $null

function Show-Usage {
	@'
Usage: orb-up.ps1 <command>

Commands:
  start [directory] [amp options]  Start an Amp runner in the background
  stop                             Stop the runner
  restart                          Restart the runner
  status                           Show whether the runner is running
  logs [lines]                     Show recent runner output (default: 200)
  update                           Update Amp and restart if it changed
  enable-updates                   Install the hourly scheduled update task
  disable-updates                  Remove the scheduled update task

Environment:
  ORB_UP_SESSION       runner name (default: amp-runner)
  ORB_UP_RUNNER_ID     stable Amp runner ID (default: computer name)
  ORB_UP_STATE_DIR     runtime state directory
  AMP_BIN              path to the Amp executable
'@
}

function Find-Amp {
	if ($env:AMP_BIN -and (Test-Path -LiteralPath $env:AMP_BIN -PathType Leaf)) {
		return (Resolve-Path -LiteralPath $env:AMP_BIN).Path
	}

	$command = Get-Command amp -ErrorAction SilentlyContinue
	if ($command) {
		return $command.Source
	}

	$installedAmp = Join-Path $(if ($env:AMP_HOME) { $env:AMP_HOME } else { Join-Path $HOME '.amp' }) 'bin\amp.exe'
	if (Test-Path -LiteralPath $installedAmp -PathType Leaf) {
		return $installedAmp
	}

	throw 'Amp is not installed; run: irm https://ampcode.com/install.ps1 | iex'
}

function Get-PowerShellExecutable {
	$processPath = (Get-Process -Id $PID).Path
	if ($processPath) { return $processPath }
	return 'powershell.exe'
}

function Test-RunnerProcess($Metadata) {
	if (-not $Metadata -or -not $Metadata.ProcessId -or -not $Metadata.ProcessStartTimeUtc) {
		return $false
	}

	$process = Get-Process -Id $Metadata.ProcessId -ErrorAction SilentlyContinue
	if (-not $process) { return $false }

	try {
		$recordedStartTime = ([datetime]$Metadata.ProcessStartTimeUtc).ToUniversalTime()
		return $process.StartTime.ToUniversalTime().Ticks -eq $recordedStartTime.Ticks
	} catch {
		return $false
	}
}

function Get-RunnerMetadata {
	if (-not (Test-Path -LiteralPath $RunnerMetadataFile -PathType Leaf)) { return $null }
	try {
		return Get-Content -LiteralPath $RunnerMetadataFile -Raw | ConvertFrom-Json
	} catch {
		return $null
	}
}

function Get-RunnerActivity {
	$metadata = Get-RunnerMetadata
	if (-not (Test-RunnerProcess $metadata)) { return 'stopped' }
	if (-not (Test-Path -LiteralPath $RunnerStateFile -PathType Leaf)) { return 'unknown' }

	$stateParts = (Get-Content -LiteralPath $RunnerStateFile -Raw).Trim() -split '\s+'
	if ($stateParts.Count -ne 2 -or $stateParts[0] -notin @('idle', 'busy')) { return 'unknown' }

	$pluginProcess = Get-Process -Id $stateParts[1] -ErrorAction SilentlyContinue
	if (-not $pluginProcess) { return 'unknown' }
	return $stateParts[0]
}

function Start-RunnerProcess($Metadata) {
	New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
	$Metadata.ProcessId = $null
	$Metadata.ProcessStartTimeUtc = $null
	$launchMetadataFile = Join-Path $StateDirectory "$SafeSession.launch-$([guid]::NewGuid().ToString('N')).json"
	$Metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $launchMetadataFile -Encoding UTF8

	# Windows paths cannot contain a double quote, so explicit quoting is sufficient here.
	$nativeArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" __run "{1}"' -f $PSCommandPath, $launchMetadataFile
	try {
		$process = Start-Process -FilePath (Get-PowerShellExecutable) `
			-ArgumentList $nativeArguments -WindowStyle Hidden -PassThru
		$Metadata.ProcessId = $process.Id
		$Metadata.ProcessStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
		$Metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $RunnerMetadataFile -Encoding UTF8
	} catch {
		Remove-Item -LiteralPath $launchMetadataFile -Force -ErrorAction SilentlyContinue
		throw
	}
}

function Start-Runner([string[]]$Arguments) {
	$existing = Get-RunnerMetadata
	if (Test-RunnerProcess $existing) {
		throw "runner '$Session' is already running; use 'orb-up.ps1 status' or 'orb-up.ps1 restart'"
	}

	$directory = (Get-Location).Path
	if ($Arguments.Count -gt 0 -and -not $Arguments[0].StartsWith('-')) {
		$directory = $Arguments[0]
		$Arguments = @($Arguments | Select-Object -Skip 1)
	}
	if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
		throw "directory does not exist: $directory"
	}
	$directory = (Resolve-Path -LiteralPath $directory).Path

	$hasRunnerId = $Arguments | Where-Object { $_ -and ($_ -eq '--runner-id' -or $_.StartsWith('--runner-id=')) }
	if (-not $hasRunnerId) {
		$runnerId = if ($env:ORB_UP_RUNNER_ID) { $env:ORB_UP_RUNNER_ID } else { $env:COMPUTERNAME }
		$Arguments = @('--runner-id', $runnerId) + $Arguments
	}

	Remove-Item -LiteralPath $RunnerStateFile, $RestartPendingFile -Force -ErrorAction SilentlyContinue
	$metadata = [pscustomobject]@{
		AmpBin = Find-Amp
		Directory = $directory
		Arguments = @($Arguments)
		LogFile = Join-Path $StateDirectory "$SafeSession.runner.log"
		StateFile = $RunnerStateFile
		ProcessId = $null
		ProcessStartTimeUtc = $null
	}
	Start-RunnerProcess $metadata
	Write-Output "Started Amp runner '$Session' in the background (directory: $directory)."
	Write-Output 'Use "orb-up.ps1 logs" to inspect it.'
}

function Stop-RunnerProcess($Metadata) {
	if (-not (Test-RunnerProcess $Metadata)) { return }
	& taskkill.exe /PID $Metadata.ProcessId /T /F *> $null
	if ($LASTEXITCODE -ne 0 -and (Get-Process -Id $Metadata.ProcessId -ErrorAction SilentlyContinue)) {
		throw "could not stop runner process $($Metadata.ProcessId)"
	}
}

function Stop-Runner {
	$metadata = Get-RunnerMetadata
	if (Test-RunnerProcess $metadata) {
		Stop-RunnerProcess $metadata
		Write-Output 'Stopped runner.'
	} else {
		Write-Output 'Runner is not started.'
	}
	Remove-Item -LiteralPath $RunnerMetadataFile, $RunnerStateFile, $RestartPendingFile -Force -ErrorAction SilentlyContinue
}

function Restart-Runner([switch]$StartStopped) {
	$metadata = Get-RunnerMetadata
	if (-not (Test-RunnerProcess $metadata)) {
		if ($StartStopped -and $metadata) {
			Remove-Item -LiteralPath $RunnerStateFile -Force -ErrorAction SilentlyContinue
			Start-RunnerProcess $metadata
			Remove-Item -LiteralPath $RestartPendingFile -Force -ErrorAction SilentlyContinue
			Write-Output "Restarted runner '$Session'."
			return
		}
		Remove-Item -LiteralPath $RestartPendingFile -Force -ErrorAction SilentlyContinue
		Write-Output 'Runner is not started; the update will be used next time it starts.'
		return
	}

	Stop-RunnerProcess $metadata
	Remove-Item -LiteralPath $RunnerStateFile -Force -ErrorAction SilentlyContinue
	Start-RunnerProcess $metadata
	Remove-Item -LiteralPath $RestartPendingFile -Force -ErrorAction SilentlyContinue
	Write-Output "Restarted runner '$Session'."
}

function Show-Status {
	$metadata = Get-RunnerMetadata
	if (-not (Test-RunnerProcess $metadata)) {
		Write-Output 'stopped'
		exit 1
	}
	Write-Output "running, $(Get-RunnerActivity) (runner: $Session, process: $($metadata.ProcessId), directory: $($metadata.Directory))"
}

function Show-Logs([string[]]$Arguments) {
	$metadata = Get-RunnerMetadata
	if (-not $metadata -or -not (Test-Path -LiteralPath $metadata.LogFile -PathType Leaf)) {
		throw 'no runner log is available'
	}
	$lines = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '200' }
	$parsedLines = 0
	if (-not [int]::TryParse($lines, [ref]$parsedLines) -or $parsedLines -lt 1) {
		throw 'line count must be a positive integer'
	}
	Get-Content -LiteralPath $metadata.LogFile -Tail $parsedLines
}

function Enter-UpdateLock {
	New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
	try {
		$script:UpdateLock = [System.IO.File]::Open(
			$UpdateLockFile,
			[System.IO.FileMode]::OpenOrCreate,
			[System.IO.FileAccess]::ReadWrite,
			[System.IO.FileShare]::None
		)
		return $true
	} catch [System.IO.IOException] {
		return $false
	}
}

function Update-Amp {
	if (-not (Enter-UpdateLock)) {
		Write-Output 'Another update check is already running; skipping.'
		return
	}

	try {
		$activity = Get-RunnerActivity
		if ($activity -in @('busy', 'unknown')) {
			if (Test-Path -LiteralPath $RestartPendingFile) {
				Write-Output "Runner is $activity; restart deferred until the next idle update check."
			} else {
				Write-Output "Runner is $activity; update deferred until the next check."
			}
			return
		}

		$output = & (Find-Amp) update --porcelain 2>&1
		if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
		$output | Write-Output
		if ($output | Where-Object { $_ -match '^updated ' }) {
			New-Item -ItemType File -Path $RestartPendingFile -Force | Out-Null
		}

		if (Test-Path -LiteralPath $RestartPendingFile) {
			$activity = Get-RunnerActivity
			if ($activity -in @('busy', 'unknown')) {
				Write-Output "Runner became $activity; restart deferred until the next idle update check."
				return
			}
			Restart-Runner
		}
	} finally {
		if ($script:UpdateLock) {
			$script:UpdateLock.Dispose()
			$script:UpdateLock = $null
		}
	}
}

function ConvertTo-PowerShellLiteral([string]$Value) {
	return "'" + $Value.Replace("'", "''") + "'"
}

function Enable-Updates {
	$ampBin = Find-Amp
	$executable = Get-PowerShellExecutable
	$commandText = @(
		"`$env:AMP_BIN=$(ConvertTo-PowerShellLiteral $ampBin)",
		"`$env:ORB_UP_SESSION=$(ConvertTo-PowerShellLiteral $Session)",
		"`$env:ORB_UP_STATE_DIR=$(ConvertTo-PowerShellLiteral $StateDirectory)",
		"& $(ConvertTo-PowerShellLiteral $PSCommandPath) update *>> $(ConvertTo-PowerShellLiteral $UpdateLogFile)"
	) -join '; '
	$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandText))
	$action = New-ScheduledTaskAction -Execute $executable -Argument "-WindowStyle Hidden -NoProfile -NonInteractive -EncodedCommand $encodedCommand"
	$firstRun = (Get-Date).Date.AddMinutes(17)
	if ($firstRun -le (Get-Date)) { $firstRun = $firstRun.AddHours(1) }
	$trigger = New-ScheduledTaskTrigger -Once -At $firstRun -RepetitionInterval (New-TimeSpan -Hours 1)
	$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
	Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
	Write-Output 'Installed automatic update task: hourly at 17 minutes past the hour.'
	Write-Output "Update log: $UpdateLogFile"
}

function Disable-Updates {
	if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
		Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
	}
	Write-Output 'Removed automatic update task.'
}

function Invoke-RunnerHost([string]$MetadataPath) {
	try {
		$metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
	} finally {
		Remove-Item -LiteralPath $MetadataPath -Force -ErrorAction SilentlyContinue
	}
	$env:ORB_UP_RUNNER_STATE_FILE = $metadata.StateFile
	Set-Location -LiteralPath $metadata.Directory
	& $metadata.AmpBin --no-tui @($metadata.Arguments) *>> $metadata.LogFile
	exit $LASTEXITCODE
}

try {
	switch ($Command) {
		'start' { Start-Runner $CommandArguments }
		'stop' { Stop-Runner }
		'restart' {
			if (-not (Get-RunnerMetadata)) { throw 'runner has not been started before' }
			Restart-Runner -StartStopped
		}
		'status' { Show-Status }
		'logs' { Show-Logs $CommandArguments }
		'update' { Update-Amp }
		'enable-updates' { Enable-Updates }
		'disable-updates' { Disable-Updates }
		'__run' { Invoke-RunnerHost $CommandArguments[0] }
		{ $_ -in @('-h', '--help', 'help') } { Show-Usage }
		default {
			Show-Usage
			if ($Command) { throw "unknown command: $Command" }
			exit 1
		}
	}
} catch {
	Write-Error "orb-up: $($_.Exception.Message)"
	exit 1
}
