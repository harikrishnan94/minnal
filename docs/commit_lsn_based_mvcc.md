# Minnal MVCC Using PostgreSQL Commit LSN — Design and Implementation

Status: Draft
Scope: MVP targets single‑statement READ COMMITTED (autocommit) offload. This document also captures the general approach for future multi‑statement transactions.

Goals
- Achieve PostgreSQL‑equivalent row visibility for offloaded statements while keeping the Minnal engine independent of PostgreSQL internals.
- Use a purely LSN‑based MVCC in the engine (commit‑LSN intervals). The engine never manipulates or interprets PostgreSQL TXIDs.
- The PostgreSQL extension computes a per‑statement visibility horizon B (a commit‑LSN fence) from the statement’s snapshot and WAL metadata, and transmits B with the plan to the engine.
- The engine blocks execution until last_applied_commit_lsn ≥ B, then evaluates row version visibility via a simple begin_lsn/end_lsn predicate.

Non‑Goals (MVP)
- Offloading multi‑statement transactions, REPEATABLE READ, and SERIALIZABLE. These are routed to PostgreSQL. A forward‑looking approach for multi‑statement is documented in the Appendix.

Contents
0. Terminology and invariants
1. Background and rationale
2. Engine MVCC model (LSN‑interval / CSN‑like)
3. Ingest semantics and data stamping
4. Visibility evaluation at query time
5. Extension algorithm: snapshot → boundary B
6. Code‑level pseudocode (engine and extension)
7. Worked examples (expanded)
8. Edge cases and nuances
9. Failure, recovery, and checkpoints
10. Testing strategy
11. Operational considerations and metrics
12. Alternatives (when exact parity is not required)
13. Appendix: towards multi‑statement isolation
14. References to PostgreSQL internals (local tree)

---

## 0) Terminology and invariants

- XID: PostgreSQL transaction ID, possibly with an epoch to disambiguate wraparound.
- Commit LSN C: The WAL LSN of a transaction’s COMMIT record (or COMMIT PREPARED).
- begin_lsn / end_lsn: Engine version interval endpoints. begin_lsn is the creator’s commit LSN; end_lsn is the deleter’s commit LSN (0 ⇒ still live).
- B (boundary): The statement’s visibility horizon, computed by the extension from PostgreSQL’s snapshot S and WAL state. Engine must only show effects with commit LSN ≤ B and exclude any version whose end_lsn ≤ B.
- Snapshot S (READ COMMITTED, single statement): Captured by the backend at statement start (GetTransactionSnapshot). S contains xmin/xmax and a set of in‑progress XIDs (S.xip/subxip).
- Commit order: The total order of committed effects by the WAL commit record LSNs.
- Invariant: The engine never applies uncommitted or aborted effects. All version stamps are top‑level commit LSNs only. All visibility decisions in the engine are based solely on LSNs, not TXIDs.

---

## 1) Background and rationale

PostgreSQL tuple visibility at READ COMMITTED is defined by a statement‑level snapshot S (GetTransactionSnapshot), which captures:
- xmin/xmax and the set of in‑progress XIDs at statement start.
- A tuple is visible if created by a committed XID “visible to S” and not deleted by a committed XID “visible to S.”

A raw WAL LSN does not encode the in‑progress set, but commit records impose a total order of committed effects and carry precise LSNs.

Design choices
- Keep the engine independent of PostgreSQL internals by using commit LSN as a commit sequence number (CSN‑like).
- Push the TXID/snapshot complexity into the extension: compute a boundary LSN B corresponding to S, then enforce purely LSN‑based MVCC in the engine.

Why this achieves parity
- If B reflects “all commits visible to S but strictly below any XIDs that S still considers in‑progress,” then the engine’s interval predicate (begin_lsn ≤ B < end_lsn or end_lsn=0) yields exactly the same rows as PostgreSQL for that statement.

---

## 2) Engine MVCC model (LSN‑interval / CSN‑like)

Per row version, the engine stores:
- begin_lsn = C(top‑level creator)
- end_lsn = C(top‑level invalidator) or 0 if live

