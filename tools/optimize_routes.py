#!/usr/bin/env python3
"""CompletionRoute :: tools/optimize_routes.py - offline route optimizer (FINISH_PLAN W3, routing tier A).

Reads the per-guide travel matrices written by tools/cost_matrix.lua (real TravelGraph/Router costs) and
bakes, per quest guide, the fastest step order that keeps every hard rule:

  * A before C before T per quest (several accepts / turn-ins of one quest keep their author order),
  * PRE: a prerequisite's turn-in before every step that names it (only edges the author order already keeps),
  * quest-log capacity (era/forever 20, tbc/mop 25, retail 35 - raised to the author order's own peak
    if a guide already needs more), counting accepts minus turn-ins inside the guide,
  * level gates: a step whose |LVL| is above the guide's start level may only come after as many turn-ins
    as the author order needed before its FIRST step of that level (the author's own XP assumption),
  * anchors (non-routable or sticky steps, and step kinds with no quest semantics) stay where the author
    put them - the guide is cut into segments between anchors and each segment is solved on its own,
  * steps without coordinates stay attached to the located step before them (a "block").

Solver: OR-Tools routing (open path, 'order' dimension for precedence, 'log' and 'turnins' dimensions),
started from the better of the author order and a feasible nearest-neighbour construction, improved with
guided local search under a per-guide time limit (default: 2 s + 0.1 s per block, capped at 30 s).
Then an exact dynamic programme over precedence-closed subsets runs on the metric closure of the costs
(<= 90 blocks, --dp-time seconds, --dp-cap subsets): when it finishes, its optimum is a TRUE lower bound
and its order is one more candidate.

Lower bound per segment: the metric DP optimum when it finishes (lb_exact = 1), else max(assignment
relaxation with precedence-impossible arcs removed, minimum spanning tree and Held-Karp 1-tree bound on
min(c_ij, c_ji)) - those ignore precedence and are loose.  opt_gap = (baked - bound) / baked.
Multi-segment guides (anchors) sum per-segment bounds from the baked chain's segment starts (approximate).

Costs: every constant and rule comes from the cost model (CompletionRoute/Routing/CostModel.lua) through the rows
tools/cost_matrix.lua writes: the priced points (a step without one rides with the block before it), the matrix (each
leg at the planning level of the step it leaves from) and "cm" (the no-route cost, the cost-model version, the offline
flight-path rule).  This file holds no second copy of them; a row without "cm" is refused.

Output:
  --lua-out PATH (default CompletionRoute/Data/RouteOrder_<flavor>.lua; generated, gitignored; only guides the bake
                 makes faster)
  --out PATH     (default $CR_TMP/routeopt/<flavor>.jsonl; one result row per guide, read by tools/collect_routes.py)
  CR_TMP defaults to TMP_DEFAULT below (the optimizer's job directory).

Usage: venv/bin/python tools/optimize_routes.py <flavor> [--in PATH] [--out PATH] [--lua-out PATH] [--limit-s 30]
                                               [--guide ID] [--no-write] [--merge]
"""
import argparse
import heapq
import json
import math
import os
import sys
import time

TMP_DEFAULT = "/Users/daniel/.claude/jobs/ff3c728a/tmp"
TMP = os.environ.get("CR_TMP") or TMP_DEFAULT
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG_CAP = {"era": 20, "forever": 20, "tbc": 25, "mop": 25, "retail": 35}
NOROUTE = None            # seconds for a leg the router cannot path: the cost model's (row["cm"], use_cost_model)
HEARTH = None             # seconds an H step (use the hearthstone) costs instead of the trip: the cost model's
SCALE = 10                # OR-Tools works in integers: deciseconds
MOD = 2147483647

try:
    from ortools.constraint_solver import pywrapcp, routing_enums_pb2
    from ortools.graph.python import linear_sum_assignment
    HAVE_ORTOOLS = True
except Exception:  # pragma: no cover
    HAVE_ORTOOLS = False


def checksum(steps):
    c = 0
    for s in steps:
        c = (c * 31 + ord(s[0][0]) + (s[2] or 0)) % MOD
    return c


def use_cost_model(rec):
    """Take the cost model's constants from a cost_matrix row (there is no second copy here)."""
    global NOROUTE, HEARTH
    cm = rec.get("cm")
    if not cm or "noroute" not in cm or "hearth" not in cm:
        raise SystemExit("row %s has no cost model (\"cm\"): it was written before Routing/CostModel.lua - "
                         "re-run tools/cost_matrix.lua" % rec.get("id"))
    NOROUTE = float(cm["noroute"])
    HEARTH = float(cm["hearth"])
    return cm


# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------
class Seg:
    """One stretch of a guide between anchors: blocks that may be reordered freely within the rules."""
    def __init__(self):
        self.blocks = []       # list of lists of step indices (0-based), author order
        self.start_pt = None   # point index the segment starts from (None = guide start column)
        self.t_before = 0      # turn-in steps done before this segment (author order == baked order)
        self.log_before = set()


