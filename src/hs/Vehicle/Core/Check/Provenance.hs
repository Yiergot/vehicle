{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes          #-}

module Vehicle.Core.Check.Provenance where

import           Control.Monad.Writer
import           Data.Range (Range(..), (+=+))
import qualified Data.Range as Range
import           Vehicle.Core.Type
import           Vehicle.Prelude


newtype Provenance = Provenance { fromProvenance :: [Range Position] }

instance Semigroup Provenance where
  r1 <> r2 = Provenance $ fromProvenance r1 `Range.union` fromProvenance r2

instance Monoid Provenance where
  mempty = Provenance []

-- |Get the provenance for a single token.
tkProvenance :: IsToken a => a -> Provenance
tkProvenance tk = Provenance [begin +=+ end]
  where
    begin = tkPos tk
    end   = (line begin, column begin + tkLength tk)


-- |Get the provenance for a single layer.
tellProvenance ::
  (IsToken name, IsToken builtin, KnownSort sort) =>
  TreeF (K name) (K builtin) ann sort sorted -> Writer Provenance ()

tellProvenance (tree :: TreeF name builtin ann sort sorted) = case sortSing :: SSort sort of

  -- Kinds
  SKIND -> case tree of
    KConF  _ann op -> tell (tkProvenance op)
    _              -> return ()

  -- Types
  STYPE -> case tree of
    TVarF _ann n  -> tell (tkProvenance n)
    TConF _ann op -> tell (tkProvenance op)
    _             -> return ()

  -- Type arguments
  STARG -> case tree of
    TArgF _ann n -> tell (tkProvenance n)

  -- Expressions
  SEXPR -> case tree of
    EVarF     _ann n  -> tell (tkProvenance n)
    EConF     _ann op -> tell (tkProvenance op)
    _                 -> return ()

  -- Expression arguments
  SEARG -> case tree of
    EArgF _ann n -> tell (tkProvenance n)

  -- Declarations
  SDECL -> return ()

  -- Programs
  SPROG -> return ()


-- |Save the provenance information for the tree.
saveProvenance ::
  (IsToken name, IsToken builtin, KnownSort sort) =>
  Tree (K name) (K builtin) ann sort ->
  Tree (K name) (K builtin) (K Provenance :*: ann) sort

saveProvenance = _
  where
    go ::
      (forall sort. KnownSort sort => TreeF name builtin ann sort sorted -> Writer Provenance (sorted sort)) ->
      (forall sort. KnownSort sort => Tree  name builtin ann sort        -> Writer Provenance (sorted sort))
    go = _


  -- Prelude.fst . runWriter . sortedFoldM $ \tree -> do
  -- ((), p) <- listen (tellProvenance tree)
  -- return . embed $ updAnn (K p :*:) tree
