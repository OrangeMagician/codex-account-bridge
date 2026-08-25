# 隐私说明

## 不会进入 Git 的数据

- Codex `auth.json`、`config.toml`、账号目录与会话数据库。
- CAB Desktop 保存的服务器显示名称、SSH 主机或别名。
- SSH 密钥、环境变量文件以及 `*.local.json`、`*.private.json` 本地配置。
- CAB CLI 的用户配置：`~/.config/codex-account-bridge/config.json`。

仓库 `.gitignore` 对上述常见文件名设置了防误提交规则。提交前仍应运行隐私扫描，因为 Git 无法识别粘贴到源码或文档中的任意秘密。

## 本地保存内容

CAB Desktop 使用 macOS UserDefaults 在本机保存服务器列表和当前选择。每条记录只包含随机 ID、用户填写的显示名称和 SSH 主机字符串。应用不保存 SSH 密码或私钥，也不读取 Codex 令牌内容。

CAB CLI 的账号配置只保存账号名称和各自 `CODEX_HOME` 路径。判断登录状态时仅检查 `auth.json` 是否为安全权限的普通文件，不读取其内容。

## 网络边界

- CAB Desktop 不包含遥测、崩溃上传、更新检查或自建后台。
- 管理远程服务器时，它直接启动系统 `/usr/bin/ssh`，连接用户明确选择的 SSH 主机。
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
