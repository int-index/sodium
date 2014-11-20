{-# LANGUAGE FlexibleContexts #-}
module Sodium (translate) where

import Sodium.Nucleus.Vectorize   (vectorize)
import Sodium.Nucleus.Shadow      (unshadow)
import Sodium.Nucleus.Scalar.Atomize (atomize')
import Sodium.Nucleus.Scalar.Valueficate (valueficate)
import Sodium.Nucleus.Strip (strip)
import Sodium.Nucleus.Pass.Flatten     (flatten)
import Sodium.Nucleus.Pass.JoinMultiIf (joinMultiIf)
import Sodium.Nucleus.Pass.Inline      (inline)
import Sodium.Nucleus.Pass.FoldMatch   (foldMatch)
import Sodium.Nucleus.Pass.ExtractBody (extractBody)
import Sodium.Nucleus.Pass.BindClean   (bindClean)
import Sodium.Nucleus.Pass.Clean       (clean)
import Sodium.Nucleus.Pass.Compute     (compute)
import Sodium.Nucleus.Pass.ArgClean    (argClean)
import Language.Haskell.Exts.Pretty (prettyPrint)
import qualified Sodium.Pascal.Parse   as P (parse)
import qualified Sodium.Pascal.Convert as P (convert)
import qualified Sodium.Haskell.Convert as H (convert, reserved)
import qualified Sodium.Error as E
import qualified Sodium.Nucleus.Program.Vector as V
import qualified Sodium.Nucleus.Render as R
import qualified Sodium.Nucleus.Name as N

import Data.Bool
import Control.Applicative
import Control.Monad.Writer hiding (pass)
import Control.Monad.State
import Control.Monad.Except

translate :: (Applicative m, MonadError E.Error m) => String -> m ([String], String)
translate src = do
    pas <- P.parse src
    let namestack0 = map ((\name -> V.Name ["g", name]) . ('g':) . show) [0..]
    (scalar, namestack1) <- P.convert pas `runStateT` namestack0
    (atomic, namestack2) <- atomize' scalar `runStateT` namestack1
    let valued = valueficate atomic
    (atomicValued, namestack3) <- atomize' valued `runStateT` namestack2
    vector <- vectorize atomicValued
    let noshadow = unshadow vector
    let (optimal, log) = runWriterT (closureM pass noshadow) `evalState` namestack3
    let dest = prettyPrint $ H.convert $ strip H.reserved optimal
    return (map R.render log, dest)

pass :: (MonadWriter [V.Program] m, N.NameStack t m) => V.Program -> m V.Program
pass program = tell [program] >> f program
    where f  =  return . argClean
            <=< return . compute
            <=< return . flatten
            <=< inline
            <=< return . foldMatch
            <=< return . joinMultiIf
            <=< return . extractBody
            <=< return . bindClean
            <=< return . clean

closureM :: (Eq a, Monad m) => (a -> m a) -> (a -> m a)
closureM f = go where
    go x = f x >>= \y -> bool (go y) (return x) (x == y)