Visibility at boundary B
- A version V is visible iff:
  - V.begin_lsn ≤ B
  - and (V.end_lsn == 0 or V.end_lsn > B)

Storage sketch
- Lsn type: 64‑bit unsigned monotonic (maps to PostgreSQL XLogRecPtr ordering).
- Per table:
  - Columnar payload + version metadata (begin_lsn, end_lsn), stored either per row‑id side structure or vectorized metadata.
  - last_applied_commit_lsn (atomic).
- The engine applies only committed batches, atomically per top‑level transaction, in commit order or any order that preserves per‑table LSN monotonicity.

Never apply uncommitted/aborted deltas; end_lsn/begin_lsn are stamped only at commit time.

---

## 3) Ingest semantics and data stamping

Source of truth (extension via logical decoding)
- Logical decoding restricted to Minnal‑managed relations.
- Do not emit row deltas until the top‑level transaction’s COMMIT is observed (reorderbuffer preserves commit order).
- Large in‑progress transactions may stream; the extension buffers and emits a single atomic batch at commit LSN C. Aborts are discarded.
- Subtransactions: fold to top‑level at commit; stamp all row effects with the top‑level commit LSN C.
- Two‑phase: apply only on COMMIT PREPARED; stamp with that commit’s LSN as C.
- DDL: version schema with commit LSN and serialize with data changes; for MVP, route DDL statements to PostgreSQL.

Logical decoding with streaming (PG14+)
- With streaming enabled (PG14+), the output plugin receives interleaved stream blocks from concurrent in‑progress transactions. Finalization events (stream_commit_cb/stream_abort_cb) are delivered in commit order (WAL order). Non‑streamed transactions use begin_cb/change_cb/commit_cb. Treat visibility as occurring at finalization; buffer stream fragments; apply on commit only.

Timelines for concurrent T2 and T3

Timeline A — both stream; T3 commits before T2 (C3 < C2)
1) stream_start_cb(T3)
2) stream_change_cb(T3, …) … stream_stop_cb(T3)
3) stream_start_cb(T2)
4) stream_change_cb(T2, …) … stream_stop_cb(T2)
5) (interleaved stream_* blocks for T2/T3 as needed)
6) Finalization in commit order (WAL order):
   • stream_commit_cb(T3, commit_lsn = C3)
   • stream_commit_cb(T2, commit_lsn = C2)
Visibility materializes at stream_commit_cb.

Timeline B — both stream; T2 commits before T3 (C2 < C3)
- Same interleaving of stream_* blocks; finalization flips:
  • stream_commit_cb(T2, commit_lsn = C2)
  • stream_commit_cb(T3, commit_lsn = C3)
- Commit order is preserved even though pre‑commit stream blocks interleave.

Abort variant (one aborts)
- If T3 aborts after streaming some blocks:
  • stream_abort_cb(T3, abort_lsn = …) arrives; discard all buffered T3 fragments.
  • T2 still finalizes with stream_commit_cb(T2) in commit order.

Notes to rely on in code
- Callback sets:
  • Streamed transactions: stream_start_cb, stream_change_cb, stream_stop_cb, then stream_commit_cb or stream_abort_cb.
  • Non‑streamed transactions: begin_cb → change_cb … → commit_cb.
  • Streaming callbacks are documented in the logical decoding/output plugin API; wire‑level messages (“Stream Start/Stop/Commit/Abort”) are defined by the logical replication protocol.
- Order guarantee:
  • Finalization events respect commit order (WAL commit record order). Pre‑commit fragments from different transactions can interleave; commits do not.
- Apply on commit only:
  • Buffer stream fragments keyed by top‑level XID. On stream_commit_cb, coalesce and emit a single committed batch stamped with commit_lsn = C. On stream_abort_cb, drop all buffered fragments for that XID. Preserves LSN‑only MVCC.
- Stamping alignment (at finalization):
  • INSERT → begin_lsn = C, end_lsn = 0
  • DELETE/UPDATE(old) → end_lsn = C
  • UPDATE(new) → begin_lsn = C
  • Fold subtransactions to the top‑level XID before finalization so all effects are stamped with the top‑level commit LSN C.

