# bin/

`cloudflared.exe` deliberately is **not tracked by git**.

- Version used by this deployment: **2026.11.0** (built 2026-11-12)
- SHA-256: `d5c1d82031da6253dcdcff64c944cd0fe063016edeb2e4fd088075fc9bd52d0a`

Place the official Windows amd64 binary here, or copy that exact binary from another local project. Verify in PowerShell:

```powershell
Get-FileHash .\bin\cloudflared.exe -Algorithm SHA256
.\bin\cloudflared.exe --version
```

`control.ps1 start` reports a degraded state if the binary is missing. `run.ps1` treats this as a soft failure: it can keep the authenticating proxy alive for local diagnosis, but the public Tunnel cannot become ready. A fresh clone must restore this binary before it can serve public traffic.
