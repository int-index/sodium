{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
module Sodium.Nucleus.Program where

import Data.Singletons.Prelude
import Data.Singletons.TH
import Data.Type.Equality
import qualified Data.Map as M

singletons [d|

    data Type
        = TypeInteger
        | TypeDouble
        | TypeBoolean
        | TypeChar
        | TypeUnit
        | TypeList Type
        | TypePair Type Type
        deriving (Eq)

             |]

deriving instance Ord  Type
deriving instance Show Type

data Name1 tag
    = NameOp Operator
    | Name1 [String] tag
    deriving (Eq, Ord, Show)

type Name = Name1 ()
pattern Name ns = Name1 ns ()

data Operator
    = OpAdd
    | OpSubtract
    | OpMultiply
    | OpDivide
    | OpDiv
    | OpMod
    | OpLess
    | OpMore
    | OpEquals
    | OpAnd
    | OpOr
    | OpNot
    | OpXor
    | OpRange
    | OpElem
    | OpShow
    | OpNegate
    | OpFold
    | OpProduct
    | OpSum
    | OpAnd'
    | OpOr'
    | OpPrintLn
    | OpReadLn
    | OpPutLn
    | OpGetLn
    | OpId
    | OpPair
    | OpFst
    | OpSnd
    | OpSingleton
    | OpTaint
    | OpConcat
    | OpIntToDouble
    | OpUndefined
    | OpMain
    deriving (Eq, Ord, Show)

data Literal where
    Lit :: SType t -> TypeRepr t -> Literal

instance Eq Literal where
    Lit STypeInteger r1 == Lit STypeInteger r2 = r1 == r2
    Lit STypeDouble  r1 == Lit STypeDouble  r2 = r1 == r2
    Lit STypeBoolean r1 == Lit STypeBoolean r2 = r1 == r2
    Lit STypeChar    r1 == Lit STypeChar    r2 = r1 == r2
    Lit STypeUnit    r1 == Lit STypeUnit    r2 = r1 == r2
    Lit (STypeList ts1) rs1 == Lit (STypeList ts2) rs2
        | Just Refl <- testEquality ts1 ts2
        = map (Lit ts1) rs1 == map (Lit ts2) rs2
    Lit (STypePair t11 t21) (r11, r21) == Lit (STypePair t12 t22) (r12, r22)
        | Just Refl <- testEquality t11 t21
        , Just Refl <- testEquality t12 t22
        = (Lit t11 r11, Lit t21 r21) == (Lit t12 r12, Lit t22 r22)
    Lit _ _ == Lit _ _ = False

typecheckLiteral :: Literal -> Type
typecheckLiteral (Lit t _) = fromSing t

type family TypeRepr (t :: Type) where
    TypeRepr TypeInteger = Integer
    TypeRepr TypeDouble  = Rational
    TypeRepr TypeBoolean = Bool
    TypeRepr TypeChar    = Char
    TypeRepr TypeUnit    = ()
    TypeRepr (TypeList    ts) = [TypeRepr ts]
    TypeRepr (TypePair t1 t2) = (TypeRepr t1, TypeRepr t2)

type Vars
    = M.Map Name Type
