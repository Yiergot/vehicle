{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}

module Vehicle.Backend.Verifier.VNNLib
  ( VNNLibDoc(..)
  , compileToVNNLib
  ) where

import Control.Monad.Reader (MonadReader(..), runReaderT, asks)
import Control.Monad.Except (MonadError(..), runExcept)
import Control.Monad.State (MonadState(..), evalStateT)
import Data.Map (Map)
import Data.Map qualified as Map (insert, lookup)
import Data.Maybe (catMaybes, fromMaybe)

import Vehicle.Prelude
import Vehicle.Language.AST hiding (Map)
import Vehicle.Language.Print (prettySimple)
import Vehicle.Language.Normalise (normaliseInternal)
import Vehicle.Backend.Verifier.Core
import Vehicle.Backend.Verifier.SMTLib (SMTLibError, SMTDoc, SMTLibError(..), InputOrOutput(..), UnsupportedNetworkType(..))
import Vehicle.Backend.Verifier.SMTLib qualified as SMTLib (compileProp)

--------------------------------------------------------------------------------
-- Compilation to VNNLib
--
-- Okay so this is a wild ride. The VNNLib format has special variable names for
-- input and output variables, namely X1 ... XN and Y1 ... YM but otherwise has
-- the standard SMTLib syntax.
--
-- This means that in theory you can only reason about a single network applied
-- to a single input per property. We get around this restriction by combining
-- multiple networks, or multiple applications of the same network into a
-- single "meta" network. Concretely this process goes as follows for each
-- property we identify in the program.
--
-- 1. We perform let-lifting of network applications so that every application
-- of a network to a unique input sits in its own let binding underneath a
-- universal quantifier. (STILL TO DO)
--
-- 2. We traverse the resulting expression finding all let-bound
-- applications of the network e.g.
--
--   let y = f xs in e
--
-- and perform the following substitution for the application:
--
--   (X4 == a and X5 == b && X6 == c) and ([Y2, Y3] `substInto` e)
--
-- and add each application to the meta-network.
--
-- 3. For every input and output of the meta-network we insert
-- universal quantifiers over the inputs X1 ... XN and outputs
-- Y1 ... YN to the network at the top-level of the property.
--
-- 5. The property should then be a valid SMTLib expression so we now
-- compile it to SMTLib as normal.
--
-- 6. We return the meta-network composition so that we can actually
-- perform the required hackery on the network files elsewhere.

-- | Compiles a given program to a VNNLib script.
-- Assumes the program has already been normalised.
compileToVNNLib :: (MonadLogger m, MonadError SMTLibError m)
                => CheckedProg
                -> m [VNNLibDoc]
compileToVNNLib prog = do
  logDebug "Beginning compilation to VNNLib"
  incrCallDepth
  result <- runReaderT (compileProg prog) []
  decrCallDepth
  logDebug "Finished compilation to VNNLib"
  return result

--------------------------------------------------------------------------------
-- Data

data VNNLibDoc = VNNLibDoc
  { smtDoc      :: SMTDoc
  , metaNetwork :: MetaNetwork
  }

instance Pretty TensorDetails where
  pretty (TensorDetails size tElem) = "Tensor" <+> pretty tElem <+> "[" <> pretty size <> "]"

type NetworkCtx = Map Identifier CheckedDecl

type MetaNetwork = [Identifier]

--------------------------------------------------------------------------------
-- Monad

type MonadVNNLib m =
  ( MonadLogger m
  , MonadError SMTLibError m
  , MonadReader NetworkCtx m
  )

getNetworkDetailsFromCtx :: MonadVNNLib m => Identifier -> m NetworkDetails
getNetworkDetailsFromCtx ident = do
  networkDecl <- asks (fromMaybe outOfScopeError . Map.lookup ident)
  getNetworkDetails (provenanceOf networkDecl, TheUser) (identifierOf networkDecl) (typeOf networkDecl)
  where
    outOfScopeError :: a
    outOfScopeError = developerError $
      "Either" <+> squotes (pretty ident) <+> "is not a network or it is not in scope"