Relevant local sources
- postgres/source/src/backend/replication/logical/reorderbuffer.c
- postgres/source/src/include/replication/output_plugin.h
- postgres/source/src/backend/replication/logical/logical.c
- postgres/source/src/backend/access/transam/xact.c

Stamping rules for a committed top‑level transaction T with commit_lsn = C:
- INSERT: new version with begin_lsn = C, end_lsn = 0
- DELETE: set end_lsn = C on the prior version
- UPDATE: set end_lsn = C on the old version; create new version with begin_lsn = C

Batching and atomicity
- Send one batch per committed transaction (or coalesce multiple, preserving commit order by C).
- The engine applies each batch atomically, then publishes last_applied_commit_lsn = max(last_applied_commit_lsn, C).

Examples
- Abort example:
  - T1: INSERT r(a=1) → ABORT. No versions are emitted; engine remains unchanged.
- Subtransaction example:
  - T2: subx T2_1 INSERT r; subx T2_2 UPDATE r; COMMIT T2 at C2.
  - Engine receives a single batch stamped at C2: r.end=C2; r′.begin=C2 (folded to top‑level).
- 2PC example:
  - T3: PREPARE TRANSACTION; no visibility/effects yet.
  - COMMIT PREPARED at C3 → engine applies effects at C3.

---

## 4) Visibility evaluation at query time

- The extension computes B from the statement’s snapshot S (Section 5) and sends (plan, B) to the engine.
- The engine gatekeeps execution until last_applied_commit_lsn ≥ B (and additional table watermarks; see below).
- The engine evaluates visibility with two comparisons per version:
  - visible ⇔ (begin_lsn ≤ B) ∧ (end_lsn = 0 ∨ end_lsn > B)

Definition of B (precise, minimal)
1) B_base := the publisher’s WAL flush LSN captured immediately after acquiring S (GetTransactionSnapshot), e.g., GetFlushRecPtr() or pg_current_wal_flush_lsn().
2) fence2 := the minimum commit LSN among XIDs that appear in‑progress in S but for which the logical commit record is already known (via commit_index).
3) If fence2 exists: B := min(B_base, predecessor(fence2)); else B := B_base.
   This excludes any commit already flushed but still listed in S.xip due to ProcArray lag, so visibility matches PostgreSQL’s snapshot.

Async‑commit note
- With synchronous_commit=off, PostgreSQL may consider a transaction committed and visible to new snapshots before its commit record is flushed. Because B uses the flush horizon, such commits would be excluded by Minnal, potentially producing results that are staler than PostgreSQL. For exact parity: require synchronous_commit=on for Minnal‑managed relations (else route statements to PostgreSQL).

Multi‑table joins: query waits and watermarks
- Problem: If B corresponds to a commit with no changes for some table, naive per‑table waits “last_applied_commit_lsn[table] ≥ B” can stall.
- Solution: Maintain two watermarks:
  1) global_ingest_watermark: highest WAL LSN the extension has fully decoded/observed, advancing even when some tables have no changes (via periodic heartbeats).
  2) table_safe_upto_lsn[t]: for each table t, the highest LSN up to which the extension certifies “no pending changes remain for t” (either by applying all deltas ≤ L or by sending a no‑op heartbeat for t when decoding advances past L).
- Gating for query touching tables T at boundary B:
  - Require global_ingest_watermark ≥ B (liveness).
  - For each t ∈ T: require max(last_applied_commit_lsn[t], table_safe_upto_lsn[t]) ≥ B (per‑table safety).
- Implementation: bgworker emits periodic heartbeat frames as decoding advances, carrying:
  - observed_lsn (→ update global_ingest_watermark), and
  - a vector of tables for which safe_upto_lsn[t] = observed_lsn holds when no changes for t were found up to that point.

Example (join wait)
- Tables A and B; B includes recent changes up to C105; A had no changes since C90.
- Statement snapshot yields B = C100; the engine has applied:
  - A.last_applied_commit_lsn = C90, safe_upto_lsn[A] = C104 due to heartbeat
  - B.last_applied_commit_lsn = C105, safe_upto_lsn[B] = C105
  - global_ingest_watermark = C105
