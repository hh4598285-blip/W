# Hebrew OS Live - Bootable ISO Builder

Hebrew-language Live OS, bootable from USB via Rufus, no installation required.

## Contents
- `scripts/` - build scripts
- `.github/workflows/` - GitHub Actions automated build

## How to build
1. Go to the Actions tab of this repo
2. Select "Build Hebrew OS Live ISO"
3. Click "Run workflow"
4. Wait (this can take a few hours - building a full OS is a long process
   and may fail due to GitHub Actions time/disk limits)
5. If it succeeds, download the ISO from the run's Artifacts section