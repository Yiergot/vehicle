
module Vehicle.Language.Type
  ( TypingError(..)
  , typeCheck
  ) where

import Prelude hiding (pi)
import Control.Monad (when)
import Control.Monad.Except (MonadError(..), ExceptT)
import Control.Monad.Reader (MonadReader(..), ReaderT(..), asks)
import Control.Monad.State (MonadState, evalStateT)
import Data.Foldable (foldrM)
import Data.Map qualified as Map
import Data.List.NonEmpty qualified as NonEmpty (toList)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Monoid (Endo(..), appEndo)
import Data.Text (pack)

import Vehicle.Prelude
import Vehicle.Language.AST
import Vehicle.Language.DSL
import Vehicle.Language.Type.Core
import Vehicle.Language.Type.Unify
import Vehicle.Language.Type.Meta
import Vehicle.Language.Type.TypeClass
import Vehicle.Language.Print (prettyVerbose)
import Vehicle.Language.Type.MetaSet qualified as MetaSet (null)

typeCheck :: UncheckedProg -> ExceptT TypingError Logger CheckedProg
typeCheck prog = do
  let prog1 = runAll prog
  let prog2 = runReaderT prog1 emptyVariableCtx
  prog3 <- evalStateT prog2 emptyMetaCtx
  return prog3

runAll :: TCM m => UncheckedProg -> m CheckedProg
runAll prog = do
  logDebug $ prettyVerbose prog <> line
  prog2 <- inferProg prog
  metaSubstitution <- solveMetas
  return $ substMetas metaSubstitution prog2

solveMetas :: MonadConstraintSolving m => m MetaSubstitution
solveMetas = do
  logDebug "Starting constraint solving\n"
  constraints <- getConstraints
  solution <- loop $ Progress
    { newConstraints = constraints
    , solvedMetas    = mempty
    }
  logDebug "Finished constraint solving\n"
  return solution
  where
    loop :: MonadConstraintSolving m
         => ConstraintProgress
         -> m MetaSubstitution
    loop progress = do
      allConstraints <- getConstraints
      currentSubstitution <- getMetaSubstitution

      -- If there are no constraints to be solved then return the solution
      if null allConstraints
        then return currentSubstitution

      else case progress of
        Stuck -> throwError $ UnsolvedConstraints (head allConstraints :| tail allConstraints)
        Progress newConstraints solvedMetas -> do
          -- If we have failed to make useful progress last pass then abort
          if MetaSet.null solvedMetas && null newConstraints then
            throwError $ UnsolvedConstraints (head allConstraints :| tail allConstraints)
          -- Otherwise start a new pass
          else do
            logDebug "Starting new pass"

            let updatedConstraints = substMetas currentSubstitution allConstraints
            logDebug $ "current-constraints:" <+> align (prettyVerbose updatedConstraints)

            -- TODO try only the non-blocked metas
            setConstraints []
            newProgress <- mconcat `fmap` traverse tryToSolveConstraint updatedConstraints

            metaSubst <- getMetaSubstitution
            logDebug $ "current-solution:" <+> prettyVerbose metaSubst <> "\n"
            loop newProgress

    tryToSolveConstraint :: MonadConstraintSolving m
                        => Constraint
                        -> m ConstraintProgress
    tryToSolveConstraint constraint@(Constraint ctx baseConstraint) = do
      logDebug $ "trying" <+> prettyVerbose constraint
      incrCallDepth

      result <- case baseConstraint of
        Unify eq  -> solveUnificationConstraint ctx eq
        m `Has` e -> solveTypeClassConstraint ctx m e

      case result of
        Progress newConstraints _ -> addConstraints newConstraints
        Stuck                     -> addConstraints [constraint]

      decrCallDepth
      return result

--------------------------------------------------------------------------------
-- Contexts

-- | The type-checking monad
type TCM m =
  ( MonadError  TypingError m
  , MonadState  MetaCtx     m
  , MonadReader VariableCtx m
  , MonadLogger             m
  )

