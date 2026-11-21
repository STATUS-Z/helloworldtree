-- Hello World Tree — SQL adapter.
--
-- SQL is how the vessel answers questions about itself. The graph is two tables; every interesting
-- property is a join.
--
-- The queries here are not examples. They are the four queries the visualisation layer runs, written
-- against the schema the Rust and TypeScript sides both produce. Keeping them in the repository means
-- the schema is tested by something that actually uses it.

-- ── Schema ───────────────────────────────────────────────────────────────────
-- Nodes carry no weight column. A dead vessel has no data, so there is nothing to weight, and adding
-- the column before there is data invites someone to invent values for it.
--
-- The weight column exists in `node_weight` instead, which is a separate table joined at read time.
-- That way "no data" is an empty join rather than a zero that looks like a real measurement.

CREATE TABLE IF NOT EXISTS node (
    id          TEXT PRIMARY KEY,
    source      TEXT    NOT NULL,
    kind        TEXT    NOT NULL,
    label       TEXT    NOT NULL,
    meta_json   TEXT
);

CREATE TABLE IF NOT EXISTS edge (
    from_id     TEXT    NOT NULL REFERENCES node(id) ON DELETE CASCADE,
    to_id       TEXT    NOT NULL REFERENCES node(id) ON DELETE CASCADE,
    kind        TEXT    NOT NULL,
    PRIMARY KEY (from_id, to_id, kind)
);

-- Weights arrive later and are additive. A node with no row here is unweighted, which is a fact rather
-- than a zero.
CREATE TABLE IF NOT EXISTS node_weight (
    node_id     TEXT PRIMARY KEY REFERENCES node(id) ON DELETE CASCADE,
    weight      REAL NOT NULL CHECK (weight >= 0 AND weight <= 1),
    measured_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_edge_from ON edge(from_id);
CREATE INDEX IF NOT EXISTS idx_edge_to   ON edge(to_id);
CREATE INDEX IF NOT EXISTS idx_node_kind ON node(kind);

-- ── Query 1: degree, without a correlated subquery ──────────────────────────
-- The naive version runs one subquery per node. This runs two aggregations and joins them, which is a
-- single pass over each side of the edge table.

WITH outbound AS (
    SELECT from_id AS id, COUNT(*) AS out_deg
    FROM edge
    GROUP BY from_id
),
inbound AS (
    SELECT to_id AS id, COUNT(*) AS in_deg
    FROM edge
    GROUP BY to_id
)
SELECT
    n.id,
    n.kind,
    n.label,
    COALESCE(o.out_deg, 0) AS out_degree,
    COALESCE(i.in_deg, 0)  AS in_degree,
    COALESCE(o.out_deg, 0) + COALESCE(i.in_deg, 0) AS total_degree,
    w.weight
FROM node n
LEFT JOIN outbound o ON o.id = n.id
LEFT JOIN inbound  i ON i.id = n.id
LEFT JOIN node_weight w ON w.node_id = n.id
ORDER BY total_degree DESC, n.id;

-- ── Query 2: the imports nothing uses ───────────────────────────────────────
-- An imported symbol with no incoming reference is a symbol that exists only to be named. Those are
-- either dead code or a dependency the author thought they needed, and both are worth seeing.

SELECT
    n.id,
    n.label,
    COUNT(DISTINCT e.from_id) AS importers
FROM node n
LEFT JOIN edge e
       ON e.to_id = n.id
      AND e.kind <> 'imports'
WHERE n.kind = 'import'
GROUP BY n.id, n.label
HAVING COUNT(DISTINCT e.from_id) = 0
ORDER BY n.label;

-- ── Query 3: the largest cluster, found by connected component ──────────────
-- Recursive CTE. Postgres and DuckDB both accept this form; the vessel does not depend on which.
-- Depth is capped so a malformed graph cannot run forever.

WITH RECURSIVE walk(root, current, depth, path) AS (
    SELECT id, id, 0, ARRAY[id]
    FROM node
    WHERE kind = 'file'

    UNION ALL

    SELECT
        w.root,
        e.to_id,
        w.depth + 1,
        w.path || e.to_id
    FROM walk w
    JOIN edge e ON e.from_id = w.current
    WHERE w.depth < 12
      AND NOT (e.to_id = ANY (w.path))
)
SELECT
    root,
    COUNT(DISTINCT current) AS component_size
FROM walk
GROUP BY root
ORDER BY component_size DESC
LIMIT 10;

-- ── Query 4: what is unweighted, and therefore what the vessel does not yet know ──
-- This is the query that matters most on a dead vessel: it returns everything, because nothing has
-- flowed yet. That is the correct answer, not a bug.

SELECT
    n.kind,
    COUNT(*)                            AS nodes,
    COUNT(w.node_id)                    AS weighted,
    COUNT(*) - COUNT(w.node_id)         AS unweighted
FROM node n
LEFT JOIN node_weight w ON w.node_id = n.id
GROUP BY n.kind
ORDER BY unweighted DESC;

-- ── Trigger: refuse a weight of zero ────────────────────────────────────────
-- A weight of exactly zero means "measured and found weightless", which is a real and rare finding.
-- More common is "someone passed through a default". Requiring a timestamp makes the distinction
-- visible: a zero with a time is a measurement, a zero without one cannot exist.

CREATE TRIGGER IF NOT EXISTS require_measurement_time
BEFORE INSERT ON node_weight
FOR EACH ROW
WHEN NEW.measured_at IS NULL OR NEW.measured_at = ''
BEGIN
    SELECT RAISE(ABORT, 'weight must carry a measurement timestamp');
END;
