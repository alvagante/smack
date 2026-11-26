# Summary tile details and arrangement

2×2 CPU, GPU, Memory, Network and Disk Activity tiles show up to five Applications ranked by their current metric. Disk Activity ranks combined read and write rates; Network ranks combined receive and send rates. Missing GPU or network samples are omitted, never treated as zero. Rows open Application details.

Documents, Projects, Dev servers, Applications, Development Environments and Homebrew use a twelve-entry limit for 2×2 tiles. Insights retains five CPU consumers and five writers from the history results already read for its digest, plus bounded per-program highlights. No extra queries are made for expanding the tile.

Arrange uses a local drag gesture in grid coordinates. The dragged tile follows the pointer; other tiles preview the order. A twelve-point movement threshold and an inset target region prevent reflow from repeatedly reordering under a stationary pointer. The preview lives in memory. Settings are written only on a completed drop that changes the order; cancellation discards the preview. No drag polling or timers are added.

## Resource cost

CPU, memory, network and disk rankings reuse the latest Process Snapshot. At most five rows per resource tile and twelve rows per list tile are rendered initially. Insights retains at most ten additional named values in its existing cached digest. Drag state holds one order and frame map for the visible tile count, and exists only during Arrange.

GPU's 2×2 tile requests the existing GPU client reader while on screen, balanced on disappearance or resizing. The scheduler still gates sampling on Panel visibility and uses its existing live interval. This adds one IORegistry client walk per live interval while requested, no subprocesses, no new timers and no new history writes. Its existing per-process rate and bounded recent-point buffers are reused. Smaller GPU tiles request no per-process collection.

An isolated optimized build of the unchanged GPUProcessReader was measured locally on 2026-11-10 using 100 consecutive scans:

| Measure | Result |
| --- | --- |
| Mean wall time per scan | 0.926 ms |
| p95 wall time per scan | 1.270 ms |
| CPU time per scan | 0.923 ms |
| Probe process peak RSS growth | 880 KiB |

The RSS figure includes initialization and allocations in the isolated probe and does not measure retained app memory. At a two-second interval, the measured CPU time corresponds to approximately 0.046% of one core. Registry size and driver behavior affect these figures. This microbenchmark does not replace the required ten-minute release comparison against main with the Panel closed and open; that comparison remains pending.

Validation covers ranking and missing samples, the five-row cap, longer list limits, expanded insight entries, live order changes, pointer offset compensation, stationary-pointer stability and rendered tile shapes at multiple widths.
