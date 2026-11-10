#requires -Version 5.1
#
# cdp-relay.ps1 - TCP relay for the Chrome DevTools Protocol (runs on the Windows host)
#
#   Chrome started with --remote-debugging-port listens only on 127.0.0.1, which
#   a NAT-ed WSL2 cannot reach. This relay listens on the host's address on the
#   WSL network (<ListenAddress>, the WSL default gateway) and forwards each
#   connection to 127.0.0.1:<Port>. It does not listen on the LAN side.
#
#   Started and stopped by chrome-cdp.sh in the same directory (stop = the
#   process is killed). chrome-cdp.sh copies this file to
#   %USERPROFILE%\.cache\chrome-cdp and runs that copy.
#
#   Keep this file ASCII-only: PowerShell 5.1 reads a BOM-less file as ANSI.
#
param(
    [Parameter(Mandatory = $true)][string]$ListenAddress,
    [int]$Port = 9222
)

$ErrorActionPreference = 'Stop'
# The log is read from WSL; without this, errors are written in the ANSI code page (CP932)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($ListenAddress), $Port)
$listener.Start()
Write-Host "[cdp-relay] listening on ${ListenAddress}:${Port} -> 127.0.0.1:${Port}"

# Bidirectional copy for one connection (runs in its own runspace)
$handler = {
    param($client, $Port)
    $remote = $null
    try {
        $remote = [System.Net.Sockets.TcpClient]::new()
        $remote.Connect('127.0.0.1', $Port)
        # CDP exchanges many small WebSocket frames; avoid Nagle/delayed-ACK stalls
        $client.NoDelay = $true
        $remote.NoDelay = $true
        $cs = $client.GetStream()
        $rs = $remote.GetStream()
        $a = $cs.CopyToAsync($rs)
        $b = $rs.CopyToAsync($cs)
        [System.Threading.Tasks.Task]::WaitAny(@($a, $b)) | Out-Null
    } catch {
    } finally {
        if ($remote) { $remote.Close() }
        if ($client) { $client.Close() }
    }
}

$jobs = New-Object System.Collections.ArrayList
try {
    while ($true) {
        try {
            $client = $listener.AcceptTcpClient()
            $ps = [PowerShell]::Create()
            [void]$ps.AddScript($handler).AddArgument($client).AddArgument($Port)
            [void]$jobs.Add([pscustomobject]@{ ps = $ps; async = $ps.BeginInvoke() })
        } catch {
            Start-Sleep -Milliseconds 200
        }

        # Reap runspaces of finished connections
        for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
            if ($jobs[$i].async.IsCompleted) {
                try { $jobs[$i].ps.EndInvoke($jobs[$i].async) } catch {}
                $jobs[$i].ps.Dispose()
                $jobs.RemoveAt($i)
            }
        }
    }
} finally {
    $listener.Stop()
}