def build_model(rec):
    """Cut the guide into segments at anchors; inside a segment, each located step opens a block and the
    unlocated steps after it ride along. Unlocated steps at the start of a segment ride with the first
    located block of that segment (or form a point-less block if there is none)."""
    steps = rec["steps"]
    segs, order_items = [], []
    cur_seg, cur_blk, lead = None, None, []

    def close_seg():
        nonlocal cur_seg, cur_blk, lead
        if lead:
            if cur_seg is None:
                cur_seg = Seg()
                order_items.append(("seg", len(segs)))
            cur_seg.blocks.append(lead)
        if cur_seg is not None and cur_seg.blocks:
            segs.append(cur_seg)
        cur_seg, cur_blk, lead = None, None, []

    for i, s in enumerate(steps):
        kind, pt, anchor = s[1], s[5], s[6]
        if anchor or kind == "O":
            close_seg()
            order_items.append(("anchor", [i]))
            continue
        if cur_seg is None:
            cur_seg = Seg()
            order_items.append(("seg", len(segs)))
        if pt >= 0:
            cur_blk = lead + [i]
            lead = []
            cur_seg.blocks.append(cur_blk)
        elif cur_blk is None:
            lead.append(i)
        else:
            cur_blk.append(i)
    close_seg()

    def bpt(block):
        for i in block:
            if steps[i][5] >= 0:
                return steps[i][5]
        return None
    return segs, order_items, bpt


def precedence_edges(steps, blocks):
    """Block-level edges (i -> j: block i before block j). Only edges the author order keeps."""
    where = {}
    for b, blk in enumerate(blocks):
        for i in blk:
            where[i] = b
    by_q = {}
    for i in where:
        s = steps[i]
        if s[2]:
            by_q.setdefault(s[2], []).append(i)
    edges = set()
    dropped = 0

    def add(i, j):
        nonlocal dropped
        bi, bj = where[i], where[j]
        if bi == bj:
            return
        if i < j:
            edges.add((bi, bj))
        else:
            dropped += 1

    for q, idx in by_q.items():
        idx.sort()
        acc = [i for i in idx if steps[i][1] == "A"]
        obj = [i for i in idx if steps[i][1] == "C"]
        tin = [i for i in idx if steps[i][1] == "T"]
        for a in acc:
            for j in obj + tin:
                add(a, j)
        for c in obj:
            for t in tin:
                add(c, t)
        for x, y in zip(acc, acc[1:]):
            add(x, y)
        for x, y in zip(tin, tin[1:]):
            add(x, y)
        # a quest with an objective step that ticks by itself (the cost model's PlanSteps, step[11]): its objective
        # steps keep their author order, so the step that does the objective is the one walked to
        if any(len(steps[i]) > 11 and steps[i][11] for i in obj):
            for x, y in zip(obj, obj[1:]):
                add(x, y)
    # PRE: every in-guide turn-in of a prerequisite before any step that names it (the client hides such a step until
    # the prerequisite is done: Core/Conditions.lua; the live window and the re-planner use the same rule)
    turnins = {}
    for i in where:
        s = steps[i]
        if s[1] == "T" and s[2]:
            turnins.setdefault(s[2], []).append(i)
    for i in where:
        s = steps[i]
        if s[3]:
            for p in s[3]:
                for t in turnins.get(p, []):
                    add(t, i)
    return edges, dropped


