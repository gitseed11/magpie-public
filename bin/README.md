# bin/

`cloudflared.exe` deliberately is **not tracked by git**.

- Version used by this deployment: **2026.11.0** (built 2026-11-12)
- SHA-256: `d5c1d82031da6253dcdcff64c944cd0fe063016edeb2e4fd088075fc9bd52d0a`

Place the official Windows amd64 binary here, or copy that exact binary from another local project. Verify in PowerShell:

```powershell
Get-FileHash .\bin\cloudflared.exe -Algorithm SHA256
.\bin\cloudflared.exe --version
```

`control.ps1 start` reports a degraded state if the binary is missing. `run.ps1` also recomputes the SHA-256 before every Tunnel launch and refuses to start cloudflared if it differs from the value above; this check must pass before the Tunnel can become ready. After an official upgrade, replace the binary and update the recorded version/hash together.

`run.ps1` treats a missing or mismatched binary as a soft failure: it can keep the authenticating proxy alive for local diagnosis, but the public Tunnel cannot become ready. A fresh clone must restore this binary before it can serve public traffic. The recorded hash detects accidental drift and enforces the reviewed artifact, but because it is stored beside the binary it is not an independent signature or a defense against an attacker who can modify both files. Verify official release provenance when provisioning or upgrading.
