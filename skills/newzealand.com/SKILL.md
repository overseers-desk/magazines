---
name: newzealand.com
description: "Horse riding operators listed on New Zealand's official tourism site: the full card set from the Horse Riding page, including the ones behind its lazy scroller."
allowed-tools: Bash
---

# newzealand.com horse riding

Tourism New Zealand's own operator listing for horse riding. Public, no login.

```bash
browser-serialiser newzealand.com/pub-horse-riding-capture
```

`result.card_count` is how many operator cards the page held once it had finished loading them, and `result.cards_html` is the showcase container's markup, one block carrying every card.

## How the page works

The operators sit in a horizontal card scroller that writes a card's markup only when the scroller reaches it, so a plain dump of the first DOM holds a handful of the set. The run pushes the scroller to its end ten times, settling two seconds each round, and reads the container afterwards.
