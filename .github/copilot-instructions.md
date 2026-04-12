# Project Guidelines

## Objective
AeroFlux exists to maximize real-world Hysteria2 and REALITY performance on VPS deployments. Default priority order is measurable throughput and streaming performance first, connectivity correctness second, and operational convenience third.

## Performance Rules
- Do not optimize for similarity with upstream or original repositories. Use them only as benchmarks.
- Prefer performance-first experiments with explicit measurement and single-variable changes.
- Treat kernel behavior, firewall path, conntrack, socket buffers, QUIC and UDP behavior, CPU scheduling, IRQ distribution, NIC offloads, and client core choice as first-class optimization surfaces.
- Avoid conservative-by-default changes unless the user explicitly asks for safety over speed.

## Change Strategy
- For performance work, preserve a known-good baseline and add a high-performance path or switch instead of deleting the fast path outright.
- Explain expected performance impact and how to validate it.
- If a change breaks connectivity, fix the break quickly, but continue the optimization effort with tighter isolation rather than abandoning the performance goal.
