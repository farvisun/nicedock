# AI usage widget: new sources

The `aiUsage` tile for each source, rendered offscreen from the release build with the sample data of the
reference scene. The renders use no account, no Keychain and no network:

```sh
scripts/build-app.sh release
build/CoolDock.app/Contents/MacOS/CoolDock --render docs/verification/ai-usage/en \
  aiUsage,aiUsage-opencode,aiUsage-antigravity,aiUsage-cursor,aiUsage-copilot,aiUsage-gemini,aiUsage-perplexity,aiUsage-xai,aiUsage-zai \
  --scene reference --lang en --style darkGlass     # same with --lang fa → fa/
```

`aiUsage-<provider>` sets the widget's `provider` and seeds `ConnSample`'s shape for that source.
`aiUsage.png` is the unchanged Claude Code reference tile: `scripts/pixel-diff.sh aiUsage` → 99.75 % (fuzz 8 %).

| Source | Headline | Third line | English | Persian |
| --- | --- | --- | --- | --- |
| Claude Code (reference) | tokens | ≈ cost · input | ![](en/aiUsage.png) | ![](fa/aiUsage.png) |
| OpenCode (local DB) | tokens | ≈ OpenCode's cost · input | ![](en/aiUsage-opencode.png) | ![](fa/aiUsage-opencode.png) |
| Antigravity (agy CLI) | quota left, tightest bucket | model group · reset time | ![](en/aiUsage-antigravity.png) | ![](fa/aiUsage-antigravity.png) |
| Cursor (Admin API) | tokens | billed cost · input | ![](en/aiUsage-cursor.png) | ![](fa/aiUsage-cursor.png) |
| GitHub Copilot | premium requests (or AI credits) | billed amount | ![](en/aiUsage-copilot.png) | ![](fa/aiUsage-copilot.png) |
| Gemini API (Cloud Monitoring) | requests | — | ![](en/aiUsage-gemini.png) | ![](fa/aiUsage-gemini.png) |
| Perplexity (Analytics API) | credits | queries | ![](en/aiUsage-perplexity.png) | ![](fa/aiUsage-perplexity.png) |
| Grok / xAI | spend (USD) | — | ![](en/aiUsage-xai.png) | ![](fa/aiUsage-xai.png) |
| GLM / Z.ai | tokens | top model | ![](en/aiUsage-zai.png) | ![](fa/aiUsage-zai.png) |

The numbers are sample values, not live data. How each source gets its data, and what was checked live, against
documentation or on this Mac's own files, is in [`../providers.md`](../providers.md) (Cursor through Z.ai, and
"AI usage: local sources").
