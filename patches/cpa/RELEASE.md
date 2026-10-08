基于 CLIProxyAPI v8.0.21（提交见 version.json），保留上游许可证。

- 修正原生 Responses API-key 模型的 `/v1/models` 归属：DeepSeek 官方域名返回 `deepseek`，其他网关返回域名；OpenAI 官方端点及默认端点仍返回 `openai`。
- 模型可用 `owned-by` 显式声明供应商，适合自定义网关。
- 不改变 Codex/Responses 执行器、请求协议、模型别名和路由优先级。
- 同时测试旧配置、v8 分组配置、接口认证、原生 Responses 转发和 v0 管理接口。

`.tar.gz` 是内核安装包，供 MacCLIProxyAPI 的“本地安装包”使用。不是桌面应用安装包。