getDeclCtx :: TCM m => m DeclCtx
getDeclCtx = asks declCtx

addToDeclCtx :: TCM m => Identifier -> CheckedExpr -> Maybe CheckedExpr -> m a -> m a
addToDeclCtx n t e = local add
  where
    add :: VariableCtx -> VariableCtx
    add VariableCtx{..} = VariableCtx{declCtx = Map.insert n (t, e) declCtx, ..}

getBoundCtx :: TCM m => m BoundCtx
getBoundCtx = asks boundCtx

getVariableCtx :: TCM m => m VariableCtx
getVariableCtx = ask

addToBoundCtx :: TCM m => Name -> CheckedExpr -> m a -> m a
addToBoundCtx n e = local add
  where
    add :: VariableCtx -> VariableCtx
    add VariableCtx{..} = VariableCtx{boundCtx = (n, e) : boundCtx, ..}

--------------------------------------------------------------------------------
-- Debug functions

showDeclEntry :: TCM m => Identifier -> m ()
showDeclEntry ident = do
  logDebug ("decl-entry" <+> pretty ident)
  incrCallDepth

showDeclExit :: TCM m => Identifier -> m ()
showDeclExit ident = do
  decrCallDepth
  logDebug ("decl-exit" <+> pretty ident)

showCheckEntry :: TCM m => CheckedExpr -> UncheckedExpr -> m ()
showCheckEntry t e = do
  logDebug ("check-entry" <+> prettyVerbose e <+> "<-" <+> prettyVerbose t)
  incrCallDepth

showCheckExit :: TCM m => CheckedExpr -> m ()
showCheckExit e = do
  decrCallDepth
  logDebug ("check-exit " <+> prettyVerbose e)

showInferEntry :: TCM m => UncheckedExpr -> m ()
showInferEntry e = do
  logDebug ("infer-entry" <+> prettyVerbose e)
  incrCallDepth

showInferExit :: TCM m => (CheckedExpr, CheckedExpr) -> m ()
showInferExit (e, t) = do
  decrCallDepth
  logDebug ("infer-exit " <+> prettyVerbose e <+> "->" <+> prettyVerbose t)

-------------------------------------------------------------------------------
-- Utility functions

assertIsType :: TCM m => Provenance -> CheckedExpr -> m ()
assertIsType _ (Type _) = return ()
-- TODO: add a new TypingError 'ExpectedAType'
assertIsType p e        = do
  ctx <- getBoundCtx
  throwError $ Mismatch p ctx e (Type 0)

unify :: TCM m => Provenance -> CheckedExpr -> CheckedExpr -> m CheckedExpr
unify p e1 e2 = do
  ctx <- getVariableCtx
  addUnificationConstraint p ctx e1 e2
  -- TODO calculate the most general unifier
  return e1

freshMeta :: TCM m
          => Provenance
          -> m (Meta, CheckedExpr)
freshMeta p = do
  ctx <- getBoundCtx
  freshMetaWith ctx p

-- Takes the expected type of a function and the user-provided arguments
-- and traverses through checking each argument type against the type of the
-- matching pi binder and inserting any required implicit/instance arguments.
-- Returns the type of the function when applied to the full list of arguments
-- (including inserted arguments) and that list of arguments.
inferArgs :: TCM m
          => Provenance     -- Provenance of the function
          -> CheckedExpr    -- Type of the function
          -> [UncheckedArg] -- User-provided arguments of the function
          -> m (CheckedExpr, [CheckedArg])
inferArgs p (Pi _ binder tRes) (arg : args)
  | vis binder == vis arg = do
    -- Check the type of the argument.
    checkedArgExpr <- check (binderType binder) (argExpr arg)
    -- Substitute argument in tRes
    let tRes1 = checkedArgExpr `substInto` tRes
    -- Recurse into the list of args
    (tRes2, args1) <- inferArgs p tRes1 args
    -- Return the appropriately annotated type with its inferred kind.
    return (tRes2, replaceArgExpr checkedArgExpr arg : args1)