class Problem:
    """One segment as an open-path problem over its blocks."""
    def __init__(self, rec, seg, bpt, cap, start_level, kmap, segstart_cost):
        steps = rec["steps"]
        self.steps = steps
        self.blocks = seg.blocks
        self.n = n = len(seg.blocks)
        self.pts = [bpt(b) for b in seg.blocks]
        m = rec["m"]
        self.m = m
        self.segstart_cost = segstart_cost   # function(pt) -> seconds from the segment start
        self.edges, self.dropped = precedence_edges(steps, seg.blocks)
        self.pred = [0] * n                    # bitmask of direct predecessors
        for i, j in self.edges:
            self.pred[j] |= 1 << i
        # transitive closure (ancestors)
        anc = [0] * n
        for j in range(n):           # author order is a topological order
            a = 0
            p = self.pred[j]
            k = 0
            while p:
                if p & 1:
                    a |= (1 << k) | anc[k]
                p >>= 1
                k += 1
            anc[j] = a
        self.anc = anc
        # log demand and turn-ins per block
        accepted_first = {}
        self.delta = [0] * n
        self.tcount = [0] * n
        self.gate = [0] * n
        has_t = {s[2] for s in steps if s[1] == "T" and s[2]}
        log = set(seg.log_before)
        for b, blk in enumerate(seg.blocks):
            d = 0
            for i in blk:
                s = steps[i]
                if s[1] == "A" and s[2] and s[2] not in log:
                    log.add(s[2])
                    d += 1
                elif s[1] == "T" and s[2] and s[2] in log:
                    log.discard(s[2])
                    d -= 1
                if s[1] == "T":
                    self.tcount[b] += 1
                if s[4] and s[4] > self.gate[b]:
                    self.gate[b] = s[4]
            self.delta[b] = d
        self.log0 = len(seg.log_before)
        # author peak -> capacity
        peak, cur = self.log0, self.log0
        for b in range(n):
            cur += self.delta[b]
            peak = max(peak, cur)
        self.cap = max(cap, peak)
        # level gates -> minimum turn-ins (within the segment) before each block
        self.kmin = [0] * n
        tb = 0
        for b in range(n):
            if self.gate[b] > start_level:
                need = kmap(self.gate[b]) - seg.t_before
                self.kmin[b] = max(0, min(need, tb))
            tb += self.tcount[b]

    def c(self, a, b):
        """cost from block a (or -1 = segment start) to block b"""
        pb = self.pts[b]
        if pb is None:
            return 0.0
        if a < 0:
            return self.segstart_cost(pb)
        pa = self.pts[a]
        if pa is None:
            return self.segstart_cost(pb) if a < 0 else 0.0
        v = self.m[pa][pb]
        return NOROUTE if v < 0 else v

    def cost(self, order):
        t, prev = 0.0, -1
        for b in order:
            # a block without a point (only possible for a lone leading block) costs nothing and keeps prev
            if self.pts[b] is None:
                continue
            t += self.c(prev, b)
            prev = b
        return t

    def feasible(self, order):
        if sorted(order) != list(range(self.n)):
            return False, "not a permutation"
        done = 0
        log = self.log0
        tb = 0
        for b in order:
            if self.pred[b] & ~done:
                return False, "precedence"
            if tb < self.kmin[b]:
                return False, "level gate"
            log += self.delta[b]
            if log > self.cap:
                return False, "quest log"
            tb += self.tcount[b]
            done |= 1 << b
        return True, ""


# ---------------------------------------------------------------------------
# Construction, exact DP, OR-Tools, lower bound
# ---------------------------------------------------------------------------
def greedy(pb):
    n = pb.n
    done, order, prev = 0, [], -1
    log, tb = pb.log0, 0
    for _ in range(n):
        best, bc = None, None
        for b in range(n):
            if done >> b & 1 or pb.pred[b] & ~done or tb < pb.kmin[b] or log + pb.delta[b] > pb.cap:
                continue
            c = pb.c(prev, b) + b * 1e-3
            if bc is None or c < bc:
                best, bc = b, c
        if best is None:
            return None
        order.append(best)
        done |= 1 << best
        log += pb.delta[best]
        tb += pb.tcount[best]
        if pb.pts[best] is not None:
            prev = best
    return order


def metric_closure(pb):
    """Shortest-path closure c' <= c of the segment's point costs (so c' obeys the triangle inequality).
    Returns (cs, cm): start->point and point->point arrays indexed by the problem's local point ids."""
    import numpy as np
    pts = sorted({p for p in pb.pts if p is not None})
    loc = {p: k for k, p in enumerate(pts)}
    k = len(pts)
    M = np.zeros((k, k))
    for i, p in enumerate(pts):
        for j, q in enumerate(pts):
            if i != j:
                v = pb.m[p][q]
                M[i, j] = NOROUTE if v < 0 else v
    for t in range(k):
        M = np.minimum(M, M[:, t:t + 1] + M[t:t + 1, :])
    S = np.array([pb.segstart_cost(p) for p in pts]) if k else np.zeros(0)
    if k:
        S = np.minimum(S, (S[:, None] + M).min(axis=0))
    return loc, S, M


