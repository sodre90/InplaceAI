# InplaceAI Tests

## Running

```bash
./Tests/run_tests.sh
```

## Why not `swift test`

XCTest and swift-testing both ship with Xcode, not with the Command Line Tools
toolchain this project is built against, so a SwiftPM `.testTarget` cannot be
compiled here. Instead `run_tests.sh` compiles the units under test directly
from `Sources/` together with `Tests/InplaceAITests/main.swift` and runs the
resulting binary.

The tests exercise the real production sources — nothing is stubbed or copied.
The trade-off is that the file list in `run_tests.sh` has to be maintained by
hand, and sources that use `Bundle.module` (the SwiftPM-generated resource
accessor) cannot be compiled this way.

If Xcode is installed later, this can be replaced by a `.testTarget` in
`Package.swift` and a plain `swift test`.

## Coverage

**`OpenAIService` — reasoning toggle.** The `Disable Reasoning` preference is
sent as `chat_template_kwargs.enable_thinking`, which must stay a JSON *boolean*:
llama.cpp rejects the string form with `invalid type for "enable_thinking"
(expected boolean, got string)`, and Qwen3-style Jinja templates test it with
`is false`. `reasoning_effort: "none"` is sent alongside it — only when reasoning
is disabled, since the parameter has no defined "on" value — to cover servers
whose chat template has no `enable_thinking` at all.

A leaked `<think>` block in the response is deliberately **not** stripped, and a
test pins that behaviour. Masking it would hide a future regression of the
toggle: if reasoning traces start appearing in rewritten text again, that should
be visible rather than silently cleaned up.

**`OpenAIService` — request shape and response handling.** Base URL resolution
(with and without a trailing slash, non-http schemes rejected), `Authorization`
header (Bearer token, omitted when the key is empty — local servers are commonly
keyless), model and `max_tokens` passthrough, prompt message construction, and
the `ServiceError` paths for non-2xx responses, blank content, and overlong
error bodies.

**`PromptLibrary`.** Preset title and ID lookup, whitespace tolerance, and the
fallback to the custom preset.

**`TextSelection`.** Browser bundle identifier detection and the
`requiresVerifiedPasteReplacement` rule.
