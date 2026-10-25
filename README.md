# xhcoding.ai-services

Omarchy bar widget that exclusively manages three GPU AI services (ComfyUI, a
local LLM, and a Strata service): starting one stops the others. It also
carries GPU power-cap and CPU package limit (PL1/PL2) switchers.

## How it works

- `Panel.qml` — the bar widget (icon + popup).
- `ai-services.sh` — polled by the panel. Reports each service's state from the
  systemd user units (`comfyui.service`, `local-llm.service`,
  `strata_iq3_s.service`), the tailnet address, and the current power limits.
- Changing caps runs through privileged helpers
  (`/usr/local/bin/omarchy-gpu-power`, `/usr/local/bin/omarchy-cpu-power`) via
  `pkexec`, which shows the normal polkit password dialog.

## Requirements

- systemd user units that start the three services (see `IDS` / `unit_of` in
  `ai-services.sh`)
- `tailscale` for the tailnet line (optional; shows "down" without it)
- `nvidia-smi` for GPU power caps, Intel RAPL for CPU package limits
- the helper binaries above if you want to *change* caps (reading needs nothing)

## Install

```bash
omarchy plugin add https://github.com/xhcoding/xhcoding.ai-services
```

## License

MIT — see [LICENSE](LICENSE).