--------------------------------------------------------------------------------
-- Algorithm
--------------------------------------------------------------------------------

compileProg :: MonadVNNLib m => CheckedProg -> m [VNNLibDoc]
compileProg (Main ds) = do
  results <- catMaybes <$> compileDecls ds
  if null results then
    throwError NoPropertiesFound
  else
    return results

compileDecls :: MonadVNNLib m => [CheckedDecl] -> m [Maybe VNNLibDoc]
compileDecls []       = return []
compileDecls (d : ds) = do
    (doc, alterCtx) <- compileDecl d
    docs <- local alterCtx (compileDecls ds)
    return (doc : docs)

compileDecl :: MonadVNNLib m => CheckedDecl -> m (Maybe VNNLibDoc, NetworkCtx -> NetworkCtx)
compileDecl d = case d of
  DeclData{} ->
    normalisationError "Dataset declarations"

  DeclNetw _ ident _ -> do
    -- Insert the network into the context
    let alterCtx = Map.insert ident d
    -- Remove the declaration, as SMTLib does not support it.
    return (Nothing, alterCtx)

  DefFun p ident t e ->
    let alterCtx = id in
    let identDoc = squotes (pretty ident) in
    if not $ isProperty t then
      -- If it's not a property then we can discard it as all applications
      -- of it should have been normalised out by now.
      return (Nothing, alterCtx)
    else do
      logDebug $ "Beginning compilation of VNNLib property" <+> identDoc
      incrCallDepth

      let metaNetwork = freeNames e
      logDebug $ "Generated meta-network" <+> pretty metaNetwork <> line

      if null metaNetwork then
        throwError $ NoNetworkUsedInProperty (p, TheUser) ident
      else do
        metaNetworkDetails <- traverse getNetworkDetailsFromCtx metaNetwork

        -- Replace all applications of neural networks with the magic VNNLib variables
        let numberOfMagicVariables = sum (map networkSize metaNetworkDetails)
        networklessExpr <- evalStateT (replaceNetworkApplications numberOfMagicVariables e) (0,0)

        -- Calculate and eliminate

        -- Normalise the resulting expression
        let normNetworklessExpr = normaliseInternal networklessExpr

        -- Append quantifiers over the magic variables so that it becomes a valid SMTLib expression
        let quantifiedExpr = quantifyOverMagicVariables metaNetworkDetails normNetworklessExpr
        logDebug $ "Replaced network applications:" <+> prettySimple quantifiedExpr <> line

        -- Compile to SMTLib
        smtDoc <- SMTLib.compileProp ident quantifiedExpr

        decrCallDepth
        logDebug $ "Finished compilation of VNNLib property" <+> identDoc

        return (Just $ VNNLibDoc smtDoc metaNetwork, alterCtx)

--------------------------------------------------------------------------------
-- Pass 1: instantiating network applications

replaceNetworkApplication :: (MonadVNNLib m, MonadState (Int, Int) m)
                          => CheckedAnn
                          -> Identifier
                          -> CheckedExpr
                          -> CheckedExpr
                          -> BindingDepth
                          -> m CheckedExpr