def exact_dp(pb, metric=False, mask_cap=150000, time_cap=None):
    """Exact DP over precedence-closed subsets with state (subset, last point).

    Zero-cost closure: when the walk stands at point p, every feasible block at p that cannot hurt the log
    (delta <= 0, or the log can never fill) is taken at once. With costs that obey the triangle inequality
    this never loses optimality, so with metric=True (shortest-path closure c' <= c) the result is the exact
    optimum of the c' problem - a valid LOWER BOUND for the real one. With metric=False it is a heuristic
    on the real costs. Returns (cost, order) or None when the subset count passes mask_cap."""
    n = pb.n
    full = (1 << n) - 1
    if metric:
        loc, S, M = metric_closure(pb)

        def cost(last, b):
            if last is None:
                return float(S[loc[pb.pts[b]]])
            return float(M[loc[last], loc[pb.pts[b]]])
    else:
        def cost(last, b):
            if last is None:
                return pb.segstart_cost(pb.pts[b])
            v = pb.m[last][pb.pts[b]]
            return NOROUTE if v < 0 else v
    never_full = pb.log0 + sum(d for d in pb.delta if d > 0) <= pb.cap
    by_pt = {}
    for b in range(n):
        by_pt.setdefault(pb.pts[b], []).append(b)

    def closure(mask, log, tb, p, seq):
        changed = True
        while changed:
            changed = False
            for b in by_pt.get(p, ()):
                if mask >> b & 1 or pb.pred[b] & ~mask or tb < pb.kmin[b]:
                    continue
                if not (pb.delta[b] <= 0 or never_full) or log + pb.delta[b] > pb.cap:
                    continue
                mask |= 1 << b
                log += pb.delta[b]
                tb += pb.tcount[b]
                seq.append(b)
                changed = True
        return mask, log, tb

    # point-less blocks (lone leads) first, free
    seq0 = []
    mask0, log0, tb0 = 0, pb.log0, 0
    for b in by_pt.get(None, ()):
        if not pb.pred[b]:
            mask0 |= 1 << b
            log0 += pb.delta[b]
            tb0 += pb.tcount[b]
            seq0.append(b)
    # states: key (mask, last_pt) -> (cost, log, tb, parent_key, blocks_added)
    states = {(mask0, None): (0.0, log0, tb0, None, seq0)}
    buckets = {bin(mask0).count("1"): [(mask0, None)]}
    masks = set()
    pc = bin(mask0).count("1")
    best = None
    deadline = time.time() + time_cap if time_cap else None
    while pc <= n:
        if deadline and time.time() > deadline:
            return None
        keys = buckets.pop(pc, [])
        for key in keys:
            mask, last = key
            cst, log, tb, _, _ = states[key]
            if mask == full:
                if best is None or cst < states[best][0]:
                    best = key
                continue
            for b in range(n):
                if mask >> b & 1 or pb.pred[b] & ~mask or tb < pb.kmin[b] or log + pb.delta[b] > pb.cap:
                    continue
                p = pb.pts[b]
                if p is None:
                    v, np_ = cst, last
                else:
                    v, np_ = cst + cost(last, b), p
                seq = [b]
                nm, nl, nt = closure(mask | 1 << b, log + pb.delta[b], tb + pb.tcount[b], np_, seq)
                nk = (nm, np_)
                old = states.get(nk)
                if old is None or v < old[0] - 1e-9:
                    if old is None:
                        buckets.setdefault(bin(nm).count("1"), []).append(nk)
                        masks.add(nm)
                        if len(masks) > mask_cap or (deadline and len(masks) % 2048 == 0 and time.time() > deadline):
                            return None
                    states[nk] = (v, nl, nt, key, seq)
        pc += 1
    if best is None:
        return None
    order, key = [], best
    while key is not None:
        st = states[key]
        order[0:0] = st[4]
        key = st[3]
    return states[best][0], order


def lower_bound(pb):
    n = pb.n
    loc = [b for b in range(n) if pb.pts[b] is not None]
    if not loc:
        return 0.0
    # --- assignment relaxation: nodes S (start), blocks, E (end); arc E->S free; arcs into a block from
    # one of its descendants are impossible.
    nodes = ["S"] + loc + ["E"]
    k = len(nodes)
    BIG = 10 ** 9
    ap = None
    if HAVE_ORTOOLS:
        lsa = linear_sum_assignment.SimpleLinearSumAssignment()
        for ii, a in enumerate(nodes):
            for jj, b in enumerate(nodes):
                if ii == jj:
                    continue
                if a == "E":
                    cost = 0 if b == "S" else BIG
                elif b == "S":
                    cost = BIG
                elif b == "E":
                    cost = 0
                elif a == "S":
                    cost = int(pb.c(-1, b) * SCALE) if pb.anc[b] == 0 else BIG
                else:
                    cost = BIG if (pb.anc[a] >> b & 1) else int(pb.c(a, b) * SCALE)
                lsa.add_arc_with_cost(ii, jj, cost)
        if lsa.solve() == lsa.OPTIMAL:
            ap = lsa.optimal_cost() / SCALE
            if ap >= BIG / SCALE:
                ap = None
    # --- MST on symmetric min costs over S + located blocks (a Hamiltonian path is a spanning tree)
    V = [-1] + loc
    def w(a, b):
        if a == -1:
            return pb.c(-1, b)
        if b == -1:
            return pb.c(-1, a)
        return min(pb.c(a, b), pb.c(b, a))
    inT = {V[0]}
    dist = {v: w(V[0], v) for v in V[1:]}
    mst = 0.0
    while dist:
        v = min(dist, key=dist.get)
        mst += dist.pop(v)
        for u in dist:
            d = w(v, u)
            if d < dist[u]:
                dist[u] = d
    return max(mst, ap or 0.0, held_karp_bound(pb))


