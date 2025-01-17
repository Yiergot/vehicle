-- | This module exports the datatype representations of the builtin symbols.

module Vehicle.Language.AST.Builtin
  ( Builtin(..)
  , NumericType(..)
  , BooleanType(..)
  , ContainerType(..)
  , Quantifier(..)
  , Order(..)
  , Equality(..)
  , TypeClass(..)
  , BooleanOp2(..)
  , NumericOp2(..)
  , builtinFromSymbol
  , symbolFromBuiltin
  ) where

import Data.Bifunctor (first)
import GHC.Generics (Generic)
import Control.DeepSeq (NFData)
import Data.Text (pack)
import Data.Hashable (Hashable)

import Vehicle.Prelude

-- TODO all the show instances should really be obtainable from the grammar
-- somehow.

--------------------------------------------------------------------------------
-- Numeric types

data NumericType
  = Nat
  | Int
  | Rat
  | Real
  deriving (Eq, Ord, Show, Generic)

instance NFData   NumericType
instance Hashable NumericType

instance Pretty NumericType where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Boolean types

data BooleanType
  = Bool
  | Prop
  deriving (Eq, Ord, Show, Generic)

instance NFData   BooleanType
instance Hashable BooleanType

instance Pretty BooleanType where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Container types

data ContainerType
  = List
  | Tensor
  deriving (Eq, Ord, Show, Generic)

instance NFData   ContainerType
instance Hashable ContainerType

instance Pretty ContainerType where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Type classes

data TypeClass
  = HasEq
  | HasOrd
  | IsTruth
  | IsNatural
  | IsIntegral
  | IsRational
  | IsReal
  | IsContainer
  | IsQuantifiable
  deriving (Eq, Ord, Generic)

instance NFData   TypeClass
instance Hashable TypeClass

instance Show TypeClass where
  show = \case
    HasEq          -> "HasEq"
    HasOrd         -> "HasOrd"
    IsTruth        -> "IsTruth"
    IsContainer    -> "IsContainer"
    IsNatural      -> "IsNatural"
    IsIntegral     -> "IsIntegral"
    IsRational     -> "IsRational"
    IsReal         -> "IsReal"
    IsQuantifiable -> "IsQuantify"

instance Pretty TypeClass where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Quantifiers

data Quantifier
  = All
  | Any
  deriving (Eq, Ord, Generic)

instance NFData   Quantifier
instance Hashable Quantifier

--------------------------------------------------------------------------------
-- Equality

data Equality
  = Eq
  | Neq
  deriving (Eq, Ord, Generic)

instance NFData   Equality
instance Hashable Equality

instance Show Equality where
  show = \case
    Eq  -> "=="
    Neq -> "!="

instance Pretty Equality where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Orders

data Order
  = Le
  | Lt
  | Ge
  | Gt
  deriving (Eq, Ord, Generic)

instance NFData   Order
instance Hashable Order

instance Show Order where
  show = \case
    Le -> "<="
    Lt -> "<"
    Ge -> ">="
    Gt -> ">"

instance Pretty Order where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Boolean operations

data BooleanOp2
  = Impl
  | And
  | Or
  deriving (Eq, Ord, Generic)

instance NFData   BooleanOp2
instance Hashable BooleanOp2

instance Show BooleanOp2 where
  show = \case
    Impl -> "implies"
    And  -> "and"
    Or   -> "or"

instance Pretty BooleanOp2 where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Numeric operations

data NumericOp2
  = Mul
  | Div
  | Add
  | Sub
  deriving (Eq, Ord, Generic)

instance NFData   NumericOp2
instance Hashable NumericOp2

instance Show NumericOp2 where
  show = \case
    Add -> "+"
    Mul -> "*"
    Div -> "/"
    Sub -> "-"

instance Pretty NumericOp2 where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Builtin

-- |Builtins in the Vehicle language
data Builtin
  -- Types
  = BooleanType   BooleanType
  | NumericType   NumericType
  | ContainerType ContainerType
  -- Expressions
  | If
  | Not
  | BooleanOp2 BooleanOp2
  | Neg
  | NumericOp2 NumericOp2
  | Cons
  | At
  | Map
  | Fold
  | Equality  Equality
  | Order     Order
  | TypeClass TypeClass
  | Quant     Quantifier
  | QuantIn   Quantifier
  deriving (Eq, Ord, Generic)

instance NFData   Builtin
instance Hashable Builtin

instance Pretty Builtin where
  pretty = pretty . show

--------------------------------------------------------------------------------
-- Conversion to symbols

instance Show Builtin where
  show = \case
    BooleanType   t -> show t
    NumericType   t -> show t
    ContainerType t -> show t
    BooleanOp2 op   -> show op
    Not             -> "not"
    NumericOp2 op   -> show op
    Neg             -> "~"
    If              -> "if"
    At              -> "!"
    Cons            -> "::"
    Equality e      -> show e
    Order o         -> show o
    TypeClass tc    -> show tc
    Map             -> "map"
    Fold            -> "fold"
    Quant   All     -> "every"
    Quant   Any     -> "some"
    QuantIn All     -> "everyIn"
    QuantIn Any     -> "someIn"

builtinSymbols :: [(Symbol, Builtin)]
builtinSymbols = map (first pack)
  [ show (BooleanType Bool)     |-> BooleanType Bool
  , show (BooleanType Prop)     |-> BooleanType Prop
  , show (NumericType Nat)      |-> NumericType Nat
  , show (NumericType Int)      |-> NumericType Int
  , show (NumericType Real)     |-> NumericType Real
  , show (ContainerType List)   |-> ContainerType List
  , show (ContainerType Tensor) |-> ContainerType Tensor
  , show If                     |-> If
  , show (BooleanOp2 Impl)      |-> BooleanOp2 Impl
  , show (BooleanOp2 And)       |-> BooleanOp2 And
  , show (BooleanOp2 Or)        |-> BooleanOp2 Or
  , show Not                    |-> Not
  , show (Equality Eq)          |-> Equality Eq
  , show (Equality Neq)         |-> Equality Neq
  , show (Order Le)             |-> Order Le
  , show (Order Lt)             |-> Order Lt
  , show (Order Ge)             |-> Order Ge
  , show (Order Gt)             |-> Order Gt
  , show (NumericOp2 Add)       |-> NumericOp2 Add
  , show (NumericOp2 Mul)       |-> NumericOp2 Mul
  , show (NumericOp2 Div)       |-> NumericOp2 Div
  , show (NumericOp2 Sub)       |-> NumericOp2 Sub
  , show Neg                    |-> Neg
  , show At                     |-> At
  , show Cons                   |-> Cons
  , show (Quant All)            |-> Quant All
  , show (Quant Any)            |-> Quant Any
  , show (QuantIn All)          |-> QuantIn All
  , show (QuantIn Any)          |-> QuantIn Any
  , show Map                    |-> Map
  , show Fold                   |-> Fold
  ]

builtinFromSymbol :: Symbol -> Maybe Builtin
builtinFromSymbol symbol = lookup symbol builtinSymbols

symbolFromBuiltin :: Builtin -> Symbol
symbolFromBuiltin builtin = pack $ show builtin