replaceNetworkApplication ann ident networkInput letBody bindingDepth  = do
  (NetworkDetails _ _ inputs outputs) <- getNetworkDetailsFromCtx ident
  let inputSize = size inputs
  let inputType = tElem outputs
  let outputSize = size inputs
  let outputType = tElem outputs

  (inputStartingIndex, outputStartingIndex) <- get
  put (inputStartingIndex + size inputs, outputStartingIndex + size outputs)

  let totalNumberOfMagicVariablesSoFar = inputStartingIndex + outputStartingIndex

  -- In the example points to X3
  let inputStartingDBIndex  = bindingDepth - totalNumberOfMagicVariablesSoFar
  -- In the example points to Y2
  let outputStartingDBIndex = inputStartingDBIndex - inputSize
  -- In the examples points to X4
  let outputEndingDBIndex       = outputStartingDBIndex - outputSize
  let inputVarIndices           = reverse [outputStartingDBIndex .. inputStartingDBIndex-1]
  let outputVarIndices          = reverse [outputEndingDBIndex   .. outputStartingDBIndex-1]
  let (inputsExpr,  inputsType) = mkMagicVariableSeq inputType  inputVarIndices
  let (outputsExpr, _)          = mkMagicVariableSeq outputType outputVarIndices

  let body'         = outputsExpr `substInto` letBody
  let inputEquality = mkEq Eq ann inputsType (BuiltinBooleanType ann Prop) [inputsExpr, networkInput]
  let newBody       = mkBoolOp2 Impl ann (BuiltinBooleanType ann Prop) [inputEquality, body']

  return newBody
  where
    mkMagicVariableSeq :: Builtin -> [Int] -> (CheckedExpr, CheckedExpr)
    mkMagicVariableSeq tElem indices = (tensorExpr, tensorType)
      where
        tensorElemType   = Builtin ann tElem
        tensorType       = mkTensor ann tensorElemType [length indices]
        variables        = map (Var ann . Bound) indices
        tensorExpr       = mkSeq ann tensorElemType tensorType variables

-- Takes in the expression to process and returns a function
-- from the current binding depth to the altered expression.
--
-- NOTE that we don't need to adjust references to already bound variables
-- as the quantifiers are all added on the outside.
replaceNetworkApplications :: (MonadVNNLib m, MonadState (Int, Int) m)
                           => BindingDepth
                           -> CheckedExpr
                           -> m CheckedExpr
replaceNetworkApplications d e =
  case e of
    Hole _p _      -> resolutionError "Hole"
    Meta _p _      -> resolutionError "Meta"
    Ann _ann _ _   -> normalisationError "Ann"
    Lam _ann _ _   -> normalisationError "Non-quantified Lam"

    Type{}     -> return e
    Pi{}       -> return e
    PrimDict{} -> return e
    Builtin{}  -> return e
    Literal{}  -> return e
    Var{}      -> return e

    Seq ann xs ->
      Seq ann <$> traverse (replaceNetworkApplications d) xs

    App ann1 fun@(BuiltinQuantifier _ _) [tElem, Arg ann3 v (Lam ann4 binder body)] -> do
      body' <- replaceNetworkApplications (d + 1) body
      -- Increase the binding depth by 1
      return $ App ann1 fun [tElem, Arg ann3 v (Lam ann4 binder body')]

    App ann fun args -> do
      fun'  <- replaceNetworkApplications d fun
      args' <- traverse (traverseArgExpr (replaceNetworkApplications d)) args
      return $ App ann fun' args'

    Let ann (App _ (Var _ (Free ident)) [inputArg]) _ body -> do
      newBody <- replaceNetworkApplication ann ident (argExpr inputArg) body d
      replaceNetworkApplications d newBody

    Let ann bound binder body -> do
      bound' <- replaceNetworkApplications d bound
      body'  <- replaceNetworkApplications d body
      return $ Let ann bound' binder body'

{-
    -- EXAMPLE:
    --
    --           (E)              (D)
    -- |-----------------------|
    --          (Net1)   (Net2)  (Net3)  (Net4)
    --
    -- forall (X0 X1 Y0) (X2 Y1) (X3 Y2) (X4 Y3) . forall x,y,z . ... Net2 x ...
    -- |                                       |   |          |      |      |
    -- -----------------------------------------   ------------      |------|
    --                          (A)                     (B)             (C)
    --
    -- (A) Inserted quantifiers over all Magic variables for meta-network.
    --
    -- (B) User quantifiers in the original program.
    --
    -- (C) The location of the network application in the program, which is pointed
    -- to by the variable `currentBindingDepth`.
    --
    -- (D) The location of the current network that's being applied in the quantifiers.
    --
    -- (E) Inserted quantifiers over the meta-network so far.
-}

--------------------------------------------------------------------------------
-- Pass 2: quantification over magic variables

quantifyOverMagicVariables :: [NetworkDetails] -> CheckedExpr -> CheckedExpr
quantifyOverMagicVariables metaNetwork prop =
  let totalInputs  = sum (map (size . inputTensor)  metaNetwork) in
  let totalOutputs = sum (map (size . outputTensor) metaNetwork) in
  let (_, _, result) = foldl forNetwork (totalInputs, totalOutputs, prop) metaNetwork in result
  where
    forNetwork :: (Int, Int, CheckedExpr) -> NetworkDetails -> (Int, Int, CheckedExpr)
    forNetwork (inputIndex, outputIndex, body) (NetworkDetails p _ inputs outputs)  =
      let startingInputIndex = inputIndex - size inputs in
      let startingOutputIndex = outputIndex - size outputs in
      let body' = forTensor p Input  startingInputIndex  inputs $
                  forTensor p Output startingOutputIndex outputs body in
      (startingInputIndex, startingOutputIndex, body')

    forTensor :: CheckedAnn
              -> InputOrOutput
              -> Int
              -> TensorDetails
              -> CheckedExpr
              -> CheckedExpr
    forTensor ann io startingIndex (TensorDetails size tElem) body =
      let indices = reverse [startingIndex .. startingIndex + size-1] in
      let names   = mkMagicVariableNames io indices in
      let varType = Builtin ann tElem in
      mkQuantifierSeq All ann (map Just names) varType body

    mkMagicVariableNames :: InputOrOutput -> [Int] -> [Symbol]
    mkMagicVariableNames io indices = [mkNameWithIndices baseName [i] | i <- indices]
      where baseName = if io == Input then "X" else "Y"

--------------------------------------------------------------------------------
-- Network type validation

data NetworkDetails = NetworkDetails
  { annotation   :: CheckedAnn
  , ident        :: Identifier
  , inputTensor  :: TensorDetails
  , outputTensor :: TensorDetails
  }

networkSize :: NetworkDetails -> Int
networkSize network = size (inputTensor network) + size (outputTensor network)

data TensorDetails = TensorDetails
  { size  :: Int
  , tElem :: Builtin
  }

getNetworkDetails :: MonadVNNLib m
                  => CheckedAnn
                  -> Identifier
                  -> CheckedExpr
                  -> m NetworkDetails
getNetworkDetails ann ident t@(Pi _ inputBinder output) =
  either
    (throwError . UnsupportedNetworkType ann ident t)
    return
    $ runExcept $ do
      inputDetails  <- getTensorDetails Input  (typeOf inputBinder)
      outputDetails <- getTensorDetails Output output
      return $ NetworkDetails ann ident inputDetails outputDetails
getNetworkDetails ann ident t                                  =
  throwError $ UnsupportedNetworkType ann ident t NotAFunction

getTensorDetails :: MonadError UnsupportedNetworkType m
                 => InputOrOutput
                 -> CheckedExpr
                 -> m TensorDetails
getTensorDetails io (App _ (BuiltinContainerType _ Tensor) [tElemArg, tDimsArg]) = do
  typ   <- getTensorType io (argExpr tElemArg)
  size  <- getTensorSize io (argExpr tDimsArg)
  return $ TensorDetails size typ
getTensorDetails io _ = throwError $ NotATensor io

getTensorType :: MonadError UnsupportedNetworkType m
              => InputOrOutput
              -> CheckedExpr
              -> m Builtin
getTensorType _  (BuiltinNumericType _ Real) = return (NumericType Real)
getTensorType io _                           = throwError $ WrongTensorType io

getTensorSize :: MonadError UnsupportedNetworkType m
              => InputOrOutput
              -> CheckedExpr
              -> m Int
getTensorSize io tDims = case exprHead tDims of
  (Seq _ [d]) -> case exprHead d of
    (Literal _ (LNat n)) -> return n
    _                    -> throwError $ VariableSizeTensor io
  _           -> throwError $ MultidimensionalTensor io