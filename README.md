# py-build

[![Build Status](https://github.com/plfj/py-build/actions/workflows/build.yml/badge.svg)](https://github.com/plfj/py-build/actions)

**py-build** is an advanced build automation system for producing cross-compiled Python Debian packages targeting aarch64 on macOS.  
It orchestrates the cloning, patching, building, packaging, and artifact delivery of Python 3.13, 3.14, and 3.15 for Android (aarch64) via GitHub Actions.

---

## Key Features

- **Automated Build Pipeline:** Complete workflow for building Python binaries from source, including patching and dependency management.
- **Multi-version Support:** Builds Python 3.13, 3.14, and 3.15 in parallel.
- **Cross-Compilation:** Targets Android (aarch64) architecture, executed on macOS runners.
- **Debian Packaging:** Produces `.deb` packages suitable for Termux or aarch64-based systems.
- **Artifact Delivery:** Artifacts are uploaded automatically for each Python version build.

---

## Supported Platforms & Versions

- **OS:** macOS (build host)
- **Target:** Android (aarch64)
- **Python versions:** 3.13, 3.14, 3.15

---

## Usage

### GitHub Actions Workflow

Builds are managed via [`.github/workflows/build.yml`](.github/workflows/build.yml).  
Each push or pull request to `main` or `3.*` branches triggers jobs for Python 3.13, 3.14, and 3.15.

### Artifacts

After a successful workflow run, the following Debian packages are available as downloadable artifacts:
- `pyv313_3.13_aarch64.deb`
- `pyv314_3.14_aarch64.deb`
- `pyv315_3.15_aarch64.deb`

Artifacts can be found in the "Actions" tab for each workflow run.

---

## Example Workflow Overview

1. **Clone CPython Source:**  
   Uses the appropriate branch for each Python version.

2. **Apply Patch (if needed):**  
   For 3.13, applies a Termux-specific patch.

3. **Build for Android aarch64:**  
   Cross-compiles Python using custom scripts and tools.

4. **Package as Debian `.deb`:**  
   Includes metadata and post-install script for Termux compatibility.

5. **Upload Artifact:**  
   Resulting `.deb` files are available for download.

---

## License

Licensed under the [Apache License 2.0](LICENSE).

---

## Maintainer

Developed and maintained by [plfj](https://github.com/plfj).

---

## Project Status

- **Type:** Build automation and cross-compilation for Python
- **Focus:** aarch64, macOS host, Android/Termux target
- **Debian packaging:** Yes
- **CI/CD:** GitHub Actions (macos-14 runners)
- **License:** Apache 2.0

---

## Links

- [Repository](https://github.com/plfj/py-build)
- [Workflow: build.yml](https://github.com/plfj/py-build/blob/main/.github/workflows/build.yml)
- [Issues](https://github.com/plfj/py-build/issues)
- [Releases](https://github.com/plfj/py-build/releases)
