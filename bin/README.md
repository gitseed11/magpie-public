# bin/

`cloudflared.exe` is deliberately **not tracked by git** (third-party binary, ~55 MB).

- Version used by this deployment: **2026.11.0** (built 2026-11-12)
- SHA-256: `d5c1d82031da6253dcdcff64c944cd0fe063016edeb2e4fd088075fc9bd52d0a`

Get it either way:

- download `cloudflared-windows-amd64.exe` from the official Cloudflare releases page and rename, or
- copy `cloudflared.exe` from another local project that already ships the same version.

Verify after placing it:

```bash
sha256sum bin/cloudflared.exe
```

`run.ps1` logs `cloudflared.exe missing; tunnel not started` and keeps the proxy running
if the file is absent, so a fresh clone fails soft rather than crashing.
