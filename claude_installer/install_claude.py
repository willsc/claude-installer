#!/usr/bin/env python3

"""
Claude Code Installer - Fixed version with proper Node.js and permission handling

Supports: bash, zsh, fish, csh, tcsh shells
Features: install, check, uninstall commands with idempotent operations

Usage:
    python3 install_claude.py install --token "your_token"
    python3 install_claude.py install --token "your_token" --aws-region us-east-1
    python3 install_claude.py install --proxy http://proxy:8080
    python3 install_claude.py check
    python3 install_claude.py uninstall
    python3 install_claude.py uninstall --keep-node
"""

import os
import sys
import subprocess
import argparse
import shutil
import re
import getpass
from pathlib import Path
from datetime import datetime
from typing import Optional, Tuple, Dict, List


# Configuration block markers for idempotent updates
CONFIG_START_MARKER = "# >>> Claude Code Configuration >>>"
CONFIG_END_MARKER = "# <<< Claude Code Configuration <<<"


class ClaudeInstaller:
    def __init__(self):
        self.config = {
            'token': '',
            'token_type': 'anthropic',  # 'anthropic' or 'bedrock'
            'aws_region': '',
            'aws_profile': '',
            'http_proxy': '',
            'node_version': '22',
            'node_extra_ca_certs': '/etc/ssl/certs/ca-certificates.crt',
            'skip_proxy': False,
            'keep_node': False,
            'force': False,
            'verbose': False,
        }
        self.user_home = Path.home()
        self.nvm_dir = self.user_home / '.nvm'
        self.npm_global_dir = self.user_home / '.npm-global'
        
        # Shell configurations
        self.shell_configs = {
            'bash': {
                'rc_files': ['.bashrc', '.bash_profile', '.profile'],
                'env_syntax': 'export {key}="{value}"',
                'path_syntax': 'export PATH="{path}:$PATH"',
            },
            'zsh': {
                'rc_files': ['.zshrc', '.zprofile'],
                'env_syntax': 'export {key}="{value}"',
                'path_syntax': 'export PATH="{path}:$PATH"',
            },
            'fish': {
                'rc_files': ['.config/fish/conf.d/claude.fish'],
                'env_syntax': 'set -gx {key} "{value}"',
                'path_syntax': 'fish_add_path "{path}"',
            },
            'csh': {
                'rc_files': ['.cshrc', '.login'],
                'env_syntax': 'setenv {key} "{value}"',
                'path_syntax': 'setenv PATH "{path}:$PATH"',
            },
            'tcsh': {
                'rc_files': ['.tcshrc', '.cshrc', '.login'],
                'env_syntax': 'setenv {key} "{value}"',
                'path_syntax': 'setenv PATH "{path}:$PATH"',
            },
        }
    
    def log(self, message: str, level: str = "info"):
        """Print formatted log message"""
        symbols = {
            "info": "ℹ",
            "success": "✓",
            "warning": "⚠",
            "error": "❌",
            "step": "→",
        }
        symbol = symbols.get(level, "•")
        print(f"{symbol} {message}")
    
    def log_verbose(self, message: str):
        """Print message only in verbose mode"""
        if self.config['verbose']:
            print(f"  [DEBUG] {message}")
    
    def run_command(self, cmd, shell=False, capture_output=False, check=True, env=None) -> Optional[str]:
        """Run a shell command with proper error handling"""
        try:
            if env is None:
                env = os.environ.copy()
            
            self.log_verbose(f"Running: {cmd if shell else ' '.join(cmd)}")
            
            if capture_output:
                result = subprocess.run(
                    cmd, 
                    shell=shell, 
                    check=check, 
                    capture_output=True, 
                    text=True,
                    encoding='utf-8',
                    errors='ignore',
                    env=env
                )
                return result.stdout.strip()
            else:
                result = subprocess.run(cmd, shell=shell, check=check, env=env)
                return "success" if result.returncode == 0 else None
        except subprocess.CalledProcessError as e:
            if self.config['verbose']:
                self.log(f"Command failed: {cmd}", "error")
                if e.stderr:
                    print(f"   Stderr: {e.stderr[:500]}")
            return None
        except FileNotFoundError:
            return None
        except Exception as e:
            if self.config['verbose']:
                self.log(f"Unexpected error: {e}", "error")
            return None
    
    def check_node_version(self) -> Tuple[bool, str]:
        """Check if Node.js is installed and meets version requirements (>=18)"""
        # First try using nvm's node
        nvm_node_check = f'''
        export NVM_DIR="{self.nvm_dir}"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        node --version 2>/dev/null
        '''
        node_version = self.run_command(['bash', '-c', nvm_node_check], capture_output=True, check=False)
        
        if not node_version:
            # Fallback to system node
            node_version = self.run_command(['node', '--version'], capture_output=True, check=False)
        
        if not node_version:
            return False, "Node.js not found"
        
        version_match = re.search(r'v(\d+)\.(\d+)\.(\d+)', node_version)
        if version_match:
            major_version = int(version_match.group(1))
            if major_version >= 18:
                return True, f"Node.js {node_version} (OK - >=18)"
            else:
                return False, f"Node.js {node_version} (Too old - need >=18)"
        else:
            return False, f"Could not parse Node.js version: {node_version}"
    
    def check_npm_version(self) -> Tuple[bool, str]:
        """Check if npm is installed"""
        nvm_npm_check = f'''
        export NVM_DIR="{self.nvm_dir}"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        npm --version 2>/dev/null
        '''
        npm_version = self.run_command(['bash', '-c', nvm_npm_check], capture_output=True, check=False)
        
        if not npm_version:
            npm_version = self.run_command(['npm', '--version'], capture_output=True, check=False)
        
        if npm_version:
            return True, f"npm v{npm_version}"
        return False, "npm not found"
    
    def check_claude_installed(self) -> Tuple[bool, str, str]:
        """Check if Claude Code is installed and return version and path"""
        # Check with nvm sourced first
        check_cmd = f'''
        export NVM_DIR="{self.nvm_dir}"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        export PATH="{self.npm_global_dir}/bin:$PATH"
        which claude 2>/dev/null
        '''
        claude_path = self.run_command(['bash', '-c', check_cmd], capture_output=True, check=False)
        
        if not claude_path:
            # Try common locations
            possible_paths = [
                self.npm_global_dir / 'bin' / 'claude',
                self.user_home / '.local' / 'bin' / 'claude',
                Path('/usr/local/bin/claude'),
                Path('/usr/bin/claude'),
            ]
            for p in possible_paths:
                if p.exists():
                    claude_path = str(p)
                    break
        
        if not claude_path:
            return False, "Not installed", ""
        
        # Get version
        version_cmd = f'''
        export NVM_DIR="{self.nvm_dir}"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        "{claude_path}" --version 2>/dev/null || echo "unknown"
        '''
        version = self.run_command(['bash', '-c', version_cmd], capture_output=True, check=False)
        version = version or "unknown"
        
        return True, version, claude_path
    
    def get_user_shell(self) -> str:
        """Get the user's login shell"""
        try:
            username = getpass.getuser()
            with open('/etc/passwd', 'r') as f:
                for line in f:
                    parts = line.strip().split(':')
                    if len(parts) >= 7 and parts[0] == username:
                        return os.path.basename(parts[6])
        except Exception:
            pass
        
        # Fallback to SHELL environment variable
        shell_path = os.environ.get('SHELL', '/bin/bash')
        return os.path.basename(shell_path)
    
    def get_installed_shells(self) -> Dict[str, bool]:
        """Check which shells are installed on the system"""
        installed = {}
        for shell_name in self.shell_configs:
            shell_path = shutil.which(shell_name)
            installed[shell_name] = shell_path is not None
        return installed
    
    def install_nvm(self) -> bool:
        """Install NVM (Node Version Manager)"""
        if (self.nvm_dir / 'nvm.sh').exists():
            self.log("NVM is already installed", "success")
            return True
        
        self.log("Installing NVM...", "step")
        
        # Install NVM with suppressed output for "already exists" messages
        # NVM installer outputs to stderr for info messages
        nvm_install_script = '''
        export NVM_DIR="$HOME/.nvm"
        curl -s -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash 2>&1 | grep -v "already in" | grep -v "^=>" || true
        '''
        
        result = self.run_command(['bash', '-c', nvm_install_script], check=False)
        
        # Verify NVM was installed
        if (self.nvm_dir / 'nvm.sh').exists():
            self.log("NVM installed successfully", "success")
            return True
        else:
            self.log("Failed to install NVM", "error")
            return False
    
    def install_node(self) -> bool:
        """Install Node.js using NVM"""
        node_ok, _ = self.check_node_version()
        if node_ok and not self.config['force']:
            self.log("Node.js already installed and meets requirements", "success")
            return True
        
        if not (self.nvm_dir / 'nvm.sh').exists():
            if not self.install_nvm():
                return False
        
        self.log(f"Installing Node.js v{self.config['node_version']}...", "step")
        
        # Install Node.js, filtering out NVM's informational messages
        nvm_install_node = f'''
        export NVM_DIR="{self.nvm_dir}"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        nvm install {self.config['node_version']} --latest-npm 2>&1 | grep -v "already in" | grep -v "^=>" || true
        nvm use {self.config['node_version']} > /dev/null 2>&1
        nvm alias default {self.config['node_version']} > /dev/null 2>&1
        node --version
        '''
        
        result = self.run_command(['bash', '-c', nvm_install_node], capture_output=True, check=False)
        
        # Verify Node was installed correctly
        node_ok, node_msg = self.check_node_version()
        if node_ok:
            self.log(f"Node.js installed successfully ({node_msg})", "success")
            return True
        else:
            self.log(f"Failed to install Node.js: {node_msg}", "error")
            return False
    
    def install_claude_code(self) -> bool:
        """Install Claude Code via npm"""
        installed, version, path = self.check_claude_installed()
        if installed and not self.config['force']:
            self.log(f"Claude Code already installed: {version}", "success")
            return True
        
        self.log("Installing Claude Code...", "step")
        
        # Ensure npm global directory structure exists BEFORE npm config
        self.npm_global_dir.mkdir(parents=True, exist_ok=True)
        (self.npm_global_dir / 'bin').mkdir(exist_ok=True)
        (self.npm_global_dir / 'lib').mkdir(exist_ok=True)
        (self.npm_global_dir / 'share').mkdir(exist_ok=True)
        
        # Build install command - create dirs in bash too for safety
        install_cmd = f'''
        export NVM_DIR="{self.nvm_dir}"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        
        # Ensure npm-global directory exists
        mkdir -p "{self.npm_global_dir}/bin"
        mkdir -p "{self.npm_global_dir}/lib"
        mkdir -p "{self.npm_global_dir}/share"
        
        # Set npm prefix
        npm config set prefix "{self.npm_global_dir}"
        '''
        
        # Add proxy configuration if specified
        if self.config['http_proxy'] and not self.config['skip_proxy']:
            install_cmd += f'''
        npm config set proxy {self.config['http_proxy']}
        npm config set https-proxy {self.config['http_proxy']}
        '''
        
        install_cmd += '''
        npm install -g @anthropic-ai/claude-code
        '''
        
        result = self.run_command(['bash', '-c', install_cmd], check=False)
        if result:
            self.log("Claude Code installed successfully", "success")
            return True
        
        # Fallback: try without setting prefix (use nvm's global)
        self.log("Trying alternative installation method...", "step")
        fallback_cmd = f'''
        export NVM_DIR="{self.nvm_dir}"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        npm install -g @anthropic-ai/claude-code
        '''
        
        result = self.run_command(['bash', '-c', fallback_cmd], check=False)
        if result:
            self.log("Claude Code installed successfully (via nvm global)", "success")
            return True
        
        self.log("Failed to install Claude Code", "error")
        return False
    
    def generate_shell_config(self, shell_name: str) -> str:
        """Generate shell-specific configuration content"""
        shell_info = self.shell_configs[shell_name]
        lines = [CONFIG_START_MARKER]
        lines.append(f"# Generated on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        lines.append("")
        
        # NVM configuration
        if shell_name == 'fish':
            lines.append(f'set -gx NVM_DIR "{self.nvm_dir}"')
            lines.append('')
            lines.append('# Add nvm Node.js to PATH')
            lines.append('if test -d "$NVM_DIR/versions/node"')
            lines.append('    for version_dir in (ls -d "$NVM_DIR/versions/node"/* 2>/dev/null | sort -V -r)')
            lines.append('        if test -d "$version_dir/bin"')
            lines.append('            fish_add_path "$version_dir/bin"')
            lines.append('            break')
            lines.append('        end')
            lines.append('    end')
            lines.append('end')
            lines.append('')
            lines.append(f'fish_add_path "{self.npm_global_dir}/bin"')
        elif shell_name in ('csh', 'tcsh'):
            lines.append(f'setenv NVM_DIR "{self.nvm_dir}"')
            lines.append('')
            lines.append('# Add nvm Node.js to PATH (static - may need adjustment)')
            # For csh/tcsh we need to find the node version directory
            node_versions_dir = self.nvm_dir / 'versions' / 'node'
            if node_versions_dir.exists():
                versions = sorted(node_versions_dir.iterdir(), reverse=True)
                if versions:
                    lines.append(f'if ( -d "{versions[0]}/bin" ) then')
                    lines.append(f'    setenv PATH "{versions[0]}/bin:$PATH"')
                    lines.append('endif')
            lines.append(f'setenv PATH "{self.npm_global_dir}/bin:$PATH"')
        else:  # bash, zsh
            lines.append(f'export NVM_DIR="{self.nvm_dir}"')
            lines.append('[ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"')
            lines.append('[ -s "$NVM_DIR/bash_completion" ] && \\. "$NVM_DIR/bash_completion"')
            lines.append('')
            lines.append(f'export PATH="{self.npm_global_dir}/bin:$PATH"')
        
        lines.append('')
        
        # API Token configuration
        if self.config['token']:
            if self.config['token_type'] == 'bedrock':
                lines.append(shell_info['env_syntax'].format(key='AWS_BEARER_TOKEN_BEDROCK', value=self.config['token']))
                lines.append(shell_info['env_syntax'].format(key='CLAUDE_CODE_USE_BEDROCK', value='1'))
            else:
                lines.append(shell_info['env_syntax'].format(key='ANTHROPIC_API_KEY', value=self.config['token']))
        
        # AWS region
        if self.config['aws_region']:
            lines.append(shell_info['env_syntax'].format(key='AWS_REGION', value=self.config['aws_region']))
            if self.config['token_type'] == 'bedrock':
                lines.append(shell_info['env_syntax'].format(key='ANTHROPIC_BEDROCK_REGION', value=self.config['aws_region']))
        
        # AWS profile
        if self.config['aws_profile']:
            lines.append(shell_info['env_syntax'].format(key='AWS_PROFILE', value=self.config['aws_profile']))
        
        # Proxy configuration
        if self.config['http_proxy'] and not self.config['skip_proxy']:
            lines.append(shell_info['env_syntax'].format(key='HTTP_PROXY', value=self.config['http_proxy']))
            lines.append(shell_info['env_syntax'].format(key='HTTPS_PROXY', value=self.config['http_proxy']))
            lines.append(shell_info['env_syntax'].format(key='http_proxy', value=self.config['http_proxy']))
            lines.append(shell_info['env_syntax'].format(key='https_proxy', value=self.config['http_proxy']))
        
        # Node extra CA certs
        lines.append(shell_info['env_syntax'].format(key='NODE_EXTRA_CA_CERTS', value=self.config['node_extra_ca_certs']))
        
        lines.append('')
        lines.append(CONFIG_END_MARKER)
        
        return '\n'.join(lines) + '\n'
    
    def update_shell_config(self, shell_name: str) -> Optional[str]:
        """Update shell configuration file (idempotent)"""
        shell_info = self.shell_configs.get(shell_name)
        if not shell_info:
            return None
        
        config_content = self.generate_shell_config(shell_name)
        updated_file = None
        
        for rc_file in shell_info['rc_files']:
            rc_path = self.user_home / rc_file
            
            # For fish, create parent directories
            if shell_name == 'fish':
                rc_path.parent.mkdir(parents=True, exist_ok=True)
            
            # Read existing content
            existing_content = ""
            if rc_path.exists():
                existing_content = rc_path.read_text()
            
            # Remove existing Claude Code configuration block (idempotent)
            if CONFIG_START_MARKER in existing_content:
                pattern = re.escape(CONFIG_START_MARKER) + r'.*?' + re.escape(CONFIG_END_MARKER)
                existing_content = re.sub(pattern, '', existing_content, flags=re.DOTALL)
                existing_content = re.sub(r'\n{3,}', '\n\n', existing_content).strip()
            
            # Append new configuration
            if existing_content:
                new_content = existing_content + '\n\n' + config_content
            else:
                new_content = config_content
            
            rc_path.write_text(new_content)
            updated_file = str(rc_path)
            
            self.log_verbose(f"Updated {rc_path}")
            
            # For bash/zsh, only update first existing file or create .bashrc/.zshrc
            if shell_name not in ('fish',):
                break
        
        if updated_file:
            self.log(f"Configured {shell_name}: {updated_file}", "success")
        
        return updated_file
    
    def remove_shell_config(self, shell_name: str) -> bool:
        """Remove Claude Code configuration from shell config files"""
        shell_info = self.shell_configs.get(shell_name)
        if not shell_info:
            return False
        
        removed = False
        
        for rc_file in shell_info['rc_files']:
            rc_path = self.user_home / rc_file
            
            if not rc_path.exists():
                continue
            
            content = rc_path.read_text()
            
            if CONFIG_START_MARKER in content:
                pattern = re.escape(CONFIG_START_MARKER) + r'.*?' + re.escape(CONFIG_END_MARKER)
                new_content = re.sub(pattern, '', content, flags=re.DOTALL)
                new_content = re.sub(r'\n{3,}', '\n\n', new_content).strip() + '\n'
                
                rc_path.write_text(new_content)
                self.log(f"Cleaned {rc_path}", "success")
                removed = True
        
        return removed
    
    def uninstall_claude_code(self) -> bool:
        """Uninstall Claude Code via npm"""
        self.log("Uninstalling Claude Code...", "step")
        
        uninstall_cmd = f'''
        export NVM_DIR="{self.nvm_dir}"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        npm config set prefix "{self.npm_global_dir}"
        npm uninstall -g @anthropic-ai/claude-code 2>/dev/null
        '''
        
        self.run_command(['bash', '-c', uninstall_cmd], check=False)
        
        # Also try without prefix
        fallback_cmd = f'''
        export NVM_DIR="{self.nvm_dir}"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        npm uninstall -g @anthropic-ai/claude-code 2>/dev/null
        '''
        self.run_command(['bash', '-c', fallback_cmd], check=False)
        
        self.log("Claude Code uninstalled", "success")
        return True
    
    def uninstall_node_nvm(self) -> bool:
        """Remove NVM and Node.js"""
        self.log("Removing NVM and Node.js...", "step")
        
        if self.nvm_dir.exists():
            try:
                shutil.rmtree(self.nvm_dir)
                self.log("NVM directory removed", "success")
            except Exception as e:
                self.log(f"Failed to remove NVM: {e}", "error")
                return False
        
        # Also clean up npm-global directory
        if self.npm_global_dir.exists():
            try:
                shutil.rmtree(self.npm_global_dir)
                self.log("npm global directory removed", "success")
            except Exception as e:
                self.log(f"Failed to remove npm-global: {e}", "warning")
        
        return True
    
    # ==================== Commands ====================
    
    def cmd_install(self) -> int:
        """Execute installation"""
        print("\n" + "=" * 50)
        print("🚀 Claude Code Installation")
        print("=" * 50 + "\n")
        
        # Check if already installed
        installed, version, path = self.check_claude_installed()
        if installed and not self.config['force']:
            self.log(f"Claude Code is already installed: {version}", "success")
            self.log("Use --force to reinstall", "info")
            
            # Still update shell configs if token provided
            if self.config['token']:
                self.log("Updating shell configurations with new settings...", "step")
                shells = self.get_installed_shells()
                for shell_name, is_installed in shells.items():
                    if is_installed:
                        self.update_shell_config(shell_name)
            return 0
        
        # Step 1: Install NVM
        self.log("Step 1: Setting up NVM", "step")
        if not self.install_nvm():
            return 1
        
        # Step 2: Install Node.js
        self.log("Step 2: Installing Node.js", "step")
        if not self.install_node():
            return 1
        
        # Step 3: Install Claude Code
        self.log("Step 3: Installing Claude Code", "step")
        if not self.install_claude_code():
            return 1
        
        # Step 4: Configure shells
        self.log("Step 4: Configuring shell environments", "step")
        shells = self.get_installed_shells()
        current_shell = self.get_user_shell()
        
        for shell_name, is_installed in shells.items():
            if is_installed:
                self.update_shell_config(shell_name)
        
        # Step 5: Verify installation
        self.log("Step 5: Verifying installation", "step")
        installed, version, path = self.check_claude_installed()
        
        # Summary
        print("\n" + "=" * 50)
        if installed:
            print("✅ Installation Complete!")
        else:
            print("⚠ Installation may require shell restart")
        print("=" * 50)
        
        print(f"\n🐚 Your shell: {current_shell}")
        print(f"\n💻 Next steps:")
        print(f"   1. Restart your terminal or run:")
        
        if current_shell == 'fish':
            print(f"      source ~/.config/fish/conf.d/claude.fish")
        elif current_shell == 'zsh':
            print(f"      source ~/.zshrc")
        elif current_shell in ('csh', 'tcsh'):
            print(f"      source ~/.{current_shell}rc")
        else:
            print(f"      source ~/.bashrc")
        
        print(f"   2. Test: claude --version")
        
        if not self.config['token']:
            print(f"\n⚠ No API token provided. Set it with:")
            print(f"   export ANTHROPIC_API_KEY='your-token'")
        
        return 0
    
    def cmd_check(self) -> int:
        """Check installation status"""
        print("\n" + "=" * 50)
        print("🔍 Claude Code Status Check")
        print("=" * 50 + "\n")
        
        all_ok = True
        
        # Check Node.js
        node_ok, node_msg = self.check_node_version()
        if node_ok:
            self.log(node_msg, "success")
        else:
            self.log(node_msg, "error")
            all_ok = False
        
        # Check npm
        npm_ok, npm_msg = self.check_npm_version()
        if npm_ok:
            self.log(npm_msg, "success")
        else:
            self.log(npm_msg, "error")
            all_ok = False
        
        # Check NVM
        if (self.nvm_dir / 'nvm.sh').exists():
            self.log(f"NVM: Installed at {self.nvm_dir}", "success")
        else:
            self.log("NVM: Not installed", "warning")
        
        # Check Claude Code
        installed, version, path = self.check_claude_installed()
        if installed:
            self.log(f"Claude Code: {version}", "success")
            self.log(f"Path: {path}", "info")
        else:
            self.log("Claude Code: Not installed", "error")
            all_ok = False
        
        # Check environment variables
        print("\n📋 Environment Variables:")
        
        api_key = os.environ.get('ANTHROPIC_API_KEY')
        if api_key:
            masked = api_key[:10] + '...' + api_key[-4:] if len(api_key) > 14 else '***'
            self.log(f"  ANTHROPIC_API_KEY: {masked}", "success")
        else:
            self.log("  ANTHROPIC_API_KEY: Not set", "warning")
        
        for var in ['AWS_BEARER_TOKEN_BEDROCK', 'AWS_REGION', 'AWS_PROFILE', 'HTTP_PROXY']:
            value = os.environ.get(var)
            if value:
                if 'TOKEN' in var or 'KEY' in var:
                    value = value[:10] + '...' if len(value) > 10 else '***'
                self.log(f"  {var}: {value}", "info")
        
        # Check shell configurations
        print("\n🐚 Shell Configurations:")
        shells = self.get_installed_shells()
        current_shell = self.get_user_shell()
        
        for shell_name, is_installed in shells.items():
            if is_installed:
                marker = " (current)" if shell_name == current_shell else ""
                configured = False
                
                for rc_file in self.shell_configs[shell_name]['rc_files']:
                    rc_path = self.user_home / rc_file
                    if rc_path.exists() and CONFIG_START_MARKER in rc_path.read_text():
                        configured = True
                        break
                
                if configured:
                    self.log(f"  {shell_name}{marker}: Configured", "success")
                else:
                    self.log(f"  {shell_name}{marker}: Not configured", "warning")
        
        print()
        if all_ok and installed:
            self.log("Claude Code is ready to use!", "success")
            return 0
        else:
            self.log("Run: python3 install_claude.py install --token YOUR_TOKEN", "info")
            return 1
    
    def cmd_uninstall(self) -> int:
        """Execute uninstallation"""
        print("\n" + "=" * 50)
        print("🗑️  Claude Code Uninstallation")
        print("=" * 50 + "\n")
        
        # Step 1: Uninstall Claude Code
        self.log("Step 1: Removing Claude Code", "step")
        self.uninstall_claude_code()
        
        # Step 2: Remove Node.js and NVM (unless --keep-node)
        if not self.config['keep_node']:
            self.log("Step 2: Removing NVM and Node.js", "step")
            self.uninstall_node_nvm()
        else:
            self.log("Step 2: Keeping Node.js and NVM (--keep-node)", "info")
        
        # Step 3: Clean shell configurations
        self.log("Step 3: Cleaning shell configurations", "step")
        shells = self.get_installed_shells()
        
        for shell_name, is_installed in shells.items():
            if is_installed:
                self.remove_shell_config(shell_name)
        
        # Summary
        print("\n" + "=" * 50)
        print("✅ Uninstallation Complete!")
        print("=" * 50)
        
        print("\n💡 Please restart your terminal for changes to take effect.")
        
        return 0
    
    def run(self):
        """Main CLI interface"""
        parser = argparse.ArgumentParser(
            description='Claude Code Installer for Ubuntu',
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog=__doc__
        )
        
        subparsers = parser.add_subparsers(dest='command', help='Commands')
        
        # Install command
        install_parser = subparsers.add_parser('install', help='Install Claude Code')
        install_parser.add_argument('--token', '-t', help='API token (Anthropic or AWS Bedrock)')
        install_parser.add_argument('--bedrock', action='store_true', help='Use AWS Bedrock (token is bearer token)')
        install_parser.add_argument('--aws-region', '-r', help='AWS region for Bedrock')
        install_parser.add_argument('--aws-profile', help='AWS profile name')
        install_parser.add_argument('--proxy', '-p', help='HTTP proxy URL')
        install_parser.add_argument('--no-proxy', action='store_true', help='Skip proxy configuration')
        install_parser.add_argument('--node-version', '-n', default='22', help='Node.js version (default: 22)')
        install_parser.add_argument('--force', '-f', action='store_true', help='Force reinstall')
        install_parser.add_argument('--verbose', '-v', action='store_true', help='Verbose output')
        
        # Check command
        check_parser = subparsers.add_parser('check', help='Check installation status')
        check_parser.add_argument('--verbose', '-v', action='store_true', help='Verbose output')
        
        # Uninstall command
        uninstall_parser = subparsers.add_parser('uninstall', help='Uninstall Claude Code')
        uninstall_parser.add_argument('--keep-node', action='store_true', help='Keep Node.js and NVM')
        uninstall_parser.add_argument('--verbose', '-v', action='store_true', help='Verbose output')
        
        args = parser.parse_args()
        
        if not args.command:
            parser.print_help()
            return 1
        
        # Store configuration from args
        if hasattr(args, 'verbose'):
            self.config['verbose'] = args.verbose
        
        if args.command == 'install':
            self.config['token'] = args.token or ''
            self.config['token_type'] = 'bedrock' if args.bedrock else 'anthropic'
            self.config['aws_region'] = args.aws_region or ''
            self.config['aws_profile'] = args.aws_profile or ''
            self.config['http_proxy'] = args.proxy or ''
            self.config['skip_proxy'] = args.no_proxy
            self.config['node_version'] = args.node_version
            self.config['force'] = args.force
            return self.cmd_install()
        
        elif args.command == 'check':
            return self.cmd_check()
        
        elif args.command == 'uninstall':
            self.config['keep_node'] = args.keep_node
            return self.cmd_uninstall()
        
        return 0


if __name__ == '__main__':
    try:
        installer = ClaudeInstaller()
        sys.exit(installer.run())
    except KeyboardInterrupt:
        print("\n\n⚠ Operation cancelled by user.")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
