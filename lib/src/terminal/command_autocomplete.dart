import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nexus_ssh/src/models/ssh_models.dart';
import 'package:nexus_ssh/src/models/snippet_template.dart';

enum AutocompleteShellKind {
  linuxPosix,
  unixPosix,
  powershell,
  cmd,
}

enum SuggestionSource {
  localHistory,
  snippet,
  remoteHistory,
  builtin,
}

class AutocompleteSuggestion {
  const AutocompleteSuggestion({
    required this.fullText,
    required this.matchedPrefixLength,
    required this.insertSuffix,
    required this.source,
    this.caption,
  });

  final String fullText;
  final int matchedPrefixLength;
  final String insertSuffix;
  final SuggestionSource source;
  final String? caption;
}

/// Three-tier Termius-inspired command autocomplete engine:
/// 1. Local executed command history (most recent first)
/// 2. User's Command Snippets library
/// 3. Remote shell history read-only pulled from `~/.zsh_history` / `~/.bash_history`
/// 4. Curated high-frequency Linux / DevOps / Docker / Systemd / Git command dictionary
class CommandAutocompleteEngine {
  CommandAutocompleteEngine._();

  static final RegExp _primaryPromptRegex = RegExp(
    r'^.*?(?:[\$#%]|[❯λ])\s+',
  );
  static final RegExp _anglePromptRegex = RegExp(
    r'^[^|&;]*?>\s+',
  );
  static final RegExp _psPromptRegex = RegExp(
    r'^PS\s+[^>]*>\s+',
  );
  static final RegExp _cmdPromptRegex = RegExp(
    r'^[A-Za-z]:\\[^>]*>\s*',
  );

