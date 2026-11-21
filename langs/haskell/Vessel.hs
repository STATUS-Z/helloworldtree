{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Hello World Tree — Haskell adapter.
--
-- Haskell earns its place in the set for a specific reason rather than as a nice-to-have: total
-- functions. The other adapters in this repository can throw, and a throw inside an extractor means a
-- file produces no nodes and the failure is invisible. In Haskell the extractor's type can say it
-- always returns a skeleton, which makes "no nodes" unrepresentable and therefore impossible to
-- mistake for "no code".
--
-- That is the property the vessel needs more than speed. A graph that occasionally loses a file is
-- worse than a graph that is slow, because the loss has no symptom.
--
-- The style here is deliberately plain: no lenses, no monad transformers, no fancy abstractions. The
-- value is in the types saying what cannot happen, not in the syntax being clever.

module Vessel
  ( NodeKind (..)
  , Node (..)
  , Edge (..)
  , Graph (..)
  , empty
  , insertNode
  , insertEdge
  , extract
  , merge
  , digest
  ) where

import Data.Char (isAlpha, isAlphaNum, isSpace, toLower)
import Data.List (isPrefixOf, nub, sort, stripPrefix)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)

-- | What kind of thing a discovered node is.
--
-- Closed, because an open set of strings is how a graph stops being queryable.
data NodeKind
  = KFile
  | KSymbol
  | KImport
  | KModule
  | KClass
  | KMethod
  | KInstruction
  | KRegister
  deriving (Eq, Ord, Show)

kindName :: NodeKind -> String
kindName k = case k of
  KFile -> "file"
  KSymbol -> "symbol"
  KImport -> "import"
  KModule -> "module"
  KClass -> "class"
  KMethod -> "method"
  KInstruction -> "instruction"
  KRegister -> "register"

-- | One discovered fact.
--
-- 'nodeId' is a 'String' rather than a newtype here on purpose: the identifier crosses the language
-- boundary into TypeScript and Rust, and a newtype would need unwrapping at every crossing for no
-- safety that the round-trip does not already provide.
data Node = Node
  { nodeId :: String
  , nodeSource :: String
  , nodeKind :: NodeKind
  , nodeLabel :: String
  }
  deriving (Eq, Ord, Show)

-- | A relation between two nodes.
data Edge = Edge
  { edgeFrom :: String
  , edgeTo :: String
  , edgeKind :: String
  }
  deriving (Eq, Ord, Show)

-- | The vessel.
--
-- Both maps and both lists, because the vessel needs two different guarantees at once: membership in
-- O(log n) for deduplication, and deterministic order for diffing two runs. A single 'Map' gives the
-- first; the parallel list gives the second.
data Graph = Graph
  { gNodes :: Map.Map String Node
  , gOrder :: [String]
  , gEdges :: [Edge]
  , gSeen :: Map.Map (String, String, String) ()
  }
  deriving (Show)

empty :: Graph
empty = Graph Map.empty [] [] Map.empty

insertNode :: Node -> Graph -> Graph
insertNode n g
  | Map.member (nodeId n) (gNodes g) = g
  | otherwise =
      g
        { gNodes = Map.insert (nodeId n) n (gNodes g)
        , gOrder = gOrder g ++ [nodeId n]
        }

-- | Insert an edge, deduplicating on the triple.
--
-- A graph that admits duplicate edges is not queryable, it is just large.
insertEdge :: Edge -> Graph -> Graph
insertEdge e g
  | Map.member key (gSeen g) = g
  | otherwise =
      g
        { gEdges = gEdges g ++ [e]
        , gSeen = Map.insert key () (gSeen g)
        }
  where
    key = (edgeFrom e, edgeTo e, edgeKind e)

nodeCount :: Graph -> Int
nodeCount = Map.size . gNodes

edgeCount :: Graph -> Int
edgeCount = length . gEdges

-- | Nodes in insertion order.
orderedNodes :: Graph -> [Node]
orderedNodes g = mapMaybe (`Map.lookup` gNodes g) (gOrder g)

