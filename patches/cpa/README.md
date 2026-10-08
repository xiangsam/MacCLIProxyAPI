# CPA 原生 Responses 模型归属补丁

官方 v8.0.21 的 `buildCodexConfigModels` 将 API-key 模型归属写死为 `openai`。
此补丁只调整模型元数据，保留原生 Responses 执行器。OAuth 订阅不受影响。

`version.json` 锁定上游提交、Go 版本和补丁版本，`App/Resources/core-version.txt` 必须一致。
构建脚本校验提交和补丁可应用性；升级上游时必须重新审查、运行测试并增加 `-mac.N`。
不要将补丁静默应用于未经验证的上游版本。

```sh
./scripts/build-patched-core.sh arm64
# 在 Intel macOS runner 上：
./scripts/build-patched-core.sh amd64
```

构建执行归属单测及实际 HTTP 冒烟测试，产物在 `dist/`，包含原许可证与来源元数据。
`patched-core.yml` 可单独触发，也作为桌面应用 Release 的前置任务。
内核发布标签为 `cpa-v<version>`，不占用桌面应用的 latest Release。
已经发布的补丁版本不可覆盖，改动需要增加版本号。

原生 Responses 的模型行支持可选 `owned-by`；未提供时按 endpoint 判定：
OpenAI/ChatGPT 官方域名为 `openai`，DeepSeek 官方域名为 `deepseek`，其他网关使用完整域名。
模型归属与执行器类型分别维护，不能为了显示 DeepSeek 而切换成 Chat Completions。
