$ErrorActionPreference = "Stop"

# This script lives at <repo>/scripts/launcher/start-ui.ps1, so the repo
# root is two directories up. Computing it from $MyInvocation keeps the
# launcher working regardless of the user's current working directory or
# how the .bat / .lnk wrapper was invoked.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $ScriptDir)
Set-Location $RepoRoot

# Set the window title to a friendly name. start-ui.bat already issued
# `title IESA-Opt.jl`, but we re-set it here so the script works when run
# directly from a PowerShell prompt, and we re-set it once more after
# spawning Julia below because juliaup's launcher calls SetConsoleTitleW
# and would otherwise overwrite our title to "Julia".
$WindowTitle = "IESA-Opt.jl"
try { $Host.UI.RawUI.WindowTitle = $WindowTitle } catch {}

# Must match `serve_ui!()` defaults in src/ui_server.jl.
$UiHost = "127.0.0.1"
$UiPort = 8123
$Url    = "http://${UiHost}:${UiPort}/"

$Julia = Get-Command julia -ErrorAction SilentlyContinue
if ($null -eq $Julia) {
    Write-Host "Julia was not found on PATH." -ForegroundColor Red
    Write-Host "Install Julia 1.10 or newer, then run this launcher again."
    Read-Host "Press Enter to close"
    exit 1
}

