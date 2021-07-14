{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

module Vehicle.Core.AST.DSL where

import Data.Sequence (Seq)
import Data.Set qualified as Set (singleton)

import Vehicle.Core.AST.Builtin
import Vehicle.Core.AST.Core
import Vehicle.Core.AST.DeBruijn
import Vehicle.Core.AST.Constraint
import Vehicle.Core.AST.Utils
import Vehicle.Prelude


-- * DSL for writing kinds as info annotations

(~>) :: Monoid ann => Expr name binder ann -> Expr name binder ann -> Expr name binder ann
x ~> y = Fun mempty x y

con :: Monoid ann => Builtin AbstractBuiltinOp -> Expr name binder ann
con = Builtin mempty

app :: Monoid ann => Expr name binder ann -> Expr name binder ann -> Expr name binder ann
app = App mempty

tStar :: Monoid ann => Expr name binder ann
tStar = Star mempty

tPrim :: Monoid ann => PrimitiveType -> Expr name binder ann
tPrim = con . PrimitiveType

tPrimNumber :: Monoid ann => PrimitiveNumber -> Expr name binder ann
tPrimNumber = tPrim . Number

tPrimTruth :: Monoid ann => PrimitiveTruth -> Expr name binder ann
tPrimTruth = tPrim . Truth

tBool, tProp, tNat, tInt, tReal :: Monoid ann => Expr name binder ann
tBool    = tPrimTruth Bool
tProp    = tPrimTruth Prop
tNat     = tPrimNumber Nat
tInt     = tPrimNumber Int
tReal    = tPrimNumber Real

tTensor :: Monoid ann => Expr name binder ann -> Expr name binder ann -> Expr name binder ann
tTensor tDim tElem = con Tensor `app` tDim `app` tElem

tList :: Monoid ann => Expr name binder ann -> Expr name binder ann
tList tElem = con List `app` tElem

eList :: Monoid ann => Seq (Expr name binder ann) -> Expr name binder ann
eList = Seq mempty


data TypedAnn = TypedAnn (DeBruijnExpr TypedAnn) Provenance
type TypedExpr = DeBruijnExpr TypedAnn

instance Semigroup TypedAnn where
  t1 <> t2 = _

instance Monoid TypedAnn where
  mempty = _

-- TODO figure out how to do this without horrible -1 hacks
tForall
  :: Constraints
  -> TypedExpr
  -> (TypedExpr -> TypedExpr)
  -> TypedExpr
tForall constraints k f = quantBody
  where
    badBody   = f (Bound _ (Index (-1)))
      --(tStar :*: mempty)
    body      = liftDeBruijn (-1) badBody
    quantBody = Forall _ (Binder _ Machine) constraints body
      -- (kType :*: mempty)
      -- (k :*: mempty)

constrainedTForall
  :: Provenance
  -> ConstraintType
  -> TypedExpr
  -> (TypedExpr -> TypedExpr)
  -> TypedExpr
constrainedTForall p constraintType = tForall constraints
  where constraints = Set.singleton (Constraint p constraintType)

unconstrainedTForall
  :: TypedExpr
  -> (TypedExpr -> TypedExpr)
  -> TypedExpr
unconstrainedTForall = tForall mempty

-- |Return the kind for builtin exprs.
typeOf :: Provenance -> Builtin AbstractBuiltinOp -> TypedExpr
typeOf p = \case
  PrimitiveType _ -> tStar
  List            -> tStar ~> tStar
  Tensor          -> tStar ~> tList tNat ~> tStar
  Op op           -> typeOfAbstractOp p op

typeOfAbstractOp :: Provenance -> AbstractBuiltinOp -> TypedExpr
typeOfAbstractOp p = \case
  If   -> unconstrainedTForall tStar $ \t -> tProp ~> t ~> t
  Cons -> unconstrainedTForall tStar $ \t -> t ~> tList t ~> tList t

  Impl -> typeOfBoolOp2 p
  And  -> typeOfBoolOp2 p
  Or   -> typeOfBoolOp2 p
  Not  -> typeOfBoolOp1 p

  Eq   -> typeOfEqualityOp p
  Neq  -> typeOfEqualityOp p

  Le   -> typeOfComparisonOp p
  Lt   -> typeOfComparisonOp p
  Ge   -> typeOfComparisonOp p
  Gt   -> typeOfComparisonOp p

  Add  -> typeOfNumOp2 p HasAdd
  Sub  -> typeOfNumOp2 p HasSub
  Mul  -> typeOfNumOp2 p HasMul
  Div  -> typeOfNumOp2 p HasDiv
  Neg  -> typeOfNumOp1 p HasNeg

  At   -> typeOfAtOp p

  All  -> typeOfQuantifierOp p
  Any  -> typeOfQuantifierOp p

typeOfEqualityOp :: Provenance -> TypedExpr
typeOfEqualityOp p =
  constrainedTForall p Distinguishable tStar $ \t ->
    constrainedTForall p Truthy tStar $ \r ->
      t ~> t ~> r

typeOfComparisonOp :: Provenance -> TypedExpr
typeOfComparisonOp p =
  constrainedTForall p Comparable tStar $ \t ->
    constrainedTForall p Truthy tStar $ \r ->
      t ~> t ~> r

typeOfBoolOp2 :: Provenance -> TypedExpr
typeOfBoolOp2 p =
  constrainedTForall p Truthy tStar $ \t ->
    t ~> t ~> t

typeOfBoolOp1 :: Provenance -> TypedExpr
typeOfBoolOp1 p =
  constrainedTForall p Truthy tStar $ \t ->
    t ~> t

typeOfNumOp2 :: Provenance -> ConstraintType -> TypedExpr
typeOfNumOp2 p constraintType =
  constrainedTForall p constraintType tStar $ \t ->
    t ~> t ~> t

typeOfNumOp1 :: Provenance -> ConstraintType -> TypedExpr
typeOfNumOp1 p constraintType =
  constrainedTForall p constraintType tStar $ \t ->
    t ~> t

typeOfQuantifierOp :: Provenance -> TypedExpr
typeOfQuantifierOp p =
  constrainedTForall p Quantifiable tStar $ \t
    -> t ~> (t ~> tProp) ~> tProp

typeOfAtOp :: Provenance -> TypedExpr
typeOfAtOp p =
  constrainedTForall p Indexable tStar $ \t ->
    t ~> tNat ~> t


typeOfConcreteOp :: ConcreteBuiltinOp -> TypedExpr
typeOfConcreteOp = \case
  ConcIf              -> unconstrainedTForall tStar $ \t -> tProp ~> t ~> t

  ConcImpl truth      -> tPrimTruth truth ~> tPrimTruth truth ~> tPrimTruth truth
  ConcAnd  truth      -> tPrimTruth truth ~> tPrimTruth truth ~> tPrimTruth truth
  ConcOr   truth      -> tPrimTruth truth ~> tPrimTruth truth ~> tPrimTruth truth
  ConcNot  truth      -> tPrimTruth truth ~> tPrimTruth truth

  ConcEq  arg truth   -> tPrim arg ~> tPrim arg ~> tPrimTruth truth
  ConcNeq arg truth   -> tPrim arg ~> tPrim arg ~> tPrimTruth truth

  ConcLe  num truth   -> tPrimNumber num ~> tPrimNumber num ~> tPrimTruth truth
  ConcLt  num truth   -> tPrimNumber num ~> tPrimNumber num ~> tPrimTruth truth
  ConcGe  num truth   -> tPrimNumber num ~> tPrimNumber num ~> tPrimTruth truth
  ConcGt  num truth   -> tPrimNumber num ~> tPrimNumber num ~> tPrimTruth truth

  ConcAdd num         -> tPrimNumber num ~> tPrimNumber num ~> tPrimNumber num
  ConcSub num         -> tPrimNumber num ~> tPrimNumber num ~> tPrimNumber num
  ConcMul num         -> tPrimNumber num ~> tPrimNumber num ~> tPrimNumber num
  ConcDiv num         -> tPrimNumber num ~> tPrimNumber num ~> tPrimNumber num
  ConcNeg num         -> tPrimNumber num ~> tPrimNumber num

  ConcCons            -> unconstrainedTForall tStar $ \t -> t ~> tList t ~> tList t

  ConcAt  ListContainer          -> unconstrainedTForall tStar $ \t -> tList t ~> tNat ~> t
  ConcAt  TensorContainer        -> unconstrainedTForall tStar $ \t -> unconstrainedTForall tNat $ \d -> tTensor t d ~> tNat ~> t
  ConcAt  SetContainer           -> error "Cannot index into sets"

  ConcAll ListContainer result   -> unconstrainedTForall tStar $ \t -> tList t ~> (t ~> tPrimTruth result) ~> tPrimTruth result
  ConcAny ListContainer result   -> unconstrainedTForall tStar $ \t -> tList t ~> (t ~> tPrimTruth result) ~> tPrimTruth result

  ConcAll TensorContainer result -> unconstrainedTForall tStar $ \t -> unconstrainedTForall tNat $ \d -> tTensor t d ~> (t ~> tPrimTruth result) ~> tPrimTruth result
  ConcAny TensorContainer result -> unconstrainedTForall tStar $ \t -> unconstrainedTForall tNat $ \d -> tTensor t d ~> (t ~> tPrimTruth result) ~> tPrimTruth result

  ConcAll SetContainer Prop      -> unconstrainedTForall tStar $ \t -> (t ~> tBool) ~> (t ~> tProp) ~> tProp
  ConcAny SetContainer Prop      -> unconstrainedTForall tStar $ \t -> (t ~> tBool) ~> (t ~> tProp) ~> tProp

  ConcAll SetContainer Bool      -> error "Cannot quantify over bool"
  ConcAny SetContainer Bool      -> error "Cannot quantify over bool"