def held_karp_bound(pb, iters=150):
    """Held-Karp 1-tree bound (subgradient ascent) on the symmetric relaxation min(c_ij, c_ji) of the
    open path: add a dummy node D tied to the start S (forced edge) and free to every block, so a tour
    through D, S and all blocks is a Hamiltonian path from S. Ignores precedence, so it is a valid but
    loose bound when the rules force back-tracking."""
    try:
        import numpy as np
    except Exception:
        return 0.0
    loc = [b for b in range(pb.n) if pb.pts[b] is not None]
    k = len(loc)
    if k < 2:
        return 0.0
    N = k + 2          # 0 = D, 1 = S, 2.. = blocks
    C = np.zeros((N, N))
    for ii, a in enumerate(loc):
        C[1, ii + 2] = C[ii + 2, 1] = pb.c(-1, a)
        for jj in range(ii + 1, k):
            b = loc[jj]
            v = min(pb.c(a, b), pb.c(b, a))
            C[ii + 2, jj + 2] = C[jj + 2, ii + 2] = v
    BIGF = 1e7
    C[0, 1] = C[1, 0] = -BIGF        # force D-S
    pi = np.zeros(N)
    best = 0.0
    ub = pb.cost(list(range(pb.n)))
    step0 = 2.0
    lam = step0
    stall = 0
    for it in range(iters):
        W = C + pi[:, None] + pi[None, :]
        # MST over nodes 1..N-1 (Prim), then D joins with its two cheapest edges
        sub = W[1:, 1:]
        m = N - 1
        intree = np.zeros(m, dtype=bool)
        intree[0] = True
        dist = sub[0].copy()
        parent = np.zeros(m, dtype=int)
        deg = np.zeros(N)
        total = 0.0
        dist[0] = np.inf
        for _ in range(m - 1):
            v = int(np.argmin(np.where(intree, np.inf, dist)))
            total += dist[v]
            deg[v + 1] += 1
            deg[parent[v] + 1] += 1
            intree[v] = True
            upd = (~intree) & (sub[v] < dist)
            dist[upd] = sub[v][upd]
            parent[upd] = v
        dw = W[0, 1:]
        two = np.argsort(dw)[:2]
        total += dw[two[0]] + dw[two[1]]
        deg[0] += 2
        deg[two[0] + 1] += 1
        deg[two[1] + 1] += 1
        val = total - 2 * pi.sum() + BIGF
        if val > best + 1e-6:
            best = val
            stall = 0
        else:
            stall += 1
            if stall >= 10:
                lam /= 2
                stall = 0
        g = deg - 2
        nrm = float((g * g).sum())
        if nrm == 0:
            break
        t = lam * max(1.0, ub - val) / nrm
        pi = pi + t * g
        if lam < 1e-4:
            break
    return max(0.0, best)


def ortools_solve(pb, init, time_limit):
    n = pb.n
    mgr = pywrapcp.RoutingIndexManager(n + 2, 1, [0], [n + 1])
    rt = pywrapcp.RoutingModel(mgr)

    # block b = node b+1; a pointless block (no location) inherits nothing - charge 0 into and out of it
    # by giving it its predecessor's point is not expressible, so such blocks only exist as lone leads and
    # are pinned first via the precedence below.
    def arc(fi, ti):
        a, b = mgr.IndexToNode(fi), mgr.IndexToNode(ti)
        if b == n + 1 or b == 0:
            return 0
        bb = b - 1
        if pb.pts[bb] is None:
            return 0
        if a == 0:
            return int(pb.c(-1, bb) * SCALE)
        aa = a - 1
        if pb.pts[aa] is None:
            return int(pb.c(-1, bb) * SCALE)
        return int(pb.c(aa, bb) * SCALE)
    cb = rt.RegisterTransitCallback(arc)
    rt.SetArcCostEvaluatorOfAllVehicles(cb)
    # order dimension (precedence)
    one = rt.RegisterUnaryTransitCallback(lambda fi: 1)
    rt.AddDimension(one, 0, n + 2, True, "order")
    od = rt.GetDimensionOrDie("order")
    slv = rt.solver()
    for i, j in pb.edges:
        slv.Add(od.CumulVar(mgr.NodeToIndex(i + 1)) < od.CumulVar(mgr.NodeToIndex(j + 1)))
    for b in range(n):
        if pb.pts[b] is None:     # lone point-less lead: keep it first
            od.CumulVar(mgr.NodeToIndex(b + 1)).SetRange(1, 1)
    # quest log
    if any(pb.delta):
        def dem(fi):
            node = mgr.IndexToNode(fi)
            return 0 if node in (0, n + 1) else pb.delta[node - 1]
        dcb = rt.RegisterUnaryTransitCallback(dem)
        rt.AddDimension(dcb, 0, pb.cap, False, "log")
        ld = rt.GetDimensionOrDie("log")
        ld.CumulVar(mgr.NodeToIndex(0)).SetValue(pb.log0)
    # level gates
    if any(pb.kmin):
        def tdem(fi):
            node = mgr.IndexToNode(fi)
            return 0 if node in (0, n + 1) else pb.tcount[node - 1]
        tcb = rt.RegisterUnaryTransitCallback(tdem)
        rt.AddDimension(tcb, 0, sum(pb.tcount) + 1, True, "turnins")
        td = rt.GetDimensionOrDie("turnins")
        for b in range(n):
            if pb.kmin[b]:
                td.CumulVar(mgr.NodeToIndex(b + 1)).SetMin(pb.kmin[b])
    params = pywrapcp.DefaultRoutingSearchParameters()
    params.local_search_metaheuristic = routing_enums_pb2.LocalSearchMetaheuristic.GUIDED_LOCAL_SEARCH
    params.time_limit.FromMilliseconds(int(time_limit * 1000))
    params.log_search = False
    rt.CloseModelWithParameters(params)
    asg = rt.ReadAssignmentFromRoutes([[b + 1 for b in init]], True)
    if asg is None:
        return None
    sol = rt.SolveFromAssignmentWithParameters(asg, params)
    if sol is None:
        return None
    idx = rt.Start(0)
    order = []
    idx = sol.Value(rt.NextVar(idx))
    while not rt.IsEnd(idx):
        order.append(mgr.IndexToNode(idx) - 1)
        idx = sol.Value(rt.NextVar(idx))
    return order