# Materialise a Windows shortcut at the repo root so users get a single
# clickable entry point with a custom icon -- Explorer / Start menu /
# pinned taskbar all honour the IconLocation on a .lnk, whereas .bat
# files always show the default cmd.exe icon. The .bat + .ps1 launchers
# themselves live under scripts/launcher/ to keep the repo root tidy.
# We (re)create the shortcut on every launch because .lnk files store
# absolute paths; that way the icon stays correct if the repo is moved
# or synced to a different location through OneDrive. The operation is
# cheap (~50 ms).
function Update-LauncherShortcut {
    param(
        [string]$RepoRoot,
        [string]$ShortcutPath = (Join-Path $RepoRoot 'IESA-Opt UI.lnk')
    )

    $target = Join-Path $RepoRoot 'scripts\launcher\start-ui.bat'
    $icon   = Join-Path $RepoRoot 'ui\assets\iesa-opt-ui.ico'

    if (-not (Test-Path $target)) { return }   # nothing to point at
    if (-not (Test-Path $icon))   { return }   # icon missing; leave default

    try {
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($ShortcutPath)
        $sc.TargetPath       = $target
        $sc.WorkingDirectory = $RepoRoot
        $sc.IconLocation     = "$icon,0"
        $sc.Description      = 'Launch the IESA-Opt local browser UI'
        # WindowStyle: 1 = normal, 3 = maximized, 7 = minimized.
        $sc.WindowStyle      = 1
        $sc.Save()
    } catch {
        Write-Host ("Could not refresh launcher shortcut '{0}': {1}" -f $ShortcutPath, $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

function Reset-UiPort {
    param(
        [string]$HostName,
        [int]$Port
    )

    $listeners = @(Get-NetTCPConnection -LocalAddress $HostName -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -eq 0) { return }

    foreach ($listener in $listeners) {
        $owner = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        if ($null -eq $owner) { continue }

        if ($owner.ProcessName -notin @('julia', 'juliaup')) {
            Write-Host ""
            Write-Host ("Port {0} is already in use by PID {1} ({2})." -f $Port, $owner.Id, $owner.ProcessName) -ForegroundColor Red
            Write-Host "Stop that process or start IESA-Opt on a different port." -ForegroundColor Yellow
            Read-Host "Press Enter to close"
            exit 1
        }

        Write-Host ("Port {0} is already owned by Julia PID {1}; restarting it so the UI uses the current repo source." -f $Port, $owner.Id) -ForegroundColor Yellow
        Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue
    }

    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-NetTCPConnection -LocalAddress $HostName -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) { return }
    }

    Write-Host ""
    Write-Host ("Port {0} is still busy after stopping the old Julia UI process." -f $Port) -ForegroundColor Red
    Write-Host "Close the old IESA-Opt terminal window and launch again." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit 1
}

Update-LauncherShortcut -RepoRoot $RepoRoot
Reset-UiPort -HostName $UiHost -Port $UiPort

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " IESA-Opt local UI" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host " URL    : $Url"
Write-Host " Repo   : $RepoRoot"
Write-Host " Julia  : $($Julia.Source)"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Opening the UI in your browser. Julia is starting in the" -ForegroundColor Yellow
Write-Host "background -- the page will refresh automatically as soon as" -ForegroundColor Yellow
Write-Host "the server is ready (typically ~20 s, longer after a Julia" -ForegroundColor Yellow
Write-Host "upgrade). Keep this window open while using the UI, and press" -ForegroundColor Yellow
Write-Host "Ctrl+C here to stop the server." -ForegroundColor Yellow
Write-Host ""

# Open a lightweight static "loading" page from disk *before* Julia binds
# port 8123. The page polls /api/status and redirects to the live UI as
# soon as the server is reachable. This makes the user-visible delay feel
# instantaneous instead of staring at a closed terminal for ~10 s. If the
# file:// open fails for any reason we fall back below to opening the live
# URL once the TCP port is up.
$LoadingPath = Join-Path $RepoRoot 'ui\loading.html'
$LoadingUri  = $null
if (Test-Path $LoadingPath) {
    try {
        # System.Uri handles spaces, percent-encoding, and the file:// scheme
        # correctly for paths like "C:\OneDrive - TNO\...\loading.html".
        $LoadingUri = ([System.Uri]$LoadingPath).AbsoluteUri
        Start-Process $LoadingUri | Out-Null
        Write-Host "Opened launcher page: $LoadingUri" -ForegroundColor DarkGray
    } catch {
        Write-Host "Could not open the loading page automatically: $($_.Exception.Message)" -ForegroundColor DarkYellow
        $LoadingUri = $null
    }
}

# `IESA_OPT_OPEN_BROWSER=0` tells `serve_ui!()` to skip its own
# `@async sleep(1.0); _open_browser(url)` so we do not race and end up with
# two browser tabs (one for loading.html, one direct).
$env:IESA_OPT_OPEN_BROWSER = "0"

$julia_args = @(
    '--threads=auto',
    # `Start-Process -ArgumentList` on Windows PowerShell 5.1 does NOT add
    # quotes around array entries — it just space-joins them. The repo path
    # often contains spaces ("OneDrive - TNO", "My Documents", ...), so we
    # must embed literal quotes around `--project=...` ourselves; otherwise
    # Julia sees argv split on the space and treats `-` as "read script from
    # stdin", which leaves the process hung with no log output.
    ('--project="{0}"' -f $RepoRoot),
    'scripts/serve_ui.jl'
)

# `Start-Process -NoNewWindow -PassThru` attaches Julia's stdout/stderr to
# the current console (so the user still sees @info / @warn output) and lets
# us poll the port from this script while Julia is still loading. Ctrl+C in
# this window is delivered to the Julia child via the shared console.
$proc = Start-Process -FilePath $Julia.Source -ArgumentList $julia_args -NoNewWindow -PassThru

# juliaup's launcher writes "Julia" to the console title via
# SetConsoleTitleW shortly after we spawn it. Re-set our friendly title
# every poll iteration -- it's cheap and guarantees the window stays named
# "IESA-Opt.jl" regardless of when Julia finishes overwriting it.
try { $Host.UI.RawUI.WindowTitle = $WindowTitle } catch {}

$portReady    = $false
$elapsed      = 0
$progressTick = 5

try {
    while (-not $proc.HasExited) {
        try { $Host.UI.RawUI.WindowTitle = $WindowTitle } catch {}
        if (-not $portReady) {
            $client = $null
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $client.Connect($UiHost, $UiPort)
                $client.Close()
                $portReady = $true
                Write-Host ""
                Write-Host "Server is ready at $Url" -ForegroundColor Green
                # loading.html will detect this on its next poll (~500 ms)
                # and redirect itself. We only open the live URL here as a
                # fallback when the static loading page could not be opened
                # earlier (e.g. file:// disabled by browser policy).
                if (-not $LoadingUri) {
                    try {
                        Start-Process $Url | Out-Null
                    } catch {
                        Write-Host "Could not open the default browser automatically. Open $Url manually." -ForegroundColor Yellow
                    }
                }
            } catch {
                # Port not listening yet; try again after the sleep below.
                if ($client) { try { $client.Close() } catch {} }
            }
        }
        Start-Sleep -Seconds 1
        $elapsed++
        if (-not $portReady -and ($elapsed % $progressTick) -eq 0) {
            Write-Host ("  ...still starting Julia ({0}s elapsed) -- this is normal on the first run" -f $elapsed) -ForegroundColor DarkGray
        }
    }
} finally {
    if (-not $proc.HasExited) {
        try { $proc.WaitForExit() } catch {}
    }
}

$exitCode = $proc.ExitCode
if ($null -eq $exitCode) { $exitCode = 0 }

if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "Julia exited with code $exitCode. See the messages above for the cause." -ForegroundColor Red
    Read-Host "Press Enter to close"
    # Exit 0 so start-ui.bat does not pause a second time.
    exit 0
}

Write-Host ""
Write-Host "UI server stopped." -ForegroundColor Cyan
