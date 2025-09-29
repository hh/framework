# Repository Guidelines

## Project Structure & Module Organization
- `Containerfile` chooses the base image (`ghcr.io/ublue-os/bluefin-dx:latest`) and runs `build_files/build.sh`; keep package installs and systemd tweaks inside that script.
- Store helper scripts and assets under `build_files/`; drop filesystem overlays in `src/` while mirroring their runtime paths.
- `disk_config/*.toml` feed bootc-image-builder; tweak image name/tag plus profile toggles when you change variants. `iso_files/` and `flatpaks.example.txt` seed live-media content.
- `Justfile` handles day-to-day recipes, while `titanoboa.just` powers advanced ISO flows. Wipe `output/` whenever you want a clean rebuild.

## Build, Test, and Development Commands
- `just build [image] [tag]` builds the bootc container with Podman; run it after any workflow or script change.
- `just build-iso`, `just build-qcow2`, and `just build-raw` wrap bootc-image-builder using `disk_config/*.toml` profiles.
- `just run-vm-qcow2` or `just run-vm-iso` boots artifacts via `qemux/qemu` and exposes a web console for smoke testing.
- `just check`, `just fix`, `just lint`, and `just format` guard Just syntax and Bash style; run them before every PR.

## Coding Style & Naming Conventions
- Shell scripts must target Bash, start with `#!/usr/bin/env bash`, and enable `set -euo pipefail` (see `build_files/build.sh`).
- Indent continuation lines by two spaces, align package lists under the calling command, and keep comments directive.
- Name Just recipes and systemd units after their intent (`build-qcow2`, `doom-firstboot.service`); use snake_case for variables.

## Testing Guidelines
- Validate each change by running `just build` plus the relevant artifact recipe, then boot with `just run-vm-qcow2` to confirm services and first-boot hooks.
- Capture supporting logs (`journalctl -u doom-firstboot.service`, `podman logs`) when touching boot sequences or background services.
- Note manual QA steps and `just` commands in your PR description.

## Commit & Pull Request Guidelines
- Follow the Conventional Commit style already in history (`chore: add flatpaks`, `feat: ...`); scope names like `iso` or `polkit` when helpful.
- Squash WIP commits so each commit keeps the image buildable.
- PRs need a concise summary, linked issues, and the validation steps you ran; include screenshots or logs for desktop or ISO changes.

## Security & Secrets
- Never commit `cosign.key`; store it as the `SIGNING_SECRET` action secret and check in only `cosign.pub`.
- Keep S3 credentials and similar secrets in GitHub Actions; avoid embedding secrets in Just recipes or workflow files.