- Gating:
  - global_ingest_watermark ≥ C100 (ok).
  - For A: max(C90, C104) = C104 ≥ C100 (ok).
  - For B: max(C105, C105) = C105 ≥ C100 (ok).
- The query runs immediately without waiting for a nonexistent “A@C100” batch.

---

## 5) Extension algorithm: snapshot → commit‑LSN boundary B

Goal: Compute B = highest commit LSN among transactions visible to S, strictly below any XIDs that S considers in‑progress at statement start.

Minimal steps
- Capture S = GetTransactionSnapshot(), then immediately read B_base = GetFlushRecPtr() (or pg_current_wal_flush_lsn()) in the same backend.
- Build InProgTop from S.xip[] plus top(parent(subxids)).
- From WAL‑derived commit_index, find fence2 = min(commit_lsn(x) for x ∈ InProgTop if known).
- If fence2 exists: B = min(B_base, predecessor(fence2)); else B = B_base.
- Send (plan, B) to engine; the engine gates and evaluates via begin_lsn/end_lsn.

Inputs
- S from snapmgr/procarray.
- B_base from xlog flush pointer in the same backend that took S.
- commit_index: WAL‑driven map {topXid → commit_lsn}, maintained by bgworker via logical decoding (ReorderBufferCommit).
- child→parent mapping for subtransactions from XLOG_XACT_ASSIGNMENT or SubTrans.

Races handled
- Commit record flushed (commit_index knows Cx) but XID still appears in S.xip: predecessor(Cx) excludes its effects for this statement.

Algorithm
1) Capture S.
2) Build InProgTop:
   - Add S.xip[] (top‑level in‑progress).
   - Fold S.subxip[] to top‑level parents and add.
3) fence1 := B_base (publisher flush LSN captured at snapshot time).
4) fence2 := +∞
   - For xid in InProgTop: if commit_index[xid] known → fence2 = min(fence2, commit_index[xid]).
5) If fence2 < +∞: B = min(fence1, predecessor(fence2)); else B = fence1.
6) Send B with the serialized plan to the engine.

Notes
- Use GetFlushRecPtr() (xlog.c) directly in the backend, not bgworker horizons, for fence1.
- predecessor(LSN) := LSN−1 with XLogRecPtr‑safe decrement (use PG macros in extension). In the engine, LSN is treated as a 64‑bit monotonic scalar.

Why this matches PostgreSQL
- All commits visible to S have commit LSN ≤ B.
- Any XID considered in‑progress by S is excluded even if its commit WAL exists: predecessor(fence2) cuts it out.

---

## 6) Code‑level pseudocode

Engine side (no PostgreSQL headers)
```cpp
using Lsn = uint64_t; // encodes PG's XLogRecPtr ordering

struct VersionRef {
  uint64_t row_id;   // engine row locator
  Lsn begin_lsn;     // 0 is invalid, must be > 0 when present
  Lsn end_lsn;       // 0 means "live"
  // payload in columnar storage
};

inline bool visible_at(const VersionRef& v, Lsn B) noexcept {
  if (v.begin_lsn > B) return false;
  if (v.end_lsn != 0 && v.end_lsn <= B) return false;
  return true;
}

struct TableState {
  std::atomic<Lsn> last_applied_commit_lsn{0};
  // storage handles...
};

// Apply committed batch for a single transaction commit C.
void apply_committed_batch(TableState& t, Lsn C, Span<Delta> deltas) {
  // 1) Apply INSERT/DELETE/UPDATE deltas atomically; all stamped at C.
  // 2) Publish new last_applied_commit_lsn (monotonic).
  Lsn expected = t.last_applied_commit_lsn.load(std::memory_order_relaxed);
  while (expected < C &&
         !t.last_applied_commit_lsn.compare_exchange_weak(
             expected, C, std::memory_order_release, std::memory_order_relaxed)) {
    // retry on contention
  }
}
```

