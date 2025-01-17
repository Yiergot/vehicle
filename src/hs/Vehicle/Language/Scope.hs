
module Vehicle.Language.Scope
  ( ScopeError(..)
  , scopeCheck
  ) where

import Control.Monad.Except
import Control.Monad.Reader (MonadReader(..), runReaderT)
import Data.List (elemIndex)
import Data.Set (Set,)
import Data.Set qualified as Set (member, insert, toList)

import Vehicle.Language.AST
import Vehicle.Language.Print (prettyVerbose)
import Vehicle.Prelude


scopeCheck :: (MonadLogger m, MonadError ScopeError m) => InputProg -> m UncheckedProg
scopeCheck prog = do
  logDebug "Beginning scope checking"
  result <- runReaderT (scope prog) emptyCtx
  logDebug "Finished scope checking\n"
  return result

--------------------------------------------------------------------------------
-- * Errors.

-- |Type of errors thrown by scope checking.
data ScopeError
  = UnboundName Symbol Provenance
  deriving Show

instance MeaningfulError ScopeError where
  details  (UnboundName name p) = UError $ UserError
    { problem    = "The name" <+> squotes (pretty name) <+> "is not in scope"
    , provenance = p
    -- TODO can use Levenschtein distance to search contexts/builtins
    , fix        = pretty ("Unknown" :: String)
    }

-- |Throw an |UnboundName| error using an arbitrary token.
unboundNameError :: MonadError ScopeError m => Symbol -> Provenance -> m a
unboundNameError n p = throwError $ UnboundName n p

--------------------------------------------------------------------------------
-- Scope checking monad and context

type SCM m = (MonadLogger m, MonadError ScopeError m, MonadReader Ctx m)

-- |Type of scope checking contexts.
data Ctx = Ctx
  { declCtx :: Set Identifier
  , exprCtx :: [Maybe Symbol]
  }

instance Pretty Ctx where
  pretty (Ctx declCtx exprCtx) = "Ctx" <+> pretty (Set.toList declCtx) <+> pretty exprCtx

emptyCtx :: Ctx
emptyCtx = Ctx mempty mempty

--------------------------------------------------------------------------------
-- Debug functions

logScopeEntry :: SCM m => InputExpr -> m ()
logScopeEntry e = do
  incrCallDepth
  logDebug $ "scope-entry" <+> prettyVerbose e -- <+> "in" <+> pretty ctx

logScopeExit :: SCM m => UncheckedExpr -> m ()
logScopeExit e = do
  logDebug $ "scope-exit " <+> prettyVerbose e
  decrCallDepth

--------------------------------------------------------------------------------
-- Algorithm

class ScopeCheck a b where
  scope :: SCM m => a -> m b

instance ScopeCheck InputProg UncheckedProg where
  scope (Main ds) = Main <$> scope ds

instance ScopeCheck [InputDecl] [UncheckedDecl] where
  scope []       = return []
  scope (d : ds) = do
    d' <- scope d
    ds' <- bindDecl (identifierOf d') (scope ds)
    return (d' : ds')

instance ScopeCheck InputDecl UncheckedDecl where
  scope = \case
    DeclNetw ann n t -> DeclNetw ann n <$> scope t
    DeclData ann n t -> DeclNetw ann n <$> scope t
    DefFun ann n t e -> DefFun   ann n <$> scope t <*> scope e

instance ScopeCheck InputArg UncheckedArg where
  scope = traverseArgExpr scope

instance ScopeCheck InputBinder UncheckedBinder where
  scope = traverseBinderType scope

instance ScopeCheck InputExpr UncheckedExpr where
  scope e = do
    logScopeEntry e
    result <- case e of
      Type l                         -> return $ Type l
      Meta p i                       -> return $ Meta p i
      Hole     ann n                 -> return $ Hole ann n
      Ann      ann ex t              -> Ann ann <$> scope ex <*> scope t
      App      ann fun args          -> App ann <$> scope fun <*> traverse scope args
      Builtin  ann op                -> return $ Builtin ann op
      Var      ann v                 -> Var ann <$> getVar ann v
      Literal  ann l                 -> return $ Literal ann l
      Seq      ann es                -> Seq ann <$> traverse scope es

      Pi  ann binder res -> do
        bindVar binder $ \binder' -> Pi ann binder' <$> scope res

      Lam ann binder body -> do
        bindVar binder $ \binder' -> Lam ann binder' <$> scope body

      Let ann bound binder body -> do
        bound' <- scope bound
        bindVar binder $ \binder' -> Let ann bound' binder' <$> scope body

      PrimDict _tc -> developerError "Found PrimDict during scope checking."

    logScopeExit result
    return result

bindDecl :: SCM m => Identifier -> m a -> m a
bindDecl ident continuation = do
  local addDeclToCtx continuation
    where
      addDeclToCtx :: Ctx -> Ctx
      addDeclToCtx Ctx {..} = Ctx (Set.insert ident declCtx) exprCtx

bindVar :: SCM m => InputBinder -> (UncheckedBinder -> m UncheckedExpr) -> m UncheckedExpr
bindVar binder update = do
  binder' <- scope binder
  local (addBinderToCtx (nameOf binder)) (update binder')
    where
      addBinderToCtx :: Maybe Symbol -> Ctx -> Ctx
      addBinderToCtx name Ctx{..} = Ctx declCtx (name : exprCtx)

-- |Find the index for a given name of a given sort.
getVar :: SCM m => InputAnn -> Symbol -> m LocallyNamelessVar
getVar ann symbol = do
  Ctx declCtx exprCtx <- ask
  case elemIndex (Just symbol) exprCtx of
    Just i -> return $ Bound i
    Nothing ->
      if Set.member (Identifier symbol) declCtx
        then return $ Free (Identifier symbol)
        else unboundNameError symbol (provenanceOf ann)