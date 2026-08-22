# Upstream issue draft — CLIProxyAPI

Ready to file at https://github.com/router-for-me/CLIProxyAPI/issues

---

**Title:** chat→Responses stream translator finalizes items on empty `delta.tool_calls: []`

**Version:** v7.2.119 (darwin/arm64)

## Summary

In the Chat Completions → Responses streaming translator, the tool-call branch is entered
whenever `delta.tool_calls` is present and is an array, without checking that the array is
non-empty. Providers that emit `"tool_calls": []` on every chunk therefore get their
reasoning and message items closed once per chunk.

Two user-visible symptoms follow:

1. `response.output_text.delta` events continue to arrive **after** `response.output_item.done`
   for that item. Strict clients (Codex) render only the text delivered before the item closed,
   so a long reply appears truncated to its first few characters.
2. Each `reasoning_content` delta becomes its own reasoning item
   (`output_item.added` → delta → `output_item.done`), so the thinking pane replaces its content
   word by word instead of appending.

## Location

`internal/translator/openai/openai/responses/openai_openai-responses_response.go:523`

```go
// tool calls
if tcs := delta.Get("tool_calls"); tcs.Exists() && tcs.IsArray() {
    if st.ReasoningID != "" {
        stopReasoning(st.ReasoningBuf.String())
        st.ReasoningBuf.Reset()
    }
    // Before emitting any function events, if a message is open for this index,
    // close its text/content to match Codex expected ordering.
    if st.MsgItemAdded[idx] && !st.MsgItemDone[idx] {
        ...
```

The guard checks existence and type but not length.

## Reproduction

A fake OpenAI-compatible upstream served identical reasoning and text content under four chunk
shapes, varying only whether each chunk carries an empty `finish_reason` and/or an empty
`tool_calls`. Request: `POST /v1/responses`, `stream: true`, `reasoning.summary: auto`.

Upstream chunk (the `fake-emptytools` variant):

```json
{"id":"probe","object":"chat.completion.chunk","created":1785899496,"model":"fake-emptytools",
 "choices":[{"index":0,"delta":{"content":"我是","tool_calls":[]},"logprobs":null}],"usage":null}
```

Observed client event order (`+`/`-` = `output_item.added`/`.done`, `rsn`/`txt` = deltas):

| upstream chunk shape | event order |
|---|---|
| no extra keys | `+rea rsn rsn rsn -rea +mes txt txt txt txt -mes` |
| `finish_reason: ""` | `+rea rsn rsn rsn -rea +mes txt txt txt txt -mes` |
| `tool_calls: []` | `+rea rsn -rea +rea rsn -rea +rea rsn -rea +mes txt -mes txt txt txt` |
| both | `+rea rsn -rea +rea rsn -rea +rea rsn -rea +mes txt -mes txt txt txt` |

Empty `finish_reason` is harmless; empty `tool_calls` alone reproduces both symptoms.
Note the trailing `txt txt txt` after `-mes` in the broken rows.

## Suggested fix

```go
if tcs := delta.Get("tool_calls"); tcs.Exists() && tcs.IsArray() && len(tcs.Array()) > 0 {
```

An empty array carries no tool-call information, so ignoring it is safe for every provider.
For reference, tt-switch applies the same guard in its Rust translator:

```rust
if let Some(tool_calls) = delta.get("tool_calls").and_then(|v| v.as_array())
    .filter(|calls| !calls.is_empty())
```

## Affected provider

An OpenAI-compatible gateway serving `deepseek-*`, `kimi-*` and similar models was observed
emitting `"tool_calls": []` on every chunk.

## Local workaround

Route the affected models through a leg that skips the Chat Completions → Responses stream
translator entirely (e.g. a native Responses-speaking upstream), which sidesteps the bug without
touching CLIProxyAPI.