Extension side (can use PG headers/APIs)
```cpp
// Top-level XID with epoch
using XidWithEpoch = uint64_t; // (epoch << 32) | xid

struct CommitIndex {
  absl::flat_hash_map<XidWithEpoch, XLogRecPtr> map; // topXid -> commit LSN
  std::atomic<XLogRecPtr> last_committed_lsn{InvalidXLogRecPtr};

  void on_commit(XidWithEpoch topXid, XLogRecPtr commit_lsn) {
    map[topXid] = commit_lsn;
    XLogRecPtr prev = last_committed_lsn.load(std::memory_order_relaxed);
    while (XLByteLT(prev, commit_lsn) &&
           !last_committed_lsn.compare_exchange_weak(
               prev, commit_lsn, std::memory_order_release, std::memory_order_relaxed)) {
      // retry
    }
  }
};

XidWithEpoch withEpoch(TransactionId xid);
XidWithEpoch top_xid(XidWithEpoch child); // from SubTrans or WAL ASSIGNMENT

static inline XLogRecPtr predecessor(XLogRecPtr lsn) {
  if (lsn == InvalidXLogRecPtr) return InvalidXLogRecPtr;
  return lsn - 1; // For strict < comparisons; use segment-safe helpers in PG
}

// In the connection backend at statement start:
//   Snapshot S = GetTransactionSnapshot();
//   XLogRecPtr base_flush = GetFlushRecPtr(); // or pg_current_wal_flush_lsn()
//   XLogRecPtr B = compute_boundary_B(S, base_flush, commitIndex);
//   Pass B to engine and wait until engine ≥ B.

XLogRecPtr compute_boundary_B(const SnapshotData* S,
                              XLogRecPtr base_flush_lsn,
                              CommitIndex& ci) {
  absl::flat_hash_set<XidWithEpoch> inprog;

  for (int i = 0; i < S->xcnt; ++i)
    inprog.insert(withEpoch(S->xip[i]));

  for (int i = 0; i < S->subxcnt; ++i)
    inprog.insert(top_xid(withEpoch(S->subxip[i])));

  XLogRecPtr fence1 = base_flush_lsn;

  XLogRecPtr fence2 = InvalidXLogRecPtr; // treat as +∞
  for (auto xid : inprog) {
    auto it = ci.map.find(xid);
    if (it != ci.map.end()) {
      fence2 = (fence2 == InvalidXLogRecPtr) ? it->second
               : MinXLogRecPtr(fence2, it->second);
    }
  }

  if (fence2 != InvalidXLogRecPtr) {
    XLogRecPtr pred = predecessor(fence2);
    return MinXLogRecPtr(fence1, pred);
  }
  return fence1;
}
```

Logical decoding (bgworker)
- On ReorderBufferCommit:
  - Identify top‑level XID and commit_lsn (EndRecPtr of COMMIT record).
  - CommitIndex.on_commit(topXid, commit_lsn).
  - Produce row deltas restricted to Minnal tables, stamp with commit_lsn, send to engine.

---

## 7) Worked examples (expanded)

Conventions
- Cn denotes commit LSN of Tn’s COMMIT record (e.g., C7 is commit LSN of T7).
- Engine visibility rule at B: visible ⇔ begin_lsn ≤ B ∧ (end_lsn = 0 ∨ end_lsn > B).
- Unless stated: single table t(k, v), no DDL interleaves, logical decoding filters to t.

A) Interleaved transactions (R1–R7)
- MVCC headers at logical level (xmin/xmax):
  - R1: xmin=T1, xmax=Inf
  - R2: xmin=T1, xmax=T2
  - R3: xmin=T2, xmax=Inf
  - R4: xmin=T5, xmax=Inf
  - R5: xmin=T6, xmax=Inf
  - R6: xmin=T7, xmax=Inf
  - R7: xmin=T7, xmax=T7 (insert & delete within T7)
- Status at Q1 snapshot:
  - T1, T2, T3 committed (C1, C2, C3).
  - T5 in‑progress.
  - T6 aborted.
  - T7 either post‑snapshot commit or pre‑snapshot commit.