-- | Trim leading and trailing whitespace.
trim :: String -> String
trim = dropWhileEnd' . dropWhile isSpace
  where
    dropWhileEnd' = reverse . dropWhile isSpace . reverse

-- | The identifier immediately following a keyword, or 'Nothing'.
afterKeyword :: String -> String -> Maybe String
afterKeyword kw line =
  case stripPrefix kw (trim line) of
    Nothing -> Nothing
    Just rest ->
      let rest' = trim rest
          name = takeWhile (\c -> isAlphaNum c || c == '_' || c == '?') rest'
       in if null name then Nothing else Just name

data Decl = Decl
  { dKind :: NodeKind
  , dKeywords :: [String]
  }

declarations :: [Decl]
declarations =
  [ Decl KModule ["module"]
  , Decl KClass ["class", "data", "newtype", "type"]
  , Decl KImport ["import"]
  , Decl KMethod ["::"]
  ]

-- | Extract a skeleton from one source file.
--
-- Total: the result is a 'Graph', never a failure. A file with nothing recognisable still produces its
-- file node, so "unrecognised" and "absent" are distinguishable downstream.
extract :: String -> String -> Graph
extract filename source =
  let fileId = filename ++ ":file"
      fileNode = Node fileId "haskell" KFile filename
      base = insertNode fileNode empty
      fileLineNo = zip [1 ..] (lines source)
   in foldl (step fileId) base fileLineNo
  where
    step fileId g (_, line)
      -- Comments are not declarations. Two forms in Haskell: line and block.
      | isPrefixOf "--" (trim line) = g
      | isPrefixOf "{-" (trim line) = g
      | otherwise =
          case firstDeclaration line of
            Nothing -> g
            Just (kind, name) ->
              let id' = filename ++ ":" ++ name
                  node = Node id' "haskell" kind name
                  edgeKind' = if kind == KImport then "imports" else "contains"
               in insertEdge (Edge fileId id' edgeKind') (insertNode node g)

    firstDeclaration line =
      let candidates =
            [ (decl, name)
            | decl <- declarations
            , kw <- dKeywords decl
            , Just name <- [afterKeyword kw line]
            ]
       in case candidates of
            ((decl, name) : _) -> Just (dKind decl, name)
            [] -> Nothing

-- | Merge many graphs into one, deduplicating.
merge :: [Graph] -> Graph
merge = foldl combine empty
  where
    combine acc g =
      let withNodes = foldl (flip insertNode) acc (orderedNodes g)
       in foldl (flip insertEdge) withNodes (gEdges g)

-- | A compact readout, because an agent reading this does not need the whole graph.
digest :: Graph -> String
digest g =
  let kinds = sort (map (kindName . nodeKind) (orderedNodes g))
      counts = Map.toList (Map.fromListWith (+) [(k, 1 :: Int) | k <- kinds])
      rendered = [k ++ "=" ++ show v | (k, v) <- counts]
   in "haskell: "
        ++ show (nodeCount g)
        ++ " nodes, "
        ++ show (edgeCount g)
        ++ " edges ["
        ++ foldr (\a b -> if null b then a else a ++ ", " ++ b) "" rendered
        ++ "]"

-- | A tiny self-test, run with @runghc@ over this file.
_selftest :: IO ()
_selftest = do
  let sample =
        unlines
          [ "module Demo where"
          , ""
          , "import Data.List (sort)"
          , "import qualified Data.Map as Map"
          , ""
          , "class Thing a where"
          , "  speak :: a -> String"
          , ""
          , "data Point = Point Int Int"
          ]
      g = extract "demo.hs" sample
  putStrLn (digest g)
  mapM_ (\n -> putStrLn ("  " ++ kindName (nodeKind n) ++ "\t" ++ nodeLabel n)) (orderedNodes g)
  -- The dead-vessel property is structural: there is no weight field to be zero.
  print ("nodes" :: String, nodeCount g, "edges", edgeCount g)