inferArgs _ (Pi _ binder _) (arg : _)
  | vis binder /= vis arg && vis binder == Explicit =
    throwError $ MissingExplicitArg arg (binderType binder)

-- This case handles either vis binder /= vis arg and vis binder /= Explicit or args == []
inferArgs p (Pi _ binder tRes) args = do
    logDebug ("insert-arg" <+> pretty (vis binder) <+> prettyVerbose (binderType binder))

    (meta, metaExpr) <- freshMeta p

    -- Check if the required argument is a type-class
    let binderVis = vis binder
    when (binderVis == Instance) $ do
      ctx <- getVariableCtx
      addTypeClassConstraint ctx meta (binderType binder)

    -- Substitute meta-variable in tRes
    let tRes1 = metaExpr `substInto` tRes

    (tRes2, args1) <- inferArgs p tRes1 args
    return (tRes2, Arg TheMachine binderVis metaExpr : args1)

inferArgs _p tFun [] = return (tFun, [])

inferArgs p tFun args = do
  ctx <- getBoundCtx
  let mkRes = [Endo $ \tRes -> unnamedPi (vis arg) (tHole ("arg" <> pack (show i))) (const tRes)
              | (i, arg) <- zip [0::Int ..] args]
  let expected = fromDSL (appEndo (mconcat mkRes) (tHole "res"))
  throwError $ Mismatch p ctx tFun expected

inferApp :: TCM m
         => Provenance
         -> CheckedExpr
         -> CheckedExpr
         -> [UncheckedArg]
         -> m (CheckedExpr, CheckedExpr)
inferApp p fun tFun args = do
  (tFun2, args2) <- inferArgs (prov fun) tFun args
  return (normAppList p fun args2, tFun2)

--------------------------------------------------------------------------------
-- Type-checking of expressions

check :: TCM m
      => CheckedExpr   -- Type we're checking against
      -> UncheckedExpr -- Expression being type-checked
      -> m CheckedExpr -- Updated expression
check expectedType expr = do
  showCheckEntry expectedType expr
  res <- case (expectedType, expr) of
    (Pi _ piBinder tRes, Lam p lamBinder body)
      | vis piBinder == vis lamBinder -> do
        checkedLamBinderType <- check (binderType piBinder) (binderType lamBinder)

        addToBoundCtx (binderName lamBinder) checkedLamBinderType $ do
          body' <- check tRes body
          let checkedLamBinder = replaceBinderType checkedLamBinderType lamBinder
          return $ Lam p checkedLamBinder body'

    (Pi _ binder tRes, e) ->
      -- Add the implict argument to the context
      addToBoundCtx Machine (binderType binder) $ do
        -- Check if the type matches the expected result type.
        e' <- check tRes (liftDBIndices 1 e)

        -- Create a new binder mirroring the implicit Pi binder expected
        let lamBinder = Binder mempty TheMachine Implicit (binderName binder) (binderType binder)

        -- Prepend a new lambda to the expression with the implicit binder
        return $ Lam mempty lamBinder e'

    (_, Lam p binder _) -> do
          ctx <- getBoundCtx
          let expected = fromDSL $ unnamedPi (vis binder) (tHole "a") (const (tHole "b"))
          throwError $ Mismatch p ctx expectedType expected

    (_, Hole p _name) -> do
      -- Replace the hole with meta-variable of the expected type.
      -- NOTE, different uses of the same hole name will be interpreted as different meta-variables.
      (_, meta) <- freshMeta p
      unify p meta expectedType

    (_, e@(Type _))          -> viaInfer mempty expectedType e
    (_, e@(Meta _ _))        -> viaInfer mempty expectedType e
    (_, e@(App     p _ _))   -> viaInfer p      expectedType e
    (_, e@(Pi      p _ _))   -> viaInfer p      expectedType e
    (_, e@(Builtin p _))     -> viaInfer p      expectedType e
    (_, e@(Var     p _))     -> viaInfer p      expectedType e
    (_, e@(Let     p _ _ _)) -> viaInfer p      expectedType e
    (_, e@(Literal p _))     -> viaInfer p      expectedType e
    (_, e@(Seq     p _))     -> viaInfer p      expectedType e
    (_, e@(Ann     p _ _))   -> viaInfer p      expectedType e
    (_, PrimDict{})          -> developerError "PrimDict should never be type-checked"

  showCheckExit res
  return res

