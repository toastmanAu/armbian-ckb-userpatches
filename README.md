# armbian-ckb-userpatches

Armbian userpatches that turn any supported SBC into a CKB blockchain node,
solo miner, Fiber payment channel node, or full desktop wallet machine.

Built by [Wyltek Industries](https://wyltekindustries.com).

## Setup

```bash
git clone https://github.com/armbian/build.git
cd build
git clone https://github.com/toastmanAu/armbian-ckb-userpatches.git userpatches
```

That's it. The next `compile.sh` run picks up the userpatches automatically.

## Profiles

Set `CKB_PROFILE` at build time:

| Profile | Description | DE |
|---|---|---|
| `ckb-node` | CKB full node + dashboard + stratum proxy | Headless |
| `solo-miner` | CKB full node + solo stratum (point miner at port 3333) | Headless |
| `fiber-kiosk` | CKB + Fiber network node + XFCE desktop launchers | XFCE |
| `neuron-desktop` | CKB + Neuron wallet + XFCE desktop (x86/amd64 only) | XFCE |

## Build examples

### Headless CKB node (Orange Pi 3B)
```bash
CKB_PROFILE=ckb-node bash compile.sh build \
  BOARD=orangepi3b BRANCH=current RELEASE=bookworm \
  BUILD_MINIMAL=yes BUILD_ONLY=yes COMPRESS_OUTPUTIMAGE=sha,xz
```

### Solo miner (Raspberry Pi 4)
```bash
CKB_PROFILE=solo-miner bash compile.sh build \
  BOARD=rpi4b BRANCH=current RELEASE=bookworm \
  BUILD_MINIMAL=yes BUILD_ONLY=yes COMPRESS_OUTPUTIMAGE=sha,xz
```

### Fiber kiosk (Orange Pi 5+)
```bash
CKB_PROFILE=fiber-kiosk bash compile.sh build \
  BOARD=orangepi5-plus BRANCH=current RELEASE=bookworm \
  BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=xfce \
  BUILD_ONLY=yes COMPRESS_OUTPUTIMAGE=sha,xz
```

### Neuron desktop (N100 / x86 mini PC)
```bash
CKB_PROFILE=neuron-desktop bash compile.sh build \
  BOARD=generic BRANCH=current RELEASE=bookworm \
  BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=xfce \
  BUILD_ONLY=yes COMPRESS_OUTPUTIMAGE=sha,xz
```

## First boot

On first boot a wizard runs that:
- **ckb-node**: starts all services, prints dashboard URL
- **solo-miner**: prompts for your CKB reward address, configures stratum
- **fiber-kiosk**: generates fresh Fiber keypair, prints wallet address to fund
- **neuron-desktop**: starts CKB node, Neuron launches from desktop

## Custom CKB / Fiber versions

```bash
CKB_PROFILE=ckb-node CKB_VERSION=0.205.0 bash compile.sh build ...
CKB_PROFILE=fiber-kiosk FIBER_VERSION=0.8.0 bash compile.sh build ...
```

## Icons

Drop your custom PNGs into `overlay/usr/share/pixmaps/`:
- `ckb-icon.png` — used by CKB Dashboard and Status launchers
- `fiber-icon.png` — used by Fiber UI launcher
- `neuron-icon.png` — used by Neuron launcher

Recommended size: 64×64 or 128×128 PNG.

## Supported boards

Any Armbian-supported board. Tested on:
- Orange Pi 3B (RK3566)
- Orange Pi 5 / 5+ (RK3588S)
- Raspberry Pi 4B

See [Armbian board list](https://github.com/armbian/build/tree/main/config/boards) for the full 300+ board catalogue.
