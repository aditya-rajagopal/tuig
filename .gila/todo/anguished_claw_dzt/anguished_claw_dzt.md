---
title: If \x1b is a lone byte we cant tell if it is an incomplete sequence or a part of a continuation
status: todo
priority_value: 50
priority: medium
owner: aditya
created: 2026-02-05T22:22:08Z
tags: 
- bug
- event
---

1. If parser sees lone ESC (data.len == 1 and byte 0x1B) with no carry yet:
- keep it in carry
- set esc_retry_pending = true
- return without emitting event

2. On the next pollEvents call:
- if carry is still exactly lone ESC and esc_retry_pending == true, emit Esc key event and consume
it
- clear esc_retry_pending

3. If any extra byte arrives before step 2:

- parse normally as sequence
- clear esc_retry_pending

Currently we will just parse the lone ESC as a sequence and emit Esc key event.
Important: esc_retry_pending and carry must be stored on Terminal (persistent across calls), not
local in pollEvents.
