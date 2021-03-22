{-# OPTIONS_GHC -fno-warn-orphans #-}

{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeFamilies      #-}

module Vehicle.Frontend.Type.Instance.Recursive where

import Control.Monad (join)
import Data.Functor.Foldable.TH
import Vehicle.Frontend.Type.Core

$(join <$> traverse makeBaseFunctor [''Kind, ''Type, ''Expr])