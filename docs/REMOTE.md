# Remote 与 Ubuntu 接入

## 目标结构

```text
ChatGPT mobile Remote
        |
        v
ChatGPT desktop on Mac
        |
        v SSH
Ubuntu: cab -> official codex app-server
```

手机与 Mac 必须使用相同的 ChatGPT 账号和 workspace。Ubuntu 是 SSH 执行环境，不是手机直接配对的桌面 Remote 主机。

## 1. Ubuntu 准备

安装官方 Codex CLI 和 `cab`，确认 SSH 登录 shell 能找到二者。随后分别登录：

```bash
cab init
cab account add personal
cab account add work
cab login --device-auth personal
cab login --device-auth work
cab doctor
```

不要从 Mac 复制 `auth.json`。每台机器、每个账号都独立完成官方登录。

远程指定/无痕浏览器登录只接受并转发官方 Codex 当前使用的 localhost 1455 或 1457 回调端口；SSH 转发建立失败时登录会立即停止。

## 2. 固定 Remote 账号

```bash
cab remote use work
cab shim install --dir ~/.local/bin --force
```

确认 SSH 非交互登录也能找到 shim：

```bash
ssh ubuntu-host 'command -v codex && codex --version'
```

如果输出不是 `~/.local/bin/codex`，应修正 Ubuntu 登录 shell 的 `PATH`。不要修改系统 `/usr/bin/codex`。

## 3. Mac 添加 SSH 主机

在 `~/.ssh/config` 中使用具体别名：

```sshconfig
Host codex-ubuntu
  HostName server.example.com
  User ubuntu
  IdentityFile ~/.ssh/id_ed25519
```

先运行 `ssh codex-ubuntu` 验证密钥登录。然后在 ChatGPT 桌面版的 Settings > Connections > SSH 中添加该主机和项目目录。

## 4. 手机连接

在 Mac 桌面版启用 Control this Mac，使用手机 ChatGPT 扫描二维码。手机与 Mac 使用相同账号/workspace。手机选择 Mac 上保存的 Ubuntu SSH 项目即可在服务器环境中运行任务。

## 5. 切换 Ubuntu Codex 账号

先结束或移交当前任务，然后在 Ubuntu 执行：

```bash
cab remote use personal
```

断开并重新连接 SSH 项目。切换只影响新启动的官方 app-server，不会修改 ChatGPT 手机或 Mac 桌面版的登录账号。

## 会话继承边界

- 同一台 Ubuntu 主机跨 Codex 账号：可显式启用 `cab sessions enable`。
- Mac 与 Ubuntu 之间：使用官方 Handoff。
- 不要 rsync 正在使用的 `state_*.sqlite`、WAL 或 `auth.json`。
- 不要同时从两个账号写同一个会话；先结束原进程再恢复。

官方文档：https://learn.chatgpt.com/docs/remote-connections
