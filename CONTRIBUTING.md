# Contributing to drm-colortemp

Thank you for considering contributing! This is a workaround tool for COSMIC DE until native gamma control is implemented.

## How to Contribute

### Reporting Issues

- Check if the issue already exists
- Include your system info (distro, COSMIC version, kernel version)
- Include relevant logs: `sudo journalctl -u drm-colortemp-daemon -n 50`
- Describe what you expected vs what happened

### Suggesting Features

- Check if it's already requested
- Explain the use case
- Consider if it's better implemented in COSMIC itself

### Pull Requests

1. Fork the repo
2. Create a feature branch: `git checkout -b feature-name`
3. Make your changes
4. Test thoroughly
5. Update documentation if needed
6. Submit PR with clear description

### Code Style

**C Code:**
- Follow existing style
- Use 4-space indentation
- Comment non-obvious logic
- Keep functions focused and readable

**Shell Scripts:**
- Use `shellcheck` to validate
- Quote variables properly
- Handle errors gracefully
- Test on Ubuntu/Pop!_OS

### Testing

Before submitting:

```bash
# Compile and test
make clean
make

# Test tool manually
sudo ./drm_colortemp -h
sudo ./drm_colortemp_daemon -h

# Test on actual system (from TTY)
sudo ./drm_colortemp -d /dev/dri/card1 -t 3500
```

### Commit Messages

- Use clear, descriptive messages
- Reference issues: "Fix notification bug (#42)"
- Keep first line under 72 chars

## Development Setup

```bash
# Clone
git clone https://github.com/jjo/drm-colortemp.git
cd drm-colortemp

# Install deps
sudo apt install build-essential libdrm-dev linux-libc-dev libnotify-bin

# Build
make

# Test
sudo ./drm_colortemp -h
```

## The Big Picture

This is a **temporary workaround**. The real solution is for COSMIC to implement `wlr-gamma-control-unstable-v1` protocol.

Consider contributing to:
- https://github.com/pop-os/cosmic-comp

Issues tracking gamma support:
- https://github.com/pop-os/cosmic-comp/issues/2059

## Questions?

Open an issue for discussion before starting major work.

## License

By contributing, you agree your code will be released under the Apache License 2.0.
