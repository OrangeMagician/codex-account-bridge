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

在 Ubuntu 明确选择新连接使用的账号：

```bash
cab remote use personal
```

这条 CLI 命令只影响新连接。桌面界面的“切换远程 Codex”会在确认后自动断开旧账号的桌面连接并等待官方客户端重连。顺序是保存账号、验证新官方连接、正常退出已确认的旧桌面 PID、核验实际重连进程；不会先退出再保存而让重连抢回旧账号。活动任务可能中断，确认前应保存工作。已经选中的账号也可用“重新连接并应用”修复旧连接。正确账号连接、普通 CLI 和智能体独立绑定保持不变，不会强制结束进程。

开启会话共享后，切换和新连接启动前会按落盘事件时间修正已有线程的历史路径，并在线备份各账号自己的索引。同时补齐已验证共享历史的官方会话记录，保留非项目会话、置顶、分组归属及有效标题，防止名称退化为目录路径。已有记录的审批、沙箱、归档和运行设置保持不变；补齐的记录保留同一会话原有设置，不改默认权限或项目信任。历史文件不会覆盖或拼接。系统需要 Python 3.9+ 标准库 sqlite3。已有索引显示旧历史时可运行 `cab sessions repair-index --json`，不需要结束任务。

## 会话继承边界

- 同一台 Ubuntu 主机跨 Codex 账号：可显式启用 `cab sessions enable`。
- Mac 与 Ubuntu 之间：使用官方 Handoff。
- 不要 rsync 正在使用的 `state_*.sqlite`、WAL 或 `auth.json`。
- 不要同时从两个账号写同一个会话；先结束原进程再恢复。

官方文档：https://learn.chatgpt.com/docs/remote-connections

### 验证新连接与已有连接

账号选择保存后，CAB 使用服务器公开的 `codex app-server` 入口建立一次只读连接，
核对官方 `initialize` 返回的 `codexHome` 和 `account/read` 的登录状态。
可以手动执行：

```bash
cab remote verify --account work --json
```

`fresh_connection_verified` 只表示新连接已经使用所选账号。
`desktop_connections` 列出实际官方桌面监听进程的 PID 与账号目录，`desktop_connections_checked` 表示检查完整；CAB shim 的继承环境不会冒充官方进程账号。独立智能体的 stdio 服务不算桌面连接。只有已确认的旧桌面 PID 被退出，所有新连接使用目标目录后，桌面界面才记录“桌面连接已验证”；等待超时、检查不完整或只剩零个连接都不会冒充重连成功。

可只读检查现有连接，不启动临时验证服务：

```bash
cab remote connections --account CKF --json
```

验证命令不发送模型请求、不返回账号邮箱或凭据，也不停止已有任务。
