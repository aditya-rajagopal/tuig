---
title: If we get an invalid grapheme id we return false in renderer. Can this be better
status: done
priority_value: 50
priority: medium
owner: aditya
created: 2026-02-05T22:30:09Z
completed: 2026-02-12T07:32:05Z
tags: 
- renderer
---

```zig
    } else if (old_cell.tag == .grapheme) {
        const old_id: t.GraphemeBuffer.GraphemeIndex = @truncate(@as(CellSize, @bitCast(old_cell)));
        const new_id: t.GraphemeBuffer.GraphemeIndex = @truncate(@as(CellSize, @bitCast(new_cell)));
        const old_grapheme = back_bufer.grapheme_buffer.get(old_id) orelse return true;
   -->  const new_grapheme = self.grapheme_buffer.get(new_id) orelse return false;
        return !std.mem.eql(u8, old_grapheme, new_grapheme);
    } else {
```