# ---------------------------------------------------------------------------
# Per guide
# ---------------------------------------------------------------------------
def solve_guide(rec, limit_s, flavor, dp_cap=400000, dp_time=6.0):
    cm = use_cost_model(rec)
    steps = rec["steps"]
    m = rec["m"]
    start = rec["start"]
    segs, order_items, bpt = build_model(rec)
    # level map: K(L) = turn-ins before the first author step with level >= L
    levels = []
    tb = 0
    for s in steps:
        levels.append((s[4] or 0, tb))
        if s[1] == "T":
            tb += 1
    start_level = rec["minlevel"]

    def kmap(L):
        best = None
        for lv, t in levels:
            if lv >= L and (best is None or t < best):
                best = t
        return best or 0

    def startcost(pt):
        v = start[pt]
        return NOROUTE if v < 0 else v

    t0 = time.time()
    # walk the guide in author order, solving segments
    result_steps = []
    tot_author = tot_baked = tot_lb = 0.0
    methods = set()
    nblocks = 0
    dropped = 0
    violations = 0
    exact_segs = 0
    t_before = 0
    log = set()
    last_pt = None
    seg_idx = 0
    budget_blocks = sum(len(s.blocks) for s in segs) or 1
    time_total = min(30.0, 2.0 + 0.1 * budget_blocks)
    if limit_s is not None:
        time_total = min(time_total, limit_s)

    def from_pt(p):
        if p is None:
            return startcost
        return lambda q: (NOROUTE if m[p][q] < 0 else m[p][q])

    def apply_steps(idx_list):
        nonlocal t_before, last_pt
        for i in idx_list:
            s = steps[i]
            if s[1] == "A" and s[2]:
                log.add(s[2])
            elif s[1] == "T" and s[2]:
                log.discard(s[2])
            if s[1] == "T":
                t_before += 1
            if s[5] >= 0:
                last_pt = s[5]

    for kind, val in order_items:
        if kind == "anchor":
            i = val[0]
            if steps[i][5] >= 0:
                c = HEARTH if steps[i][0] == "H" else from_pt(last_pt)(steps[i][5])
                tot_author += c
                tot_baked += c
                tot_lb += c
            result_steps.extend(val)
            apply_steps(val)
            continue
        seg = segs[val]
        seg.t_before = t_before
        seg.log_before = set(log)
        pb = Problem(rec, seg, bpt, LOG_CAP.get(flavor, 25), start_level, kmap, from_pt(last_pt))
        dropped += pb.dropped
        nblocks += pb.n
        author = list(range(pb.n))
        ok, why = pb.feasible(author)
        if not ok:
            raise RuntimeError("author order infeasible in own model: " + why)
        ac = pb.cost(author)
        best_order, best_cost, method = author, ac, "author"
        lb = None
        if pb.n >= 2:
            g = greedy(pb)
            if g is not None and pb.feasible(g)[0] and pb.cost(g) < best_cost - 1e-6:
                best_order, best_cost, method = g, pb.cost(g), "greedy"
            if HAVE_ORTOOLS:
                tl = max(1.0, time_total * pb.n / budget_blocks)
                o = ortools_solve(pb, best_order, tl)
                if o is not None and pb.feasible(o)[0] and pb.cost(o) < best_cost - 1e-6:
                    best_order, best_cost, method = o, pb.cost(o), "ortools"
                elif method == "author":
                    method = "ortools-no-gain"
            # exact optimum of the metric-closed problem: a true lower bound, and its order is a candidate
            exm = exact_dp(pb, metric=True, mask_cap=dp_cap, time_cap=dp_time) if pb.n <= 90 else None
            if exm is not None:
                lb = exm[0]
                cand = exm[1]
                if pb.feasible(cand)[0] and pb.cost(cand) < best_cost - 1e-6:
                    best_order, best_cost, method = cand, pb.cost(cand), "exact"
                exact_segs += 1
            if lb is None:
                lb = min(lower_bound(pb), best_cost)
        else:
            lb = ac
        ok, why = pb.feasible(best_order)
        if not ok:
            violations += 1
            best_order, best_cost = author, ac
        methods.add(method)
        tot_author += ac
        tot_baked += best_cost
        tot_lb += lb
        for b in best_order:
            result_steps.extend(pb.blocks[b])
        # carry state forward in AUTHOR terms (identical: a segment's block set is the same either way)
        for b in author:
            apply_steps(pb.blocks[b])
        # baked order ends somewhere else: the next segment starts from the baked last point
        for b in reversed(best_order):
            if pb.pts[b] is not None:
                last_pt = pb.pts[b]
                break
    # NOTE: when the baked last point differs from the author's, the next anchor/segment start costs in the
    # two totals differ; tot_author above uses the baked chain for those few legs. Recompute both exactly:
    order1 = [i + 1 for i in result_steps]
    assert sorted(result_steps) == list(range(len(steps))), "lost steps"
    exact_author, nr_author = chain_cost(rec, list(range(len(steps))), True)
    exact_baked, nr_baked = chain_cost(rec, result_steps, True)
    v2 = check_steps(rec, result_steps)
    gap = (exact_baked - tot_lb) / exact_baked if exact_baked > 0 else 0.0
    return {
        "flavor": flavor, "id": rec["id"], "steps": len(steps), "blocks": nblocks, "segments": len(segs),
        "author_s": round(exact_author, 1), "baked_s": round(exact_baked, 1), "lower_bound_s": round(min(tot_lb, exact_baked), 1),
        "opt_gap": round(max(0.0, gap), 4), "method": "+".join(sorted(methods)) or "none",
        "solve_s": round(time.time() - t0, 2), "violations": violations + v2, "dropped_edges": dropped,
        "lb_exact": int(exact_segs == len(segs)), "noroute_author": nr_author, "noroute_baked": nr_baked,
        "sum": rec["sum"], "n": rec["n"], "cmv": cm.get("version"), "taxi": cm.get("taxi"), "order": order1,
    }