Stamping
- T1@C1: R1.begin=C1; R2.begin=C1
- T2@C2: R2.end=C2; R3.begin=C2
- T7@C7: R6.begin=C7; R7.begin=C7; R7.end=C7

Case A1: T7 commits after the snapshot S
- PostgreSQL sees T1,T2,T3 only; in‑progress: T5,T7.
- Visible rows in PG: R1, R3.
- Extension:
  - fence1 = C3 (latest flushed at snapshot).
  - fence2 = +∞ (T5,T7 not known committed).
  - B = C3.
- Engine at B=C3: R1 (C1..∞) and R3 (C2..∞) visible; others not. Matches PG.

Case A2: T7 committed before S
- PostgreSQL visible: T1,T2,T3,T7; in‑progress: T5.
- Visible rows in PG: R1, R3, R6; R7 excluded (begin=end=C7).
- Extension:
  - fence1 = C7 (includes T7).
  - fence2 = +∞ unless T5’s commit record raced in; if so, fence2=C5 → B< C5.
  - Typically B = C7.
- Engine at B=C7: R1, R3, R6 visible; R7 excluded since end_lsn=C7 ≤ B. Matches PG.

Numeric timeline
- C1=100, C2=120, C3=130, C7=125.
- Case A2 S at time flush=130 with S.xip={T5}. B_base=130, fence2=+∞ ⇒ B=130.
- Engine shows any begin_lsn≤130 minus end_lsn≤130; R7 hidden.

B) Update chain
- T10 INSERT A; C10=210 → A.begin=210, A.end=0.
- T11 UPDATE A→A′; C11=240 → A.end=240, A′.begin=240.
- Visibility:
  - B=210 → A visible.
  - 210 < B < 240 → A visible.
  - B≥240 → A′ visible.

C) Delete
- T12 DELETE A′; C12=300 → A′.end=300.
- Visibility:
  - B<300 → A′ visible.
  - B≥300 → A′ invisible.

D) Subtransactions
- T20 with child T20_1 inserts X; child T20_2 updates X; COMMIT T20 at C20=400.
- Stamping folded to top‑level:
  - X.begin=C20; prior X.end=C20 as needed.
- Visibility:
  - B≥C20 ⇒ visible; B<C20 ⇒ not visible.

E) Two‑phase commit (2PC)
- T30 PREPARE (no effects visible).
- Later COMMIT PREPARED at C30=500:
  - INSERTs: begin=500
  - DELETEs/UPDATEs: end=500 (+ begin=500 for new versions)
- Visibility:
  - B≥500: effects visible; B<500: not visible.

F) ProcArray race (commit present, XID appears in S.xip)
- T8 commit record flushed at C8=600, but S.xip still contains T8 at snapshot time.
- Extension: commit_index[T8]=600 ⇒ fence2=600.
- B = min(B_base, predecessor(600)) ⇒ B < 600.
- Engine excludes versions stamped at 600. Matches PG’s exclusion of T8 for the statement.

G) Commit order vs visibility order
- T2 and T3 commit around each other: WAL order C3=101 then C2=102 (C3<C2).
- Snapshot S: T2 not in S.xip (visible); T3 in S.xip (in‑progress).
- B_base ≥ 102; fence2=101 (from T3).
- B = min(B_base, 100) ⇒ include C2, exclude C3. Matches PG.

H) Async commit on vs off
- T40 uses synchronous_commit=off; backend treats it as committed before flush; commit record flushes at C40=700 later.
- Snapshot S taken after backend considers T40 committed but before WAL flush:
  - PG may show T40; B_base uses flush horizon (<700), fence2 may not include C40 yet.
  - Minnal (B<C40) excludes T40.
- Policy: require synchronous_commit=on for Minnal‑managed tables for parity; otherwise route the statement to PG.

I) Multi‑table join gating example (with no‑op heartbeats)
- See Section 4 example; numeric:
  - B=1000, global_ingest_watermark=1030.
  - A.last_applied=980, safe_upto[A]=1025.
  - B.last_applied=1005, safe_upto[B]=1005.
  - Gate passes: max(A)=1025≥1000, max(B)=1005≥1000 ⇒ run.

