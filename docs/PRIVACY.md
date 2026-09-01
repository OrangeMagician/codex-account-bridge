# 隐私说明

## 不会进入 Git 的数据

- Codex `auth.json`、`config.toml`、账号目录与会话数据库。
- CAB Desktop 保存的服务器显示名称、SSH 主机或别名。
- SSH 密钥、环境变量文件以及 `*.local.json`、`*.private.json` 本地配置。
- CAB CLI 的用户配置：`~/.config/codex-account-bridge/config.json`。

仓库 `.gitignore` 对上述常见文件名设置了防误提交规则。提交前仍应运行隐私扫描，因为 Git 无法识别粘贴到源码或文档中的任意秘密。

## 本地保存内容

CAB Desktop 使用 macOS UserDefaults 在本机保存服务器列表、当前选择、额度刷新间隔、“切换时保留项目与会话”偏好和它上次用于启动桌面客户端的 CAB 账号名称。每条服务器记录只包含随机 ID、用户填写的显示名称和 SSH 主机字符串。应用不保存 SSH 密码或私钥，也不读取 Codex 令牌内容。

CAB CLI 的账号配置只保存账号名称和各自 `CODEX_HOME` 路径。判断登录状态时直接执行官方 `codex login status`；如果凭据文件存在，诊断只检查它是否为安全权限的普通文件，不读取其内容。凭据位于 macOS 钥匙串时同样不读取钥匙串内容。

## 网络边界

- CAB Desktop 不包含遥测、崩溃上传、更新检查或自建后台。
- 管理远程服务器时，它直接启动系统 `/usr/bin/ssh`，连接用户明确选择的 SSH 主机。
- 从 SSH 配置导入时只在本机读取 `~/.ssh/config` 及其 `Include` 配置，提取具体 `Host` 别名；不打开 `IdentityFile` 指向的私钥，也不保存其路径或主机解析详情。
- 指定浏览器和无痕登录只接受官方 Codex app-server 返回的 OpenAI/ChatGPT HTTPS 授权地址，并直接启动用户选择的已安装浏览器；PKCE、本地回调、凭据保存和刷新仍由官方 Codex 负责，应用不读取浏览器 Cookie、密码、令牌或历史。
- 额度查询通过所选账号的官方 Codex app-server 发起，只保留套餐类型、额度窗口、重置时间和可选 Credits/消费上限等展示字段；不输出或持久化账号邮箱、令牌和额度重置凭据 ID。桌面端按目标机器分别在内存中缓存查询结果，间隔由用户设置。
- 本机桌面账号切换只会结束官方 Codex/ChatGPT 桌面进程，并以用户明确选择的账号目录作为 `CODEX_HOME` 重新启动其已安装的官方可执行文件；不会复制、解析或上传任何凭据。操作必须经过确认，并会中断未完成的桌面任务。
- 用户开启“切换时保留项目与会话”后，CAB 会在 Codex 完全停止时合并本地 `sessions/` 与 `archived_sessions/`，并同步经过审核的项目与 SSH 引用、完整消息投影、会话目录与动态工具记录、会话标题与客户端绑定、长期目标、已生成记忆、提示历史、未发送草稿、个人技能、规则、提示模板、附件、生成图片及导入内容。目标 JSON、目录和 SQLite 文件会分别备份；SQLite 只合并经过列结构校验的白名单表，保留其他表和账号自己的处理水位，并在最后重置 `state_5.sqlite` 的 `backfill_state` 让官方客户端补建索引。CAB 不解释、展示或输出被迁移的消息、草稿、目标、记忆或附件内容；SSH 私钥、`auth.json`、`config.toml`、账号身份、插件与 OAuth、浏览器/Computer Use 配置、设备与远程控制授权、日志、审批、沙箱和项目 trust 选择始终不从其他账号复制。
- 切换账号前发现非桌面 Codex 进程时，CAB 读取可执行文件路径，并只从进程参数中提取 UUID 格式的候选线程 ID；若该 ID 能在账号自己的官方索引中匹配，则显示官方 `name/title`。完整进程参数不会显示或保存。用户可以取消，或明确要求只向列出的 PID 发送正常退出信号后继续切换。
- 除上一条用于匹配可见标题的 UUID 提取外，会话迁移预检只枚举名为 `codex` 的进程并读取其可执行文件路径，用于区分桌面端、编辑器扩展和 CLI；不读取提示内容或环境变量，也不持久化完整路径。
- 登录和运行模型仍由官方 Codex CLI 直接连接其官方服务；CAB 不代理或观察模型流量。
- 项目不提供服务器列表、令牌、会话或配置的云同步功能。

## 开源发布检查

发布前至少检查：

```bash
git status --short
git diff --check
git grep -n -I -E 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|sk-[A-Za-z0-9_-]+'
find . -type f \( -name auth.json -o -name config.toml -o -name '*.pem' -o -name '*.key' \)
```

发现隐私数据时不要仅依赖后续删除；如果已经提交或推送，应立即撤销相关凭据并清理 Git 历史。
