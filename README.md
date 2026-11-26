# Nexus SSH

跨五端现代极简 SSH 终端客户端（支持 **Windows / Linux / macOS / iOS / Android**），采用 **Flutter + Rust (`russh` + `russh-sftp`)** 架构构建，借鉴 Termius 清爽深色层级与移动端顺手交互，所有进阶能力均按需收纳在抽屉与弹层中，保持主界面纯粹干净。

## 核心特性

- **极简清爽工作区**：
  - 午夜炭蓝灰与薄荷绿柔和色阶，智能二合一「搜索 / `user@host` 快速直连」指令栏。
  - 桌面端精简侧栏与多会话并发标签页，内置**本地终端**（Windows 原生 ConPTY 自动发现 PowerShell 7 / Windows PowerShell / CMD / Git Bash / WSL；macOS / Linux 原生 POSIX PTY 支持 Zsh / Bash / Fish），支持与远程 SSH 会话同屏多标签切换、复用主题/片段库与命令联想；支持点击关闭时选择**退到系统托盘**（后台保活连接）或**直接退出**（支持记住选择并在左下角随时修改）。移动端提供全屏沉浸式终端、底部浮动活动终端胶囊条与立体触感快捷扩展按键栏（`ESC`、`TAB`、粘滞 `CTRL`/`ALT`、方向键、常用符号）。
  - `Aa` 终端外观面板：内置 4 套主题（Termius Midnight / Tokyo Night / Catppuccin Mocha / Clean Light）与字号无级缩放。
- **纯 Rust 异步 SSH 引擎与单连接多路复用 (`russh` + `russh-sftp`)**：
  - 支持密码认证（自动兼容 PAM `keyboard-interactive` 回退）与 SSH 私钥认证（`Ed25519`、`ECDSA`、`RSA-SHA2-512/256` 及加密口令）。
  - 支持从各平台原生文件选择器导入密钥文件、桌面端 `~/.ssh` 私钥自动发现快捷胶囊、密钥指纹与加密状态实时校验，以及按需展开的手动文本粘贴。
  - **SSH 通道多路复用**：交互式 PTY 终端、SFTP 文件管理与服务器监控共享同一条加密 SSH 连接，不额外发起握手、不污染终端输入提示符与命令历史。
- **多层次安全加固（只写不回显 + 应用锁/生物识别 + 静态加密 + TOFU）**：
  - **凭据只写不回显与内存零化 (`zeroize`)**：已保存的服务器密码、SSH 私钥、私钥口令与 WebDAV 密码绝不跨 FFI 回传至 UI 层明文展示；编辑主机或 WebDAV 时仅展示安全状态占位，留空即保持原凭据不变，所有认证与 `sudo` 一键填入均在 Rust 内部完成并在断开后自动擦除内存。
  - **跨平台应用锁与生物识别 + 隐私遮罩**：本地应用密码采用 `PBKDF2-HMAC-SHA256`（200,000 轮 + 随机盐）哈希校验；支持移动端（iOS 面容/触控 ID、Android 指纹/面部识别）与桌面端（Windows Hello、macOS 触控 ID、Linux 主密码回退）快速解锁，支持启动锁定、切后台/托盘超时自动锁屏、手动一键锁屏及多任务切换隐私遮罩。
  - **本地敏感凭据静态加密**：主机密码、私钥、口令及 WebDAV 密钥落盘全部采用 `AES-256-GCM` 密文存储；在 Windows 上主密钥由系统级 **DPAPI** (`CryptProtectData`) 硬件/当前用户账户保护，Unix/移动端使用 `0600` 受限主密钥保护，并支持旧版明文配置无感平滑迁移。
  - **`known_hosts` TOFU 校验与可视化管理**：首次连接远程主机弹出 `SHA256` 公钥指纹确认框，密钥变更时醒目告警；安全中心内置 `known_hosts` 检索与移除管理界面。
  - **高危操作二次确认 & 剪贴板自动清空**：执行 `rm -rf`、`mkfs`、`dd of=/dev/...`、`shutdown`/`reboot`、`DROP TABLE` 等破坏性命令片段前弹出红色二次确认；可选开启敏感剪贴板 30 秒自动清空。
  - **WebDAV 明文风险强提示**：未设置 AES-256 端到端加密口令时，同步配置界面醒目提示并在上传前二次确认。
- **按需展开的三合一会话抽屉（SFTP / 状态监控 / 命令片段）**：
  - **可视化 SFTP 文件管理器**：支持远程目录浏览、路径直跳、64 KiB 流式分块上传/下载实时进度条、新建文件夹、重命名、递归删除，以及可视化 `rwx` + 八进制权限修改（`Chmod`）。
  - **服务器状态轻量监控**：实时采集并可视化展示主机名、内核与运行时长、CPU 使用率（双采样差值计算）与 LoadAvg、物理内存与 Swap 占用、磁盘挂载点空间以及网卡实时上下行速率（RX / TX）。
  - **命令片段库（Snippets）**：支持常用运维指令分类检索、增删改查，以及 `{{变量名}}` / `{{变量名:默认值}}` 动态变量模板（执行前自动弹窗填写与实时预览）；活动终端内一键发送执行（可选自动回车），未连终端时一键复制。
  - **智能命令提示 & `sudo` 密码一键填入**：融合本机历史、远端 Shell 历史只读拉取（`~/.zsh_history` / `~/.bash_history`）、命令片段库与高频 Linux 词典，无匹配或进入 `vim`/`top` 全屏程序时自动隐身；检测到 `sudo` 密码提示时在底部浮出手动确认一键填入胶囊，绝不自动盲发密码。
- **跨平台 WebDAV 云同步（主机 + 命令片段）**：
  - 兼容坚果云、Nextcloud、ownCloud、Alist/OpenList、群晖 WebDAV 等服务。
  - 支持主机配置与命令片段库的**双向智能合并**（基于时间戳与删除墓碑）、单向覆盖上传/拉取、启动及变更后后台静默自动同步。
  - 可选开启 **`AES-256-GCM` 端到端加密**（`PBKDF2-HMAC-SHA256` 密钥派生），网盘不留明文凭据；桌面端文件私钥同步后自动内嵌内容，跨端即连。

## 开发与构建命令

```bash
# 运行 Rust 单元测试、SSH2/SFTP/TOFU 回环测试与 WebDAV 加密同步测试
cargo test --manifest-path rust/Cargo.toml

# 静态代码检查与 Flutter 组件测试
flutter analyze
flutter test

# Windows 桌面端运行 / Release 打包
flutter run -d windows
flutter build windows --release

# Android 打包
flutter build apk --release --split-per-abi
```
