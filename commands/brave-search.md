---
description: "Web search via the Brave: title, URL, snippet per result. Works headless, can serve as backup or when searching Google-gated info. Do not use this if built-in web search tool works for your purpose."
argument-hint: <query terms, optionally followed by a result count>
allowed-tools: Bash
---

Search request (the command argument): **$ARGUMENTS**

# Brave web search

Run the search with the plugin's bin tool:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/brave-search "query terms" [count]
```

`count` defaults to 8; the API accepts up to 20. Output is plain text: numbered results, each with title, URL and snippet, ready to read without parsing.

## Credentials

The subscription token is read from `${XDG_CONFIG_HOME:-$HOME/.config}/magazines/config.ini`, section `[brave.com]`, key `api_key` — the same file browser-serialiser reads. A missing file or key is a fatal error naming what it needs; the fix is to copy `config.ini.example` to that path and fill in a Brave token from brave.com/search/api.

## Usage notes

- One invocation is one API request against the monthly quota; the free plan allows 2,000 requests per month at 1 request per second. Space bulk sweeps accordingly and watch for HTTP 429.
- Quote the whole query as a single argument. Brave supports `site:` and quoted-phrase operators.
- For Google-specific verticals (Flights, Maps, Hotels, review timelines) use the serpapi command instead.
