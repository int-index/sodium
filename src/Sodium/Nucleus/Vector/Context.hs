{-# LANGUAGE FlexibleContexts #-}
module Sodium.Nucleus.Vector.Context where

import Control.Applicative
import Control.Monad.Writer
import Control.Monad.Supply

import Sodium.Nucleus.Vector.Program
import Sodium.Nucleus.Vector.Recmap
import Sodium.Nucleus.Vector.Name
import Sodium.Nucleus.Vector.Attempt
import Sodium.Util

contexts :: MonadWriter [Expression] m => Attempt -> Expression -> m Expression
contexts fits (Beta cxt e) | Just e' <- fits e = tell [cxt] >> return e'
contexts _ e = return e

context :: (Applicative m, MonadSupply Integer m) => Name -> Expression
        -> (Name -> Expression -> Maybe Expression -> m a) -> m a
context name a cont = do
    name' <- NameGen <$> supply
    let (b, cxts) = runWriter (recmapped w a)
        dangling = b `mentions` name
        w = contexts $ \case
            Access name'' | name == name'' -> Just (Access name')
            _ -> Nothing
    case uniform cxts of
        Just ctx | not dangling -> cont name' b (Just ctx)
        _ -> cont name' b Nothing

extractCtx :: (Applicative m, MonadSupply Integer m) => Program -> m Program
extractCtx = recmapped extractCtxExpression

extractCtxExpression
    :: (Applicative m, MonadSupply Integer m)
    => Expression -> m Expression
extractCtxExpression = \case
    e@(Follow (PAccess name ty) x a) -> do
        context name a $ \name' b -> \case
            Just (OpAccess op)
                | Just x'  <- taintAttempt (return . AppOp1 op) x
                , Just ty' <- hackish_typeApp op ty
                -> return $ Follow (PAccess name' ty') x' b
            _ -> return e
    e -> return e

-- TODO: typecheck
hackish_typeApp :: NameSpecial -> Type -> Maybe Type
hackish_typeApp = \case
    OpFst -> \case
        TypePair ty _ -> pure ty
        _ -> empty
    OpSnd -> \case
        TypePair _ ty -> pure ty
        _ -> empty
    _ -> \_ -> empty