---
title: \x1b[ is ambiguous and can be treated as alt + [ or incomplete sequence
status: todo
priority_value: 50
priority: medium
owner: aditya
created: 2026-02-06T18:21:33Z
tags: 
- event
---

- \x1b can be Escape key or start of a sequence.
- \x1b[ can be Alt + [ or start of CSI.
- \x1b[a can be malformed CSI, or Alt + [ then a.
There is no perfect decode without extra information

Need to figure out if i should treat a lone \x1b[ as incomplete or emit alt + [
If i get something like \x1b[a should maybe try to parse CSI and if it fials treat it as alt + [ ?
