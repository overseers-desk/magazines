---
name: justgo.com
description: "Accredited riding centres from the JustGo Coach and Club Finder, the weblet behind Pony Club Australia's Find An Accredited Riding Centre page."
allowed-tools: Bash
---

# JustGo Coach and Club Finder

Pony Club Australia's "Find An Accredited Riding Centre" page is an embedded JustGo weblet, so the centres are JustGo's data served from a JustGo origin. Public, no login.

```bash
browser-serialiser justgo.com/pub-find-riding-centres
```

`result` is one entry per captured reply, each with the URL, the HTTP status, and the reply body holding the centre records.

## Why this is filed under justgo.com

A skill is leased the site its directory names, and a capture that lands anywhere else is refused. Filed under `ponyclubaustralia.com.au` this work is stopped the moment the weblet's own origin answers, which is what happens when the pony club's page is treated as the host. The finder is read where it lives.

## How the page works

The weblet's first DOM carries no centres. Results arrive as POST replies to `WidgetService.mvc/ExecuteWidgetCommandAlt`, so the run captures matching replies for 45 seconds rather than scraping the rendered page.
