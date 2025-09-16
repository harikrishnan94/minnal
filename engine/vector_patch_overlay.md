# Minnal Vector Patch Overlay (VPO)
*Continuation of **Minnal MVCC Using LSN** (see `mvcc-lsn-design.md`).*

---

## Glossary
- **VPO** — Vector Patch Overlay (this methodology).
- **RowCluster** — A sealed, compressed, PK-sorted cluster of 1,024–4,096 rows. Each RowCluster has an exclusive PK range.
- **Overlay** — Per-RowCluster positional patch list containing `(begin_lsn, end_lsn, col-mask, values, tombstone?)`.
- **Reseal** — Local rebuild of a single RowCluster when its overlay crosses thresholds.
- **WR (WAL Replay)** — The process of ingesting committed deltas from PostgreSQL WAL and applying them to RowClusters.
- **B (Boundary)** — Per-statement commit-LSN fence computed by the extension. The engine gates on **B** before scanning.

---

## 1) Overview
**Vector Patch Overlay (VPO)** keeps the base table as immutable **RowClusters**, each covering a unique PK interval. Each RowCluster may have a small **overlay** recording updated/deleted rows by primary key (with underlying column vectors stored compressed), plus inserts in its PK range. Queries stream the base vectors and apply overlays on the fly. Only when the overlay exceeds a small threshold do we **reseal** that RowCluster.

This guarantees vectorized, reload-speed scans on cold RowClusters, while WR appends tiny overlay entries on the ingest path. Heavy work (reseal) is off the critical path and strictly local.

---

## 2) Integration with MVCC-LSN Design
- **Commit stamping.** Overlays use the same `(begin_lsn, end_lsn)` semantics from the MVCC-LSN spec.
- **WR discipline.** Only committed WAL records are applied; aborts never reach overlays.
- **B-gating.** Queries execute only after WR has applied up to **B**. Visibility uses the same predicate `(begin ≤ B < end or end=0)`.

Thus VPO is a direct continuation of the MVCC LSN model.

---

## 3) Ingest Path (WR)
1. **Decode WAL.** The extension buffers changes until commit; at commit LSN **C**, it emits a batch.
2. **Route by PK.** Use a fence index (a versioned fence directory of RowCluster PK boundaries—e.g., B+tree or radix-ordered map—that maps a primary key to its owning RowCluster and allows ranges to grow/shrink via RCU/epoch swaps) → RowCluster.
3. **Append overlay entry.** Insert, delete, update all append constant-size entries to the overlay.
4. **Advance watermark.** Update `last_applied_commit_lsn` and per-table safe watermarks.

No RowCluster rewrite is on the ingest path.

---

## 4) Read Path
1. **Gate on B.** Ensure WR has applied ≥ B.
2. **RowCluster MVCC check.** Skip entire RowCluster if its `(begin_lsn, end_lsn)` exclude B.
3. **Overlay patching.** If overlay present:
   - Mask tombstoned rows.
   - Apply updates (latest ≤ B).
   - Merge inserts ≤ B.

Cold RowClusters have empty overlays → fast path identical to clean reload.

---

## 5) Pros
- **Reload-speed scans.** One MVCC check per RowCluster; overlays are tiny.
- **Low write amplification.** Ingest appends only; reseals are deferred.
- **Bounded complexity.** Reseal is local, no global merge scheduler.
- **Memory proportional to hot set.** Overlay size grows only with updates.

## 6) Cons
- **Hot RowClusters.** Require periodic reseal (decode → patch → re-encode).
- **Overlay tuning.** Must bound overlay size/age (e.g., 16–64 rows per 4K cluster).
- **Insert routing across fences.** New PKs must extend RowCluster ranges on reseal.

---

## 7) Why VPO meets the <50 ms SLO
- **WR appends are O(1).** Overlay inserts are constant-time, RAM-local.
- **Queries gate at B.** No need to wait for reseals; visibility parity comes from commit stamps.
- **Reseal is background.** Even if lagging, overlays stay small by threshold policy, keeping scan costs bounded.

Thus change-to-query latency is bounded by WR apply, not by compaction.

---

## 8) Edge Cases
1. **PK UPDATE.** Handled as DELETE(old PK) + INSERT(new PK). Different RowClusters may be touched.
2. **Insert + Delete in same txn.** Row has begin=end=C → invisible at any B.
3. **Streaming commits.** Only finalized commit batches reach overlays.
4. **2PC.** Effects applied only at COMMIT PREPARED, stamped at its LSN.
5. **Out-of-order commit vs snapshot.** B computation excludes in-progress XIDs; overlays follow LSN stamps.
6. **Gaps between RowClusters.** Insert routed to right neighbor; reseal adjusts fence.
7. **Multiple updates before reseal.** Overlay keeps entries in commit order; scan coalesces latest ≤ B.
8. **Wide updates.** Column mask limits work to touched columns.
9. **Joins.** Use safe_upto_lsn + heartbeats (from MVCC-LSN doc) to avoid stalls on tables with no changes.

---

## 9) Reseal Policy
- **Trigger:** overlay exceeds K (e.g., 16–64 rows) or age threshold (hundreds of ms).
- **Action:** rebuild that RowCluster only.
- **Scope:** strictly local; cold RowClusters remain intact.

---

## 10) Planner and Metrics
Expose:
- `rowcluster_skip_ratio`
- `avg_overlay_entries`
- `wr_lag_ms`

These enable the extension to cost plans with overlay presence in mind.

---

## 11) Conclusion
Vector Patch Overlay (VPO) is a pragmatic hybrid: immutable PK-sorted RowClusters, per-RowCluster overlays, and local reseal. It:
- Preserves reload-level scan performance.
- Keeps ingest latency <50 ms via WAL Replay.
- Localizes heavy work to hot RowClusters only.

This continues the MVCC-LSN model cleanly and avoids global complexity while staying faithful to PostgreSQL semantics.

