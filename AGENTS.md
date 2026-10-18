# AGENTS.md

VpsFree (credit KallAncrit; template `xykal/XyRDP`): an **Ubuntu Server VPS** on a GitHub Actions runner, reachable over a **private Tailscale** tailnet via **SSH**. No RDP, no web dashboard, no public relay (Pinggy/bore/ngrok/Serveo/Funnel) on the active path.

## Layout (not obvious from filenames)
- `.github/workflows/vps-6h.yml` + `scripts/*.sh` — the **active** session: bash scripts on Ubuntu, copied into user repos from the template.
- No root `package.json`/workspace, no web app, no side tools. Don't recreate `web/`, `web-next/`, `deploy/`, `integrasi-xydesk/`, or `relay-panel/` — they were deleted on purpose.

## Runner conventions
- Scripts are **bash** run as the unprivileged `runner` user; use `sudo` for system changes (`chpasswd`, `sshd_config.d`, `tailscale`, `ufw`, writing `/var/lib/tailscale`, `/etc/ssh`). All scripts are invoked as `bash scripts/x.sh` (no exec bit needed).
- Secrets are `VPS_PASSWORD` (root + sudo user password) and `TAILSCALE_AUTH_KEY`, plus optional `CLEANUP_TOKEN` (PAT for `cleanup-actions.sh`; falls back to `GITHUB_TOKEN`). Root login + password auth are enabled; SSH is reachable only via the tailnet (ufw allows `tailscale0` / `100.64.0.0/10:22`).
- Status JSON is `out/vps-status.json`, published to branch `status` as `vps-status.json`. **Never write passwords/secrets into it.**
- State persists across ephemeral runners via GitHub Release `vpsfree-state-latest` (asset `vps-state.tar.gz`) + artifact `vpsfree-state`: home dir, `/etc/ssh/sshd_config.d`, `/var/lib/tailscale` (keeps the same Tailscale IP).
- `keepalive.sh` owns: deadline auto-stop (expires_at − 3 min), 15-min checkpoints, and the **pre-expiry renewal handover** (dispatch the next `vps-6h.yml` run ~20 min early). Renewal must never delete state.

## Validation / commands
- Bash syntax + ShellCheck: `for f in scripts/*.sh; do bash -n "$f"; done`, `shellcheck --severity=error scripts/*.sh`; CI runs this via `.github/workflows/validate-vps.yml` (on push for `scripts/**`). Don't recreate PowerShell `validate-*.yml` — they were removed with the RDP flow.
- `actionlint` (if available) validates `vps-6h.yml` expressions/actions cleanly; keep it that way.

## Things easy to get wrong
- **Workflow contract is schema 6**: `vps-6h.yml` line 1 is `# vpsfree-workflow-schema: 6` and the filename is `vps-6h.yml`. Keep the marker, the input names, and the filenames used in scripts (e.g. `persist-state.sh` uploads `vps-state.tar.gz`) in sync.
- Any change to workflow inputs must also update the dispatch payloads in `scripts/keepalive.sh` and the fallback step inside `vps-6h.yml`, or the handover will fail silently.
- `jq`, `curl`, `tar`, `gzip` are assumed available (Ubuntu runners have them; `setup-vps.sh` installs `jq`/`curl`/`ufw` if missing). Scripts run without `set -e`, so check exit codes instead of assuming failures abort.
- `.gitignore` ignores `*.env` and `out/` (state archive lives in `out/`).