J) Large in‑progress S.xip with sparse commit knowledge
- S.xip = {T51..T80}; commit_index knows only T59@C59=1200.
- B_base=1250; fence2 = min(1200) = 1200 ⇒ B = min(1250, 1199) = 1199.
- Effect: excludes T59 and any later commits; inclusion of earlier commits remains allowed.

K) Insert‑delete within same transaction
- T60 inserts Y and deletes Y; commit at C60=1400.
- Stamping: Y.begin=1400; Y.end=1400.
- Visibility:
  - Any B≥1400: Y invisible (end_lsn ≤ B).
  - B<1400: Y invisible (begin_lsn > B).
  - Hence never visible to others, matching PG.

L) Aborted transaction
- T70 inserts Z then aborts; no commit record.
- Engine receives nothing; Z never appears at any B.

---

## 8) Edge cases and nuances

- ProcArray race: Commit LSN flushed but XID still in S.xip. fence2 forces B < that commit, excluding its effects for the statement.
- HOT updates: Logical decoding surfaces UPDATE as delete+insert at commit. Engine remains unaware of HOT internals; stamping rules already match visibility.
- Reordering: Preserve reorderbuffer commit ordering across transport/apply; never reorder deltas per table independently in a way that violates commit LSN monotonicity.
- DDL/schema:
  - Version schema with commit_lsn(Cschema).
  - MVP: route DDL to PG. Future: ensure plan schema snapshot ≤ B and maintain schema snapshots keyed by LSN.
- LSN arithmetic: Use XLogRecPtr helpers/macros in the extension; in the engine treat LSN as a 64‑bit monotonic integer. predecessor(B) = B − 1 with segment‑safe semantics on extension side.
- Large S.xip: READ COMMITTED single‑statement snapshots are usually small; O(n) iteration acceptable. Stop early when fence2 reaches a very small value (pruning).

Examples
- DDL routing example:
  - Session executes ALTER TABLE between reads. Offloaded reads are routed back to PG when unstable schema is detected or when schema@B cannot be satisfied.
- Reordering hazard example:
  - T80@C80 deletes row R; T81@C81 re‑inserts R. Engine must apply in commit order so that at B∈[C80,C81): R invisible; at B≥C81: R visible.

---

## 9) Failure, recovery, and checkpoints

Engine checkpoints
- Persist columnar data + version metadata.
- Persist per‑table last_applied_commit_lsn.
- Persist global_ingest_watermark and table_safe_upto_lsn (or rebuild conservatively on restart).

Engine restart
- Load latest checkpoint.
- Accept committed batches starting from ≥ last_applied_commit_lsn (idempotent).
- Block queries until table watermarks satisfy B (Section 4 gating).

Extension restart
- Rebuild CommitIndex from WAL via logical slot restart_lsn.
- Until CommitIndex catches up, compute B conservatively (fence1 from local GetFlushRecPtr; apply fence2 exclusions when known).

Recovery examples
- If engine lost table_safe_upto_lsn, initialize it to last_applied_commit_lsn and let heartbeats raise it; queries may wait until heartbeat advances above their B.

---

## 10) Testing strategy

Concurrency harness
- Writers: randomized INSERT/UPDATE/DELETE; include subxacts, aborts, and occasional 2PC.
- Reader: autocommit SELECTs; extension computes B; compare engine vs PostgreSQL results.

Targeted races
- Commit flushed but XID in S.xip: verify exclusion via fence2.
- Subtransactions: ensure folding and stamping at top‑level C.
- 2PC: ensure visibility only after COMMIT PREPARED.

Lag scenarios
- Induce ingest lag; verify engine blocks until ≥ B and then matches PG.
- Heartbeat correctness: ensure join gating can proceed when tables have no changes near B.

Metrics‑driven assertions
- For each query, log (B − table watermark) deltas and verify within bounds.

---

## 11) Operational considerations and metrics