def chain_cost(rec, order, count_noroute=False):
    """travel seconds of a full step order, located steps only, from the guide start"""
    m, start = rec["m"], rec["start"]
    t, prev, nr = 0.0, None, 0
    for i in order:
        p = rec["steps"][i][5]
        if p < 0:
            continue
        if rec["steps"][i][0] == "H":      # use the hearthstone: the cost model's hearth cost, not the trip
            t += HEARTH
            prev = p
            continue
        v = start[p] if prev is None else m[prev][p]
        t += NOROUTE if v < 0 else v
        nr += v < 0
        prev = p
    return (t, nr) if count_noroute else t


def check_steps(rec, order):
    """independent step-level check of the hard rules (A<C<T, PRE kept by the author, anchors in place)"""
    steps = rec["steps"]
    pos = {i: k for k, i in enumerate(order)}
    bad = 0
    by_q = {}
    for i, s in enumerate(steps):
        if s[2]:
            by_q.setdefault(s[2], []).append(i)
    for q, idx in by_q.items():
        for i in idx:
            for j in idx:
                if i < j:
                    ki, kj = steps[i][1], steps[j][1]
                    rank = {"A": 0, "C": 1, "T": 2}
                    if ki in rank and kj in rank and rank[ki] < rank[kj] and pos[i] > pos[j]:
                        bad += 1
    tin = {}
    for i, s in enumerate(steps):
        if s[1] == "T" and s[2]:
            tin.setdefault(s[2], []).append(i)
    for i, s in enumerate(steps):
        if s[3]:
            for p in s[3]:
                for t in tin.get(p, []):
                    if t < i and pos[t] > pos[i]:
                        bad += 1
    # anchors: the set of steps before each anchor must be the same as in the author order
    seen = set()
    for k, i in enumerate(order):
        s = steps[i]
        if s[6] or s[1] == "O":
            if seen != set(range(i)):
                bad += 1
        seen.add(i)
    return bad


def encode(order):
    """'1-5,9,6-8' run-length string of 1-based step indices"""
    out, i = [], 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and order[j + 1] == order[j] + 1:
            j += 1
        out.append(str(order[i]) if i == j else "%d-%d" % (order[i], order[j]))
        i = j + 1
    return ",".join(out)


