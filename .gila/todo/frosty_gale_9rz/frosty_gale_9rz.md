---
title: Fixed stdin buffer can lead to incomplete termainl sequence parsing
status: todo
priority_value: 50
priority: medium
owner: aditya
created: 2026-02-06T00:30:31Z
tags: 
- terminal
---

This buffer is fixed which means if we get a large stdin we will block. We could use a ring buffer
or we could keep shifting the buffer discarding old data. But for now if write_head == buf.len we will break
and discard the data we read so far and next time we will start readign from incomplete data.

We should probably persist the buffer in the terminal to continue reading next time
