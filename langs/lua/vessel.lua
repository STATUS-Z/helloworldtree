-- Hello World Tree — Lua adapter.
--
-- Lua is one of the four languages in the non-web toolchain (Rust + Lua + QML + Perl), and its job is
-- the embedding layer: a scripting surface that lives *inside* the Rust host.
--
-- That means this file has a different relationship to the vessel than the others. The other adapters
-- are run once, at analysis time, by something outside them. This one is loaded by the host and can be
-- called repeatedly while the vessel is already open, which is what makes interactive exploration
-- possible without a recompile.
--
-- Small, embeddable, and no build step — the three properties that make that possible. Lua has all
-- three and nothing else in the set does.

local M = {}

M.VERSION = "0.1.0"
M.LANGUAGE = "lua"

-- ── Node and edge ────────────────────────────────────────────────────────────
-- Plain tables. Lua has no records, and a metatable for a three-field struct would cost more than it
-- saves. The contract is the field names, not the type.

local function node(kind, label, line)
  return {
    id = nil,           -- filled by the caller, because it needs the filename
    source = M.LANGUAGE,
    kind = kind,
    label = label,
    line = line or 0,
  }
end

local function edge(from, to, kind)
  return { from = from, to = to, kind = kind }
end

-- ── The vessel ───────────────────────────────────────────────────────────────
-- The host owns the real graph. This is a lightweight local accumulator that the host merges in, which
-- keeps the boundary simple: the adapter returns plain data and never mutates host state.

local Graph = {}
Graph.__index = Graph

function Graph.new()
  return setmetatable({
    nodes = {},
    order = {},
    seen = {},
    edges = {},
    edge_seen = {},
  }, Graph)
end

function Graph:add(n)
  if self.seen[n.id] then
    return self
  end
  self.seen[n.id] = true
  self.order[#self.order + 1] = n.id
  self.nodes[n.id] = n
  return self
end

function Graph:link(e)
  -- Deduplicate on the triple. A graph that admits duplicates is not queryable.
  local key = e.from .. "\31" .. e.to .. "\31" .. e.kind
  if self.edge_seen[key] then
    return self
  end
  self.edge_seen[key] = true
  self.edges[#self.edges + 1] = e
  return self
end

function Graph:list()
  local out = {}
  for i, id in ipairs(self.order) do
    out[i] = self.nodes[id]
  end
  return out
end

function Graph:counts()
  return #self.order, #self.edges
end

-- ── Extraction ───────────────────────────────────────────────────────────────
-- Pattern-driven. Lua patterns are not regex, which is a limitation worth naming: there is no
-- alternation and no repetition operator. That is fine for line-anchored keyword matching, which is
-- all this needs.

local PATTERNS = {
  fn = "^%s*function%s+([%w_%.:]+)",
  local_fn = "^%s*local%s+function%s+([%w_]+)",
  assign_fn = "^%s*([%w_%.]+)%s*=%s*function",
  local_assign_fn = "^%s*local%s+([%w_]+)%s*=%s*function",
  require = "^%s*local%s+[%w_]+%s*=%s*require%s*[%(]?['\"]([^'\"]+)['\"]",
  require_bare = "^%s*require%s*[%(]?['\"]([^'\"]+)['\"]",
}

local function first_capture(line, ...)
  local patterns = { ... }
  for _, pat in ipairs(patterns) do
    local m = line:match(pat)
    if m then
      return m
    end
  end
  return nil
end

--- Extract a skeleton from one source file.
--
-- @param filename string
-- @param source string
-- @return Graph
function M.extract(filename, source)
  local g = Graph.new()
  local file_id = filename .. ":file"

  g:add({
    id = file_id,
    source = M.LANGUAGE,
    kind = "file",
    label = filename,
    line = 0,
  })

  local line_no = 0
  for line in (source .. "\n"):gmatch("(.-)\n") do
    line_no = line_no + 1

    -- Comments are not declarations.
    if not line:match("^%s*%-%-") then
      local name = first_capture(
        line,
        PATTERNS.fn,
        PATTERNS.local_fn,
        PATTERNS.assign_fn,
        PATTERNS.local_assign_fn
      )

      if name then
        local id = filename .. ":" .. name
        g:add({
          id = id,
          source = M.LANGUAGE,
          kind = "symbol",
          label = name,
          line = line_no,
        })
        g:link(edge(file_id, id, "contains"))
      else
        local mod = line:match(PATTERNS.require) or line:match(PATTERNS.require_bare)
        if mod then
          local id = "import:" .. mod:gsub("[%./]", "_")
          g:add({
            id = id,
            source = M.LANGUAGE,
            kind = "import",
            label = mod,
            line = line_no,
          })
          g:link(edge(file_id, id, "imports"))
        end
      end
    end
  end

  return g
end

--- A compact readout for the host log.
function M.digest(g)
  local nodes, edges = g:counts()
  local kinds = {}
  for _, n in ipairs(g:list()) do
    kinds[n.kind] = (kinds[n.kind] or 0) + 1
  end

  local parts = {}
  for k, v in pairs(kinds) do
    parts[#parts + 1] = k .. "=" .. v
  end
  table.sort(parts)

  return string.format("%s: %d nodes, %d edges [%s]", M.LANGUAGE, nodes, edges, table.concat(parts, ", "))
end

-- ── Self-test ────────────────────────────────────────────────────────────────

local function selftest()
  local sample = [[
local json = require("json")
local util = require("util")

local function helper(x)
  return x + 1
end

function M.main()
  return helper(41)
end

local speak = function() return "hello" end
]]

  local g = M.extract("demo.lua", sample)
  print(M.digest(g))
  for _, n in ipairs(g:list()) do
    print(string.format("  %-10s %s", n.kind, n.label))
  end

  -- Merging the same graph twice must not duplicate anything.
  local before = select(1, g:counts())
  for _, n in ipairs(g:list()) do
    g:add(n)
  end
  assert(select(1, g:counts()) == before, "deduplication failed")

  print("selftest ok")
end

if ... == "selftest" then
  selftest()
end

return M