def model_keeps(r):
    """the optimizer's own rule: no violation and more than 1 s faster in the model"""
    return r["violations"] == 0 and r["baked_s"] < r["author_s"] - 1.0


def write_lua(flavor, rows, path):
    keep = sorted((r for r in rows if model_keeps(r)), key=lambda r: r["id"])
    path = os.path.realpath(path)    # a linked RouteOrder file (a worktree's) is written where it lives, the link stays
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".part", "w") as f:
        f.write("-- Completionist's Guide :: RouteOrder_%s.lua - GENERATED %s by tools/optimize_routes.py\n" % (flavor, time.strftime("%Y-%m-%d")))
        f.write("-- Baked step order per quest guide (offline route optimizer, FINISH_PLAN W3). Own data: travel times from\n")
        f.write("-- the addon's TravelGraph (tools/cost_matrix.lua). Applied by Core/Guide.lua G.Steps only when the guide's step\n")
        f.write("-- count and checksum still match; otherwise the author order is used. /cr options: routing.baked.\n")
        f.write("-- n = steps, sum = checksum, o = 1-based author step indices in baked order (a-b = run).\n")
        f.write("local _, NS = ...\n")
        f.write("if (NS.dataFlavor or NS.flavor) ~= %s then return end\n" % json.dumps(flavor))
        f.write("NS.RouteOrder = NS.RouteOrder or {}\nlocal O = NS.RouteOrder\n")
        for r in keep:
            f.write("O[%s] = { n = %d, sum = %d, o = %s }\n" % (json.dumps(r["id"]), r["n"], r["sum"], json.dumps(encode(r["order"]))))
    os.replace(path + ".part", path)
    return len(keep)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("flavor")
    ap.add_argument("--in", dest="inp")
    ap.add_argument("--out")
    ap.add_argument("--lua-out", help="RouteOrder file to write (default CompletionRoute/Data/RouteOrder_<flavor>.lua)")
    ap.add_argument("--limit-s", type=float, default=None, help="cap the per-guide time limit (default min(30, 2+0.12*blocks))")
    ap.add_argument("--guide")
    ap.add_argument("--dp-time", type=float, default=6.0, help="seconds the exact metric DP may spend per segment")
    ap.add_argument("--dp-cap", type=int, default=400000, help="subset cap of the exact metric DP (lower bound)")
    ap.add_argument("--no-write", action="store_true", help="do not write the RouteOrder file")
    ap.add_argument("--merge", action="store_true", help="keep rows from an earlier --out file for guides not in this input")
    a = ap.parse_args()
    fl = a.flavor
    inp = a.inp or os.path.join(TMP, "costmx", fl + ".jsonl")
    outp = a.out or os.path.join(TMP, "routeopt", fl + ".jsonl")
    lua_out = a.lua_out or os.path.join(REPO, "CompletionRoute", "Data", "RouteOrder_%s.lua" % fl)
    os.makedirs(os.path.dirname(os.path.abspath(outp)), exist_ok=True)
    rows = []
    prev = {}
    if a.merge and os.path.exists(outp):
        for line in open(outp):
            r = json.loads(line)
            prev[r["id"]] = r
    t0 = time.time()
    with open(outp + ".part", "w") as fo:
        for k, line in enumerate(open(inp)):
            rec = json.loads(line)
            if a.guide and rec["id"] != a.guide:
                continue
            if checksum(rec["steps"]) != rec["sum"]:
                print("checksum mismatch (Lua vs Python) for", rec["id"], file=sys.stderr)
                sys.exit(2)
            r = solve_guide(rec, a.limit_s, fl, a.dp_cap, a.dp_time)
            rows.append(r)
            prev.pop(r["id"], None)
            fo.write(json.dumps(r) + "\n")
            fo.flush()
            if len(rows) % 10 == 0:
                print("%d guides %.0fs last %s blocks=%d author=%.0f baked=%.0f lb=%.0f %s" % (
                    len(rows), time.time() - t0, r["id"], r["blocks"], r["author_s"], r["baked_s"], r["lower_bound_s"], r["method"]), file=sys.stderr)
    rows += list(prev.values())
    with open(outp + ".part", "w") as fo:
        for r in rows:
            fo.write(json.dumps(r) + "\n")
    os.replace(outp + ".part", outp)
    nviol = sum(r["violations"] for r in rows)
    if not a.no_write:
        n = write_lua(fl, rows, lua_out)
        print("wrote %s: %d of %d guides baked" % (lua_out, n, len(rows)), file=sys.stderr)
    print("DONE %s: %d guides %.0fs, violations=%d -> %s" % (fl, len(rows), time.time() - t0, nviol, outp), file=sys.stderr)


if __name__ == "__main__":
    main()