Preconditions for offload
- wal_level=logical
- synchronous_commit=on for Minnal‑managed tables (required for parity); otherwise route to PG
- max_replication_slots sized for workload; logical_decoding_work_mem tuned
- For 2PC: max_prepared_transactions > 0 and two‑phase decoding enabled

Per‑table metrics
- last_applied_commit_lsn
- safe_upto_lsn
- replication_lag_ms (now − commit_time)
- apply throughput (rows/s), batch latency

Logging
- When a query waits for ≥ B, log wait time and delta (B − max(last_applied_commit_lsn, safe_upto_lsn) at arrival).
- Log heartbeats and observed_lsn progression.

Backpressure
- If lag exceeds threshold, pause logical slot or throttle extension’s send rate; route hot queries to PG.

---

## 12) Alternatives (when exact parity is not required)

Conservative stale mode (subset)
- B := engine.last_applied_commit_lsn at dispatch time (no mapping from S).
- Never shows too‑new rows; may be staler than PG’s snapshot.

“Latest” mode (superset risk)
- B := latest known commit LSN regardless of S.
- May show rows that PG’s snapshot would not. Not recommended for correctness.

---

## 13) Appendix: towards multi‑statement isolation

Not offloaded in MVP; documented for completeness.

Repeatable Read inside a transaction
- Compute B_tx at the first statement’s snapshot using the same algorithm.
- Pin all offloaded reads in the transaction to B_tx.
- Engine must reject requests with B > B_tx within the same PG transaction.
- Any writes or non‑read‑only interactions should be routed to PG.

Serializable
- Requires predicate locking/conflict detection; not feasible with LSN‑only MVCC in the engine. Route to PG.

DDL inside transaction
- Route to PG or apply strict schema versioning with Cs ≤ B_tx; offloading not recommended.

Examples
- RR example:
  - Stmt1 computes B_tx=2000; Stmt2 arrives later when engine is at 2200.
  - Offloaded Stmt2 must still use B=2000 for parity with RR; otherwise route to PG.

---

## 14) References to PostgreSQL internals (local tree)

Paths below refer to the repository’s local PostgreSQL source:
- Absolute base: /Users/hprabaka/sources/minnal/postgres/
- Relative within repo: postgres/source/src/…

Snapshots and ProcArray
- GetTransactionSnapshot: postgres/source/src/backend/utils/time/snapmgr.c
- GetSnapshotData: postgres/source/src/backend/storage/ipc/procarray.c

Visibility
- HeapTupleSatisfiesMVCC: postgres/source/src/backend/access/heap/heapam_visibility.c

WAL flush horizon
- GetFlushRecPtr: postgres/source/src/backend/access/transam/xlog.c
- SQL wrapper: pg_current_wal_flush_lsn() (Monitoring Functions — WAL)

Logical decoding
- ReorderBufferCommit: postgres/source/src/backend/replication/logical/reorderbuffer.c
- Snapshot building (RunningXacts): postgres/source/src/backend/replication/logical/snapbuild.c

Subtransactions
- SubTransGetTopmostTransaction: postgres/source/src/backend/access/transam/subtrans.c
- XLOG_XACT_ASSIGNMENT handling: postgres/source/src/backend/access/transam/xact.c and WAL record handlers nearby

Commit records
- RecordTransactionCommit and commit WAL emission: postgres/source/src/backend/access/transam/xact.c

Notes
- The extension should call GetFlushRecPtr() in the same backend immediately after GetTransactionSnapshot() to obtain B_base.
- Use XLogRecPtr helpers/macros when computing predecessor(LSN) safely.

---

## TL;DR

- Engine: purely LSN‑based MVCC with (begin_lsn, end_lsn); visible at B iff begin_lsn ≤ B and (end_lsn = 0 or end_lsn > B).
- Extension: computes a per‑statement boundary B from PostgreSQL’s snapshot S and WAL commit index; engine gates rows to ≤ B and excludes deletions ≤ B.
- MVP: single‑statement READ COMMITTED only (autocommit). Transaction blocks and higher isolation levels route to PostgreSQL.
- For parity: require synchronous_commit=on for Minnal‑managed tables; otherwise route to PostgreSQL.
