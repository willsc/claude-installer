# Claude Code Installer for Ubuntu

A comprehensive Python script to install, manage, and uninstall [Claude Code](https://docs.anthropic.com/en/docs/claude-code) on Ubuntu systems with support for multiple shells, HTTP proxies, and AWS Bedrock.

## Features

- **Multi-shell support**: Automatically configures bash, zsh, fish, csh, and tcsh
- **Idempotent operations**: Safe to run multiple times without duplicating configurations
- **Proxy support**: Configure HTTP/HTTPS proxies for corporate environments
- **AWS Bedrock support**: Use Claude via AWS Bedrock with bearer token authentication
- **Clean uninstall**: Completely removes Claude Code and cleans up shell configurations
- **Status checking**: Verify installation status and environment configuration

## Requirements

- Ubuntu (or Debian-based Linux)
- Python 3.6+
- curl (for NVM installation)
- Internet connection

## Quick Start

```bash
# Download the script
curl -O https://example.com/install_claude.py
chmod +x install_claude.py

# Install with Anthropic API token
python3 install_claude.py install --token "sk-ant-your-token-here"

# Restart your shell or source config
source ~/.bashrc  # or ~/.zshrc, etc.

# Verify installation
claude --version
```

## Commands

### Install

Install Claude Code with all dependencies (NVM, Node.js).

```bash
python3 install_claude.py install [OPTIONS]
```

#### Options

| Option | Short | Description |
|--------|-------|-------------|
| `--token TOKEN` | `-t` | API token (Anthropic or AWS Bedrock bearer token) |
| `--bedrock` | | Use AWS Bedrock authentication mode |
| `--aws-region REGION` | `-r` | AWS region for Bedrock (e.g., `us-east-1`) |
| `--aws-profile PROFILE` | | AWS profile name |
| `--proxy URL` | `-p` | HTTP/HTTPS proxy URL |
| `--no-proxy` | | Skip proxy configuration |
| `--node-version VERSION` | `-n` | Node.js version to install (default: `22`) |
| `--force` | `-f` | Force reinstall even if already installed |
| `--verbose` | `-v` | Enable verbose output |

#### Examples

```bash
# Basic installation with Anthropic API
python3 install_claude.py install --token "sk-ant-api03-xxxxx"

# Installation with AWS Bedrock
python3 install_claude.py install \
  --token "eyJhbGciOiJIUzI1NiIs..." \
  --bedrock \
  --aws-region us-east-1 \
  --aws-profile default

# Installation behind corporate proxy
python3 install_claude.py install \
  --token "sk-ant-api03-xxxxx" \
  --proxy "http://proxy.company.com:8080"

# Force reinstall with specific Node.js version
python3 install_claude.py install \
  --token "sk-ant-api03-xxxxx" \
  --node-version 20 \
  --force

# Install without token (configure token later)
python3 install_claude.py install
```

### Check

Check the installation status of all components.

```bash
python3 install_claude.py check [OPTIONS]
```

#### Options

| Option | Short | Description |
|--------|-------|-------------|
| `--verbose` | `-v` | Enable verbose output |

#### Example Output

```
==================================================
🔍 Claude Code Status Check
==================================================

✓ Node.js v22.11.0 (OK - >=18)
✓ npm v10.9.0
✓ NVM: Installed at /home/user/.nvm
✓ Claude Code: 1.0.0
ℹ Path: /home/user/.npm-global/bin/claude

📋 Environment Variables:
✓   ANTHROPIC_API_KEY: sk-ant-api...xxxx
ℹ   AWS_REGION: us-east-1

🐚 Shell Configurations:
✓   bash (current): Configured
✓   zsh: Configured
✓   fish: Configured

✓ Claude Code is ready to use!
```

### Uninstall

Remove Claude Code and optionally Node.js/NVM.

```bash
python3 install_claude.py uninstall [OPTIONS]
```

#### Options

| Option | Description |
|--------|-------------|
| `--keep-node` | Keep Node.js and NVM installed |
| `--verbose` | Enable verbose output |

#### Examples

```bash
# Full uninstall (removes Claude Code, Node.js, and NVM)
python3 install_claude.py uninstall

# Uninstall Claude Code but keep Node.js
python3 install_claude.py uninstall --keep-node
```

## Shell Configuration

The installer automatically detects and configures all installed shells on your system.

### Supported Shells

| Shell | Config File(s) |
|-------|---------------|
| bash | `~/.bashrc`, `~/.bash_profile`, `~/.profile` |
| zsh | `~/.zshrc`, `~/.zprofile` |
| fish | `~/.config/fish/conf.d/claude.fish` |
| csh | `~/.cshrc`, `~/.login` |
| tcsh | `~/.tcshrc`, `~/.cshrc`, `~/.login` |

### Configuration Block

The installer adds a clearly marked configuration block to your shell config files:

```bash
# >>> Claude Code Configuration >>>
# Generated on 2025-01-29 12:00:00

export NVM_DIR="/home/user/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

export PATH="/home/user/.npm-global/bin:$PATH"

export ANTHROPIC_API_KEY="sk-ant-api03-xxxxx"

export NODE_EXTRA_CA_CERTS="/etc/ssl/certs/ca-certificates.crt"

# <<< Claude Code Configuration <<<
```

This block is automatically replaced when you re-run the installer, ensuring idempotent updates.

## Authentication Modes

### Anthropic API (Default)

Use your Anthropic API key directly:

```bash
python3 install_claude.py install --token "sk-ant-api03-your-key-here"
```

This sets the `ANTHROPIC_API_KEY` environment variable.

### AWS Bedrock

Use Claude via AWS Bedrock with a bearer token:

```bash
python3 install_claude.py install \
  --token "your-bearer-token" \
  --bedrock \
  --aws-region us-east-1
```

This sets:
- `AWS_BEARER_TOKEN_BEDROCK`
- `CLAUDE_CODE_USE_BEDROCK=1`
- `AWS_REGION`
- `ANTHROPIC_BEDROCK_REGION`

## Proxy Configuration

For environments behind corporate proxies:

```bash
python3 install_claude.py install \
  --token "sk-ant-xxxxx" \
  --proxy "http://proxy.example.com:8080"
```

This configures:
- `HTTP_PROXY`
- `HTTPS_PROXY`
- `http_proxy`
- `https_proxy`

To skip proxy configuration even if previously set:

```bash
python3 install_claude.py install --token "sk-ant-xxxxx" --no-proxy
```

## Troubleshooting

### Claude command not found after installation

Restart your terminal or source your shell configuration:

```bash
# Bash
source ~/.bashrc

# Zsh
source ~/.zshrc

# Fish
source ~/.config/fish/conf.d/claude.fish

# Csh/Tcsh
source ~/.cshrc
```

### Permission errors during npm install

The installer uses NVM and a user-local npm prefix to avoid permission issues. If you still encounter problems:

```bash
# Check npm prefix
npm config get prefix

# Should be: /home/yourusername/.npm-global
```

### Node.js version too old

Force reinstall with a specific version:

```bash
python3 install_claude.py install --node-version 22 --force
```

### Verify NVM is working

```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm --version
node --version
```

### Check installation paths

```bash
which claude
which node
which npm
```

## Directory Structure

After installation, the following directories are created:

```
$HOME/
├── .nvm/                    # NVM installation
│   ├── nvm.sh
│   └── versions/
│       └── node/
│           └── v22.x.x/     # Node.js installation
├── .npm-global/             # Global npm packages
│   ├── bin/
│   │   └── claude          # Claude Code binary
│   └── lib/
└── .bashrc                  # Shell config (modified)
```

## Updating Claude Code

To update to the latest version:

```bash
# Re-run install with --force
python3 install_claude.py install --token "your-token" --force

# Or manually via npm
npm update -g @anthropic-ai/claude-code
```

## Updating Your Token

Simply re-run the install command with the new token:

```bash
python3 install_claude.py install --token "new-token-here"
```

The configuration is idempotent-it will replace the old token without duplicating entries.

## Testing with Dummy Tokens

For testing the installation process without a real token:

```bash
# Dummy Anthropic token
python3 install_claude.py install --token "sk-ant-test-1234567890abcdef"

# Dummy Bedrock token
python3 install_claude.py install \
  --token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0In0.test" \
  --bedrock \
  --aws-region us-east-1
```

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## See Also

- [Claude Code Documentation](https://docs.anthropic.com/en/docs/claude-code)
- [Anthropic API Documentation](https://docs.anthropic.com/)
- [AWS Bedrock Documentation](https://docs.aws.amazon.com/bedrock/)