  /// Determines which shell dictionary & prompt rules match a terminal session.
  static AutocompleteShellKind detectShellKind({
    required bool isLocal,
    String shellProgram = '',
    String shellName = '',
  }) {
    if (!isLocal) {
      return AutocompleteShellKind.linuxPosix;
    }
    final combined = '${shellProgram.toLowerCase()} ${shellName.toLowerCase()}';
    if (combined.contains('pwsh') || combined.contains('powershell')) {
      return AutocompleteShellKind.powershell;
    }
    if (combined.contains('cmd.exe') ||
        combined.contains('(cmd)') ||
        shellProgram.toLowerCase().trim() == 'cmd') {
      return AutocompleteShellKind.cmd;
    }
    if (combined.contains('wsl')) {
      return AutocompleteShellKind.linuxPosix;
    }
    if (combined.contains('git bash') || combined.contains(r'\git\')) {
      return AutocompleteShellKind.unixPosix;
    }
    if (!kIsWeb && Platform.isMacOS) {
      return AutocompleteShellKind.unixPosix;
    }
    if (!kIsWeb && Platform.isWindows) {
      return AutocompleteShellKind.powershell;
    }
    return AutocompleteShellKind.linuxPosix;
  }

  /// Extracts the typed command prefix from the terminal's current cursor line.
  /// Returns `null` if no shell prompt is recognized or cursor is not at line end.
  static String? extractCommandPrefix({
    required String lineBeforeCursor,
    required String fullLineTrimmed,
    AutocompleteShellKind shellKind = AutocompleteShellKind.linuxPosix,
  }) {
    if (lineBeforeCursor.trimRight() != fullLineTrimmed) {
      return null;
    }

    if (shellKind == AutocompleteShellKind.cmd) {
      final cmdMatch = _cmdPromptRegex.firstMatch(lineBeforeCursor);
      if (cmdMatch != null) {
        return lineBeforeCursor.substring(cmdMatch.end);
      }
      final angle = _anglePromptRegex.firstMatch(lineBeforeCursor);
      if (angle != null) {
        return lineBeforeCursor.substring(angle.end);
      }
      return null;
    }

    if (shellKind == AutocompleteShellKind.powershell) {
      final psMatch = _psPromptRegex.firstMatch(lineBeforeCursor);
      if (psMatch != null) {
        return lineBeforeCursor.substring(psMatch.end);
      }
      final angle = _anglePromptRegex.firstMatch(lineBeforeCursor);
      if (angle != null) {
        return lineBeforeCursor.substring(angle.end);
      }
      return null;
    }

    final primary = _primaryPromptRegex.firstMatch(lineBeforeCursor);
    if (primary != null) {
      return lineBeforeCursor.substring(primary.end);
    }

    final angle = _anglePromptRegex.firstMatch(lineBeforeCursor);
    if (angle != null) {
      return lineBeforeCursor.substring(angle.end);
    }

    return null;
  }

  /// Checks whether a command looks safe to record in local session history
  /// (follows bash `ignorespace` and avoids secrets/passwords).
  static bool shouldRecordInHistory(String command) {
    if (command.startsWith(' ')) return false;
    final trimmed = command.trim();
    if (trimmed.length < 2 || trimmed.length > 260) return false;
    final upper = trimmed.toUpperCase();
    if (upper.contains('PASSWORD=') ||
        upper.contains('PASSWD') ||
        upper.contains('TOKEN=') ||
        upper.contains('SECRET=')) {
      return false;
    }
    return true;
  }

  static List<AutocompleteSuggestion> suggest({
    required String rawPrefix,
    required List<String> localHistory,
    required List<String> remoteHistory,
    required List<SnippetItem> snippets,
    AutocompleteShellKind shellKind = AutocompleteShellKind.linuxPosix,
    int maxResults = 8,
  }) {
    final prefix = rawPrefix.trimLeft();
    if (prefix.length < 2) {
      return const [];
    }

    final isPosix =
        shellKind == AutocompleteShellKind.linuxPosix ||
        shellKind == AutocompleteShellKind.unixPosix;
    final lowerPrefix = prefix.toLowerCase();
    final hasSudoPrefix =
        isPosix && lowerPrefix.startsWith('sudo ') && prefix.length > 5;
    final afterSudo = hasSudoPrefix ? prefix.substring(5) : '';
    final lowerAfterSudo = afterSudo.toLowerCase();

    final seen = <String>{};
    final out = <AutocompleteSuggestion>[];

    void consider(
      String candidate,
      SuggestionSource source, {
      String? caption,
      bool preserveTrailingSpace = false,
    }) {
      if (out.length >= maxResults) return;
      final clean = preserveTrailingSpace
          ? candidate.trimLeft()
          : candidate.trim();
      if (clean.isEmpty) return;

      String? matchedFull;
      if (clean.length > prefix.length &&
          clean.toLowerCase().startsWith(lowerPrefix)) {
        matchedFull = clean;
      } else if (hasSudoPrefix &&
          clean.length > afterSudo.length &&
          !clean.toLowerCase().startsWith('sudo ') &&
          clean.toLowerCase().startsWith(lowerAfterSudo)) {
        matchedFull = '${prefix.substring(0, 5)}$clean';
      }

      if (matchedFull == null) return;
      if (!seen.add(matchedFull)) return;

      final suffix = matchedFull.substring(prefix.length);
      if (suffix.isEmpty) return;

      out.add(
        AutocompleteSuggestion(
          fullText: matchedFull,
          matchedPrefixLength: prefix.length,
          insertSuffix: suffix,
          source: source,
          caption: caption,
        ),
      );
    }

    // Tier 1: Local session history (newest first)
    for (final cmd in localHistory) {
      consider(cmd, SuggestionSource.localHistory);
      if (out.length >= maxResults) return out;
    }

    // Tier 2: User's Command Snippets (only for POSIX shells so Linux ops
    // snippets like `ss -tulpn` / `free -h` never pollute PowerShell or CMD)
    if (isPosix) {
      for (final s in snippets) {
        final cmd = s.command.trim();
        if (cmd.isEmpty) continue;
        if (!SnippetTemplate.hasVariables(cmd)) {
          consider(cmd, SuggestionSource.snippet, caption: s.title);
        } else {
          final idx = cmd.indexOf('{{');
          if (idx >= 4) {
            consider(
              cmd.substring(0, idx).trimRight(),
              SuggestionSource.snippet,
              caption: s.title,
            );
          }
        }
        if (out.length >= maxResults) return out;
      }
    }

    // Tier 3: Remote shell history (~/.zsh_history / ~/.bash_history)
    for (final cmd in remoteHistory) {
      consider(cmd, SuggestionSource.remoteHistory);
      if (out.length >= maxResults) return out;
    }

    // Tier 4: Shell-appropriate curated command dictionary
    final dictionary = switch (shellKind) {
      AutocompleteShellKind.linuxPosix => builtinCommands,
      AutocompleteShellKind.unixPosix => unixPosixCommands,
      AutocompleteShellKind.powershell => powershellCommands,
      AutocompleteShellKind.cmd => cmdCommands,
    };
    for (final cmd in dictionary) {
      consider(
        cmd,
        SuggestionSource.builtin,
        preserveTrailingSpace: true,
      );
      if (out.length >= maxResults) return out;
    }

    return out;
  }

  static const List<String> powershellCommands = [
    // Navigation & Files
    'Get-ChildItem',
    'Get-ChildItem -Force',
    'Get-Location',
    'Set-Location ',
    'New-Item -ItemType Directory ',
    'Remove-Item -Recurse -Force ',
    'Copy-Item -Recurse ',
    'Move-Item ',
    'Get-Content -Tail 50 -Wait ',
    'Get-Content -Raw ',
    'Select-String -Pattern ',
    'Test-Path ',
    'Expand-Archive -Path ',
    'Compress-Archive -Path ',
    'Clear-Host',

    // Processes, Services & System
    'Get-Process',
    'Get-Process | Sort-Object CPU -Descending | Select-Object -First 15',
    'Stop-Process -Id ',
    'Get-Service',
    'Restart-Service ',
    'Start-Service ',
    'Stop-Service ',
    'Get-Volume',
    'Get-CimInstance Win32_OperatingSystem',
    'Get-History',
    'Get-Command ',
    'Get-ChildItem Env:',

    // Networking & Diagnostics
    'Test-NetConnection ',
    'Get-NetTCPConnection -State Listen',
    'Get-NetIPAddress -AddressFamily IPv4',
    'Resolve-DnsName ',
    'Invoke-WebRequest ',
    'Invoke-RestMethod ',
    'ipconfig /all',
    'ipconfig /flushdns',
    'netstat -ano | findstr ',
    'ping -n 4 ',
    'tracert ',
    'nslookup ',

    // Windows Package Manager & SSH
    'winget search ',
    'winget install ',
    'winget upgrade --all',
    'ssh ',
    'scp ',

    // Docker & Kubernetes
    'docker ps',
    'docker ps -a',
    'docker logs -f --tail 100 ',
    'docker exec -it ',
    'docker images',
    'docker compose up -d',
    'docker compose down',
    'docker compose ps',
    'docker compose logs -f --tail 100',
    'kubectl get pods -A',
    'kubectl get svc -A',
    'kubectl logs -f ',

    // Git & Dev Toolchains
    'git status',
    'git pull',
    'git push',
    'git log --oneline -n 20',
    'git diff',
    'git branch -a',
    'git checkout ',
    'git stash',
    'git stash pop',
    'cargo test',
    'cargo build --release',
    'flutter test',
    'flutter analyze',
    'npm run ',
    'python ',
  ];

  static const List<String> cmdCommands = [
    // Files & Directories
    'dir',
    'dir /a',
    'dir /s /b ',
    'cd /d ',
    'mkdir ',
    'rmdir /s /q ',
    'copy ',
    'xcopy /e /i ',
    'robocopy ',
    'move ',
    'del /f /q ',
    'type ',
    'findstr /s /i ',
    'cls',
    'where ',
    'set',

    // System & Processes
    'systeminfo',
    'tasklist',
    'tasklist | findstr /i ',
    'taskkill /f /pid ',
    'whoami',
    'hostname',
    'ver',

    // Networking
    'ipconfig /all',
    'ipconfig /flushdns',
    'netstat -ano',
    'netstat -ano | findstr ',
    'ping -n 4 ',
    'tracert ',
    'nslookup ',
    'curl -I ',

    // SSH, Docker & Git
    'ssh ',
    'scp ',
    'docker ps',
    'docker ps -a',
    'docker compose up -d',
    'docker compose down',
    'git status',
    'git pull',
    'git push',
    'git log --oneline -n 20',
    'git diff',
    'git branch -a',
    'git checkout ',
  ];

  static const List<String> unixPosixCommands = [
    // Navigation & Files
    'ls -la',
    'ls -lh',
    'pwd',
    'mkdir -p ',
    'cp -r ',
    'mv ',
    'rm -rf ',
    'chmod +x ',
    'find . -name ',
    'du -sh *',
    'df -h',
    'tar -zxvf ',
    'tar -zcvf ',
    'unzip ',
    'rsync -avz --progress ',

    // Text & Logs
    'tail -f ',
    'tail -n 100 ',
    'head -n 50 ',
    'less +F ',
    'cat ',
    'grep -rn ',
    'wc -l ',
    'vim ',
    'nano ',

    // Processes & Networking (macOS / Cross-Unix)
    'ps aux | grep ',
    'top',
    'uptime',
    'uname -a',
    'kill -9 ',
    'pkill -f ',
    'lsof -i :',
    'ifconfig',
    'curl -I ',
    'curl -sSL ',
    'ping -c 4 ',
    'dig ',
    'nslookup ',
    'ssh ',
    'scp ',

    // Homebrew (macOS)
    'brew update && brew upgrade',
    'brew install ',
    'brew list',
    'brew services list',

    // Docker, Kubernetes & Git
    'docker ps',
    'docker ps -a',
    'docker logs -f --tail 100 ',
    'docker exec -it ',
    'docker compose up -d',
    'docker compose down',
    'docker compose ps',
    'kubectl get pods -A',
    'git status',
    'git pull',
    'git push',
    'git log --oneline -n 20',
    'git diff',
    'git branch -a',
    'git checkout ',
    'git stash',
    'git stash pop',
  ];

  static const List<String> builtinCommands = [
    // Navigation & Files
    'ls -la',
    'ls -lh',
    'll -h',
    'cd /var/log',
    'cd /etc/nginx',
    'pwd',
    'mkdir -p ',
    'cp -r ',
    'mv ',
    'rm -rf ',
    'chmod +x ',
    'chmod 644 ',
    'chmod 755 ',
    'chown -R ',
    'ln -s ',
    'find . -name ',
    'find / -type f -size +100M',
    'du -sh *',
    'du -h --max-depth=1',
    'df -h',
    'tar -zxvf ',
    'tar -zcvf ',
    'unzip ',
    'rsync -avz --progress ',

    // Text & Logs
    'tail -f ',
    'tail -n 100 ',
    'head -n 50 ',
    'less +F ',
    'cat ',
    'grep -rn ',
    'grep -i ',
    'sed -i ',
    'awk ',
    'wc -l ',
    'vim ',
    'nano ',

    // Systemd & Journalctl
    'systemctl status ',
    'systemctl restart ',
    'systemctl reload ',
    'systemctl start ',
    'systemctl stop ',
    'systemctl enable --now ',
    'systemctl daemon-reload',
    'systemctl list-units --type=service --state=running',
    'journalctl -u ',
    'journalctl -xeu ',
    'journalctl -n 100 -f',

    // Processes & System Resources
    'ps aux | grep ',
    'top',
    'htop',
    'free -h',
    'uptime',
    'uname -a',
    'lscpu',
    'lsblk',
    'dmesg -T | tail -n 50',
    'kill -9 ',
    'pkill -f ',
    'crontab -e',
    'crontab -l',

    // Networking & Diagnostics
    'ss -tulpn',
    'netstat -tulpn',
    'lsof -i :',
    'ip addr',
    'ip route',
    'curl -I ',
    'curl -sSL ',
    'wget ',
    'ping -c 4 ',
    'traceroute ',
    'dig ',
    'nslookup ',
    'ufw status verbose',
    'iptables -L -n -v',
    'nginx -t',
    'nginx -s reload',

    // Docker & Compose
    'docker ps',
    'docker ps -a',
    'docker logs -f --tail 100 ',
    'docker exec -it ',
    'docker images',
    'docker stats',
    'docker restart ',
    'docker stop ',
    'docker system prune -f',
    'docker compose up -d',
    'docker compose down',
    'docker compose ps',
    'docker compose logs -f --tail 100',
    'docker compose pull && docker compose up -d',
    'docker compose restart ',

    // Kubernetes
    'kubectl get pods -A',
    'kubectl get svc -A',
    'kubectl get nodes -o wide',
    'kubectl logs -f ',
    'kubectl describe pod ',
    'kubectl exec -it ',

    // Git
    'git status',
    'git pull',
    'git push',
    'git log --oneline -n 20',
    'git diff',
    'git branch -a',
    'git checkout ',
    'git stash',
    'git stash pop',

    // Packages (Debian/Ubuntu & RHEL)
    'sudo apt update && sudo apt upgrade -y',
    'sudo apt install -y ',
    'sudo dnf update -y',
    'sudo yum install -y ',
    'sudo -i',
    'sudo su -',
    'history | grep ',
    'screen -ls',
    'tmux ls',
    'tmux attach',
  ];
}
