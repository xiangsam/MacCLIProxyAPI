# Known Issues / Backlog

## Codex：统一会话历史后 `thinking_signature_invalid`

**现象**：开启「统一 Codex 会话历史」并迁移 `openai → custom` 后，恢复旧会话可能报：

```text
thinking_signature_invalid / encrypted content could not be verified (rs_…)
```

**原因**：迁移只改 `model_provider` 标签；会话 JSONL 里仍有绑定原账号/上游的 `encrypted_content` reasoning 项，CPA 无法解密。

**处理**：

- 智能体页 →「清理加密思考…」：备份后去掉带 `encrypted_content` 的 reasoning / compaction 行
- 或开新会话

**方案说明**：优先 App 侧清洗会话文件，而不是依赖 CPA 插件。CPA 目前主要是把该错误归类为 `thinking_signature_invalid`，没有现成的「Codex encrypted_content 清洗」官方插件；请求期过滤也治不好磁盘上的历史。
---

## 远程切 profile 后 `/model` 仍是旧列表（`codex app-server` 缓存目录文件）

远程 Codex 的可选模型来自 `model_catalog_json` 指向的目录文件。切换 profile 时
`RemoteAgentConfigurator.applyCodex` 会把 `config.toml` 和目录文件一起写过去，
磁盘状态是对的，但 `/model` 可能还是上一个 profile 的列表。

实测（`dev` 主机）：目录文件已是 `Codex订阅` 的 `[gpt-5.6-sol, gpt-5.6-luna]`，
`model_catalog_json` 也是正确的远程绝对路径，而 `codex app-server` 已经连续运行
19 小时——它只在启动时解析一次目录文件。

原先提示写的是「需重连远程 Codex 会话才会生效」，但这条建议在这里不成立。看它自己的
启动命令：

```
(pkill -9 -U "$(id -u)" -f 'codex.*[d]esktop-ssh-websocket-v0.sock' || true) && nohup codex ... app-server --listen unix:// &
```

新连接确实会先尝试 `pkill` 旧的，但匹配的是 `desktop-ssh-websocket-v0.sock`，
而实际进程的命令行是 `app-server --listen unix://`，两者对不上；加上 `nohup` 脱离
终端，于是它能跨越任意多次重连一直活着。

解法：写完配置后检测守护进程，命中就弹窗询问是否重启（结束进程，下次连接自动拉起）。

**踩坑**：`pkill -f` 匹配的是整条命令行，所以模式必须写成 `codex.*[a]pp-server`。
写成 `app-server` 会连执行 `pkill` 的那条 SSH 命令自身一起匹配，先把连接杀掉——
调试时踩了两次。`[a]pp` 让正则要找的三个字符 `app` 在自己的命令行里并不连续。
由 `testAppServerPatternSpareOwnCommandLine` 钉住。