-- | Takes in an unchecked expression and attempts to infer it's type.
-- Returns the expression annotated with its type as well as the type itself.
infer :: TCM m
      => UncheckedExpr
      -> m (CheckedExpr, CheckedExpr)
infer e = do
  showInferEntry e
  res <- case e of
    Type l ->
      return (Type l , Type (l + 1))

    Meta _ m -> developerError $ "Trying to infer the type of a meta-variable" <+> pretty m

    Hole ann s ->
      throwError $ UnresolvedHole (prov ann) s

    Ann ann expr t   -> do
      (t', _) <- infer t
      expr' <- check t' expr
      return (Ann ann expr' t' , t')

    App p fun args -> do
      (fun', tFun') <- infer fun
      inferApp p fun' tFun' (NonEmpty.toList args)

    Pi p binder res -> do
      (checkedBinderType, tArg') <- infer (binderType binder)

      addToBoundCtx (binderName binder) checkedBinderType $ do
        (res', tRes') <- infer res
        let t' = tArg' `tMax` tRes'
        return (Pi p (replaceBinderType checkedBinderType binder) res' , t')

    Var p (Bound i) -> do
      -- Lookup the type of the variable in the context.
      ctx <- getBoundCtx
      case ctx !!? i of
        Just (_, t') -> do
          let t'' = liftDBIndices (i+1) t'
          return (Var p (Bound i), t'')
        Nothing      -> developerError $
          "Index" <+> pretty i <+> "out of bounds when looking" <+>
          "up variable in context" <+> prettyVerbose ctx <+> "at" <+> pretty p

    Var p (Free ident) -> do
      -- Lookup the type of the declaration variable in the context.
      ctx <- getDeclCtx
      case Map.lookup ident ctx of
        Just (t', _) -> return (Var p (Free ident), t')
        -- This should have been caught during scope checking
        Nothing -> developerError $
          "Declaration'" <+> pretty ident <+> "'not found when" <+>
          "looking up variable in context" <+> pretty ctx <+> "at" <+> pretty p

    Let p bound binder body -> do

      (bound', tBound') <-
        if isHole (binderType binder) then
          -- No information is provided so infer the type of the bound expression
          infer bound
        else do
          -- Check the type of the bound expression against the provided type
          (tBound', _) <- infer (binderType binder)
          bound'  <- check tBound' bound
          return (bound', tBound')

      -- Update the context with the bound variable
      addToBoundCtx (binderName binder) tBound' $ do
        -- Infer the type of the body
        (checkedBody , tBody') <- infer body
        let checkedBinder = replaceBinderType tBound' binder
        return (Let p bound' checkedBinder checkedBody , tBody')

    Lam p binder body -> do
      -- Infer the type of the bound variable from the binder
      (tBound', _) <- infer (binderType binder)

      -- Update the context with the bound variable
      addToBoundCtx (binderName binder) tBound' $ do
        (body' , tBody') <- infer body
        let checkedBinder = replaceBinderType tBody' binder
        let t' = Pi p checkedBinder tBody'
        return (Lam p checkedBinder body' , t')

    Literal p l -> do
      let t' = typeOfLiteral p l
      inferApp p (Literal p l) t' []

    Builtin p op -> do
      let t' = typeOfBuiltin p op
      return (Builtin p op, t')

    Seq p es -> do
      (es', ts') <- unzip <$> traverse infer es

      -- Generate a meta-variable for the applied container type, e.g. List Int
      (_, tCont') <- freshMeta p
      -- Generate a fresh meta variable for the type of elements in the list, e.g. Int
      (_, tElem') <- freshMeta p

      -- Unify the types of all the elements in the sequence
      _ <- foldrM (unify p) tElem' ts'

      -- Enforce that the applied container type must be a container
      -- Generate a fresh meta-variable for the container function, e.g. List
      (meta, tMeta') <- freshMeta p
      ctx <- getVariableCtx
      addTypeClassConstraint ctx meta (mkIsContainer p tElem' tCont')

      -- Add in the type and type-class arguments
      let seqWithTArgs = normAppList p (Seq p es')
            [MachineImplicitArg tElem', MachineImplicitArg tCont', MachineInstanceArg tMeta']

      return (seqWithTArgs , tCont')

    PrimDict{} -> developerError "PrimDict should never be type-checked"

  showInferExit res
  return res

-- TODO: unify DeclNetw and DeclData
inferDecls :: TCM m => [UncheckedDecl] -> m [CheckedDecl]
inferDecls [] = return []
inferDecls (d : ds) = case d of
  DeclNetw p ident t -> do
    showDeclEntry ident

    (t', ty') <- infer t
    assertIsType p ty'

    showDeclExit ident
    decls' <- addToDeclCtx ident t' Nothing $ inferDecls ds
    return $ DeclNetw p ident t' : decls'

  DeclData p ident t -> do
    showDeclEntry ident

    (t', ty') <- infer t
    assertIsType p ty'

    showDeclExit ident
    decls' <- addToDeclCtx ident t' Nothing $ inferDecls ds
    return $ DeclData p ident t' : decls'

  DefFun p ident t body -> do
    showDeclEntry ident

    (t', k') <- infer t
    assertIsType p k'
    body' <- check t' body

    showDeclExit ident
    decls' <- addToDeclCtx ident t' (Just body') $ inferDecls ds
    return $ DefFun p ident t' body' : decls'

inferProg :: TCM m => UncheckedProg -> m CheckedProg
inferProg (Main ds) = do
  logDebug "Beginning initial type-checking pass"
  result <- Main <$> inferDecls ds
  logDebug "Ending initial type-checking pass\n"
  return result

viaInfer :: TCM m => Provenance -> CheckedExpr -> UncheckedExpr -> m CheckedExpr
viaInfer p expectedType e = do
  -- TODO may need to change the term when unifying to insert a type application.
  (e', actualType) <- infer e
  (e'', actualType') <- inferApp p e' actualType []
  _t <- unify p expectedType actualType'
  return e''

--------------------------------------------------------------------------------
-- Typing of literals and builtins

-- | Return the type of the provided literal,
typeOfLiteral :: Provenance -> Literal -> CheckedExpr
typeOfLiteral p l = fromDSL $ case l of
  LNat  _ -> forall type0 $ \t -> isNatural  p t ~~~> t
  LInt  _ -> forall type0 $ \t -> isIntegral p t ~~~> t
  LRat  _ -> forall type0 $ \t -> isReal     p t ~~~> t
  LBool _ -> forall type0 $ \t -> isTruth    p t ~~~> t

-- | Return the type of the provided builtin.
typeOfBuiltin :: Provenance -> Builtin -> CheckedExpr
typeOfBuiltin p b = fromDSL $ case b of
  Bool            -> type0
  Prop            -> type0
  Nat             -> type0
  Int             -> type0
  Real            -> type0
  List            -> type0 ~> type0
  Tensor          -> type0 ~> tList tNat ~> type0

  HasEq           -> type0 ~> type0 ~> type0
  HasOrd          -> type0 ~> type0 ~> type0
  IsTruth         -> type0 ~> type0
  IsNatural       -> type0 ~> type0
  IsIntegral      -> type0 ~> type0
  IsRational      -> type0 ~> type0
  IsReal          -> type0 ~> type0
  IsContainer     -> type0 ~> type0
  IsQuantifiable  -> type0 ~> type0 ~> type0

  If   -> typeOfIf
  Cons -> typeOfCons

  Impl -> typeOfBoolOp2 p
  And  -> typeOfBoolOp2 p
  Or   -> typeOfBoolOp2 p
  Not  -> typeOfBoolOp1 p

  Eq   -> typeOfEqualityOp p
  Neq  -> typeOfEqualityOp p

  Order _ -> typeOfComparisonOp p

  Add  -> typeOfNumOp2 (isNatural  p)
  Sub  -> typeOfNumOp2 (isIntegral p)
  Mul  -> typeOfNumOp2 (isNatural  p)
  Div  -> typeOfNumOp2 (isRational p)
  Neg  -> typeOfNumOp1 (isIntegral p)

  At   -> typeOfAtOp p
  Map  -> typeOfMapOp
  Fold -> typeOfFoldOp p

  Quant   _ -> typeOfQuantifierOp
  QuantIn _ -> typeOfQuantifierInOp p

typeOfIf :: DSLExpr
typeOfIf =
  forall type0 $ \t ->
    tProp ~> t ~> t

typeOfCons :: DSLExpr
typeOfCons =
  forall type0 $ \t ->
    t ~> tList t ~> tList t

typeOfEqualityOp :: Provenance -> DSLExpr
typeOfEqualityOp p =
  forall type0 $ \t ->
    forall type0 $ \r ->
      hasEq p t r ~~~> t ~> t ~> r

typeOfComparisonOp :: Provenance -> DSLExpr
typeOfComparisonOp p =
  forall type0 $ \t ->
    forall type0 $ \r ->
      hasOrd p t r ~~~> t ~> t ~> r

typeOfBoolOp2 :: Provenance -> DSLExpr
typeOfBoolOp2 p =
  forall type0 $ \t ->
    isTruth p t ~~~> t ~> t ~> t

typeOfBoolOp1 :: Provenance -> DSLExpr
typeOfBoolOp1 p =
  forall type0 $ \t ->
    isTruth p t ~~~> t ~> t

typeOfNumOp2 :: (DSLExpr -> DSLExpr) -> DSLExpr
typeOfNumOp2 numConstraint =
  forall type0 $ \t ->
    numConstraint t ~~~> t ~> t ~> t

typeOfNumOp1 :: (DSLExpr -> DSLExpr) -> DSLExpr
typeOfNumOp1 numConstraint =
  forall type0 $ \t ->
    numConstraint t ~~~> t ~> t

typeOfQuantifierOp :: DSLExpr
typeOfQuantifierOp =
  forall type0 $ \t ->
    (t ~> tProp) ~> tProp

typeOfQuantifierInOp :: Provenance -> DSLExpr
typeOfQuantifierInOp p =
  forall type0 $ \tElem ->
    forall type0 $ \tCont ->
      forall type0 $ \tRes ->
        isContainer p tElem tCont ~~~> (tElem ~> tRes) ~> tCont ~> tRes

typeOfAtOp :: Provenance -> DSLExpr
typeOfAtOp p =
  forall type0 $ \tElem ->
    forall type0 $ \tCont ->
      isContainer p tElem tCont ~~~> tCont ~> tNat ~> tElem

-- TODO generalise these to tensors etc. (remember to do mkMap' in utils as well)
typeOfMapOp :: DSLExpr
typeOfMapOp =
  forall type0 $ \tFrom ->
    forall type0 $ \tTo ->
      (tFrom ~> tTo) ~> tList tFrom ~> tList tTo

typeOfFoldOp :: Provenance -> DSLExpr
typeOfFoldOp p =
  forall type0 $ \tElem ->
    forall type0 $ \tCont ->
      forall type0 $ \tRes ->
        isContainer p tElem tCont ~~~> (tElem ~> tRes ~> tRes) ~> tRes ~> tCont ~> tRes