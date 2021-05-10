{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Vehicle.Core.Check.Scope where

import           Control.Monad.Except (MonadError, Except, runExcept, liftEither)
import           Control.Monad.Error.Class (throwError)
import           Control.Monad.Reader (MonadReader, ReaderT, runReaderT)
import           Control.Monad.Trans (lift)
import qualified Data.List as List
import           Vehicle.Core.Type
import           Vehicle.Prelude


-- |Type of scope checking contexts.
data Ctx = Ctx { tEnv :: [Symbol], eEnv :: [Symbol] }

-- |The empty scope checking context.
emptyCtx :: Ctx
emptyCtx = Ctx { tEnv = [], eEnv = [] }

-- |The scope checking monad.
type Scope a = ReaderT Ctx (Except ScopeError) a

runScope :: MonadError ScopeError m => Scope a -> m a
runScope m = liftEither . runExcept $ runReaderT m emptyCtx

-- |Type of errors thrown by scope checking.
newtype ScopeError
  = UnboundName Token
  deriving (Show)

checkScope ::
  (MonadError ScopeError m, IsToken name, KnownSort sort) =>
  Tree (K name) builtin ann sort ->
  m (Tree DeBruijn builtin ann sort)
checkScope tree = runScope (unO (sortedFoldM checkScopeF tree))

checkScopeF ::
  (MonadError ScopeError m, MonadReader Ctx m, IsToken name, KnownSort sort) =>
  TreeF (K name) builtin ann sort (m `O` Tree DeBruijn builtin ann) ->
  (m `O` Tree DeBruijn builtin ann) sort
checkScopeF (tree :: TreeF name builtin ann sort tree) = case sortSing :: SSort sort of

  -- Kinds
  SKIND -> case tree of
    KAppF  ann k1 k2 -> _
    KConF  ann op    -> _
    KMetaF ann i     -> _

  -- Types
  STYPE -> case tree of
    TForallF  ann n t   -> _
    TAppF     ann t1 t2 -> _
    TVarF     ann n     -> _
    TConF     ann op    -> _
    TLitDimF  ann d     -> _
    TLitListF ann ts    -> _
    TMetaF    ann i     -> _

  -- Type arguments
  STARG -> case tree of
    TArgF ann n -> _

  -- Expressions
  SEXPR -> case tree of
    EAnnF     ann e t     -> _
    ELetF     ann n e1 e2 -> _
    ELamF     ann n e     -> _
    EAppF     ann e1 e2   -> _
    EVarF     ann n       -> _
    ETyAppF   ann e t     -> _
    ETyLamF   ann n e     -> _
    EConF     ann op      -> _
    ELitIntF  ann z       -> _
    ELitRealF ann r       -> _
    ELitSeqF  ann es      -> _

  -- Expression arguments
  SEARG -> case tree of
    EArgF ann n -> _

  -- Declarations
  SDECL -> case tree of
    DeclNetwF ann n t    -> _
    DeclDataF ann n t    -> _
    DefTypeF  ann n ns t -> _
    DefFunF   ann n t e  -> _

  -- Programs
  SPROG -> case tree of
    MainF ann ds -> _

{-

-- * Conversion from names to de Bruijn indices

-- |Errors thrown during conversion from names to de Bruijn indices
newtype ScopeError = UnboundName Symbol
  deriving (Show)

-- |Monad stack used during conversion from names to de Bruijn indices.
type MonadScope m = MonadError ScopeError m

-- |Context for de Bruijn conversion.
-- A list of the bound variable names encountered so far ordered from most to least recent.
data Ctx = Ctx { kenv :: [Symbol], tenv :: [Symbol] }

-- |Run a function in 'MonadScope'.
runScope :: Except ScopeError a -> Either ScopeError a
runScope = runExcept

-- |Class for the various conversion functions.
class Scope tree1 tree2 where
  checkScope :: MonadScope m => Context -> tree1 -> m tree2
{-
instance Scope (Kind (K Name) builtin ann) (Kind SortedDeBruijn builtin ann) where
  checkScope _ctx = fold $ \case
    KConF  ann op    -> return $ KCon ann op
    KMetaF ann i     -> return $ KMeta ann i
    KAppF  ann k1 k2 -> KApp ann <$> k1 <*> k2
-}
instance Scope (Type (K Name) builtin ann) (Type SortedDeBruijn builtin ann) where
  checkScope _ (TCon ann builtin) = return $ TCon ann builtin
  checkScope _ (TLitDim ann dim) = return $ TLitDim ann dim
  checkScope _ (TMeta ann var) = return $ TMeta ann var

  checkScope ctxt (TApp ann fn arg) = TApp ann <$> checkScope ctxt fn <*> checkScope ctxt arg
  checkScope ctxt (TLitList ann typs) = TLitList ann <$> traverse (checkScope ctxt) typs

  checkScope ctxt (TForall ann arg body) =
    let (name, cArg) = checkScopeTArg arg in do
      cBody <- checkScope (name : ctxt) body
      return $ TForall ann cArg cBody

  checkScope ctxt (TVar ann (K name)) = do
    index <- checkScopeName name ctxt
    return $ TVar ann (SortedDeBruijn index)

instance Scope (Expr (K Name) builtin ann) (Expr SortedDeBruijn builtin ann) where
  checkScope _ (ELitInt ann val) = return $ ELitInt ann val
  checkScope _ (ELitReal ann val) = return $ ELitReal ann val
  checkScope _ (ECon ann builtin) = return $ ECon ann builtin

  checkScope ctxt (ELitSeq ann exprs) = ELitSeq ann <$> traverse (checkScope ctxt) exprs
  checkScope ctxt (EAnn ann expr typ) = EAnn ann <$> checkScope ctxt expr<*> checkScope ctxt typ
  checkScope ctxt (ETyApp ann expr typ) = ETyApp ann <$> checkScope ctxt expr <*> checkScope ctxt typ
  checkScope ctxt (EApp ann expr1 expr2) = EApp ann <$> checkScope ctxt expr1 <*> checkScope ctxt expr2

  checkScope ctxt (EVar ann (K name)) = do
    index <- checkScopeName name ctxt
    return $ EVar ann (SortedDeBruijn index)

  checkScope ctxt (ELet ann arg expr1 expr2) =
    let (varName, cArg) = checkScopeEArg arg in do
      cExp1 <- checkScope ctxt expr1
      cExp2 <- checkScope (varName : ctxt) expr2
      return $ ELet ann cArg cExp1 cExp2

  checkScope ctxt (ELam ann arg expr) =
    let (varName, cArg) = checkScopeEArg arg in do
      cExpr <- checkScope (varName : ctxt) expr
      return $ ELam ann cArg cExpr

  checkScope ctxt (ETyLam ann arg expr) =
    let (varName, cArg) = checkScopeTArg arg in do
      cExpr <- checkScope (varName : ctxt) expr
      return $ ETyLam ann cArg cExpr

instance Scope (Decl (K Name) builtin ann) (Decl SortedDeBruijn builtin ann) where
  checkScope ctxt (DeclNetw ann arg typ) =
    let (varName, cArg) = checkScopeEArg arg in do
      cTyp <- checkScope (varName : ctxt) typ
      return $ DeclNetw ann cArg cTyp

  checkScope ctxt (DeclData ann arg typ) =
    let (varName, cArg) = checkScopeEArg arg in do
      cTyp <- checkScope (varName : ctxt) typ
      return $ DeclData ann cArg cTyp

  checkScope ctxt (DefType ann arg args typ) =
    let (varName, cArg) = checkScopeTArg arg in do
      (varNames , cArgs) <- checkScopeTArgs (varName : ctxt) args
      cTyp <- checkScope (reverse varNames ++ (varName : ctxt)) typ
      return $ DefType ann cArg cArgs cTyp

  checkScope ctxt (DefFun ann arg typ expr) = do
    let (varName, cArg) = checkScopeEArg arg in do
      cTyp <- checkScope (varName : ctxt) typ
      cExpr <- checkScope (varName : ctxt) expr
      return $ DefFun ann cArg cTyp cExpr

instance Scope (Prog (K Name) builtin ann) (Prog SortedDeBruijn builtin ann) where
  checkScope ctxt (Main ann decls)= Main ann <$> checkScopeDecls ctxt decls

checkScopeEArg :: EArg (K Name) builtin ann -> (Symbol , EArg SortedDeBruijn builtin ann)
checkScopeEArg (EArg ann (K name)) = (nameSymbol name , EArg ann (SortedDeBruijn name))

checkScopeTArg :: TArg (K Name) builtin ann -> (Symbol , TArg SortedDeBruijn builtin ann)
checkScopeTArg (TArg ann (K name)) = (nameSymbol name , TArg ann (SortedDeBruijn name))

checkScopeTArgs :: MonadScope m => Context -> [TArg (K Name) builtin ann] -> m ([Symbol], [TArg SortedDeBruijn builtin ann])
checkScopeTArgs _ [] = return ([], [])
checkScopeTArgs ctxt (tArg : tArgs) =
    let (varName, cArg) = checkScopeTArg tArg in do
      (varNames, cArgs) <- checkScopeTArgs (varName : ctxt) tArgs
      return (varName : varNames,  cArg : cArgs)

checkScopeDecls :: MonadScope m => Context -> [Decl (K Name) builtin ann] -> m [Decl SortedDeBruijn builtin ann]
checkScopeDecls _ [] = return []
checkScopeDecls ctxt (decl : decls) = do
  cDecl <- checkScope ctxt decl
  cDecls <- checkScopeDecls (declName decl : ctxt) decls
  return (cDecl : cDecls)

checkScopeName :: MonadScope m => Name -> Context -> m Ix
checkScopeName (Name (pos , text)) ctxt = case List.elemIndex text ctxt of
  Nothing -> throwError $ UnboundName text
  Just index -> return $ Ix (pos , index)

-- * Helper functions for extracting the Symbol from binding sites

nameSymbol :: Name -> Symbol
nameSymbol (Name (_ , name)) = name

eArgName :: EArg (K Name) builtin ann -> Symbol
eArgName (EArg _ (K name))= nameSymbol name

tArgName :: TArg (K Name) builtin ann -> Symbol
tArgName (TArg _ (K name))= nameSymbol name

declName :: Decl (K Name) builtin ann -> Symbol
declName (DeclNetw _ arg _) = eArgName arg
declName (DeclData _ arg _) = eArgName arg
declName (DefFun _ arg _ _) = eArgName arg
declName (DefType _ arg _ _) = tArgName arg

-- -}
-- -}
-- -}
-- -}
-- -}
