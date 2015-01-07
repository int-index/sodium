{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TemplateHaskell #-}
 
module Sodium.Pascal.Convert (convert, Error(..)) where

import Sodium.Prelude
import Sodium.Util

import qualified Data.Map as M

import Control.Monad.Trans.Maybe
-- S for Src, D for Dest
import qualified Sodium.Pascal.Program as S
import qualified Sodium.Nucleus.Scalar.Program as D
import qualified Sodium.Nucleus.Scalar.Build   as D

declareLenses [d|

    data TypeScope = TypeScope
        { tsFunctions :: Map S.Name S.FuncSig
        , tsVariables :: Map S.Name S.Type
        } deriving (Eq)

    data ConvScope = ConvScope
        { csTypes :: TypeScope
        , csNames :: Map Bool (Map S.Name D.Name)
        } deriving (Eq)

                |]

class Error e where
    errorTypecheck  :: e
    errorNoAccess   :: String -> [String] -> e
    errorNoFunction :: String -> e

type E e m = (Applicative m, MonadError e m, Error e)
type G e m = (MonadNameGen m, E e m)
type R m = MonadReader ConvScope m

convert :: G e m => S.Program -> m (D.Program D.ByType D.Pattern D.Expression)
convert program = do
    let initScope = ConvScope (TypeScope mempty mempty)
                              (M.fromList (liftA2(,)[True,False][mempty]))
    runReaderT (conv program) initScope

nameV, nameF :: (E e m, R m) => S.Name -> m D.Name
nameV = lookupName False
nameF = lookupName True

lookupName :: (E e m, R m) => Bool -> S.Name -> m D.Name
lookupName ct name = do
    names <- views csNames (M.! ct)
    let mname = M.lookup name names
    maybe (throwError (errorNoAccess name (M.keys names))) return mname

alias :: ( Applicative m , MonadNameGen m) => S.Name -> m D.Name
alias name = D.NameGen <$> mkname (Just name)

class Conv s where
    type Scalar s :: *
    conv :: (R m, G e m) => s -> m (Scalar s)

instance Conv S.Program where
    type Scalar S.Program = D.Program D.ByType D.Pattern D.Expression
    conv (S.Program funcs vars body) = do
        (mconcat -> funcNames) <- for funcs $ \(S.Func name _ _ _) -> do
            funcName <- alias name
            return $ M.singleton name funcName
        local ( (csTypes . tsFunctions %~ mappend funcSigs)
              . (csNames %~ M.adjust (mappend funcNames) True)
              ) $ do
            clMain <- do
                clBody <- convScope vars
                    $ D.Body <$> conv body <*> pure (D.expression ())
                let noparams = D.Scope ([] :: Pairs D.Name D.ByType)
                return $ D.Func D.TypeUnit (noparams clBody)
            clFuncs <- traverse conv funcs
            let programFuncs = (D.NameSpecial D.OpMain, clMain):clFuncs
            return $ D.Program (M.fromList programFuncs)
        where funcSigs = mconcat (map funcSigOf funcs)
              funcSigOf (S.Func name funcSig _ _) = M.singleton name funcSig

convScope vardecls inner = do
    (mconcat -> varNames, scopeVars)
        <- unzip <$> traverse convVardecl (M.toList vardecls)
    scopeElem <- local ( (csTypes . tsVariables %~ mappend vardecls)
                       . (csNames %~ M.adjust (mappend varNames) False)
                       ) inner
    return $ D.Scope (D.scoping scopeVars) scopeElem
       where convVardecl (name, pasType) = do
                varName <- alias name
                ty <- conv pasType
                return (M.singleton name varName, (varName, ty))

convScope' paramdecls inner = do
    (mconcat -> paramNames, scopeVars)
        <- unzip <$> traverse convParamdecl paramdecls
    scopeElem <- local ( (csTypes . tsVariables %~ mappend vardecls)
                       . (csNames %~ M.adjust (mappend paramNames) False)
                       ) inner
    return $ D.Scope scopeVars scopeElem
       where paramDeclToTup (S.ParamDecl name (_, ty)) = (name, ty)
             vardecls = M.fromList $ map paramDeclToTup paramdecls
             convParamdecl (S.ParamDecl name (r, pasType)) = do
                paramName <- alias name
                r' <- conv r
                ty <- conv pasType
                return (M.singleton name paramName, (paramName, (r', ty)))

instance Conv S.Body where
    type Scalar S.Body = D.Statement D.Pattern D.Expression
    conv statements = D.follow <$> traverse conv statements

instance Conv S.Func where
    type Scalar S.Func = (D.Name, D.Func D.ByType D.Pattern D.Expression)
    conv (S.Func name (S.FuncSig params pasType) vars body) = case pasType of
        Nothing -> do
            clScope <- convScope' params
                     $ convScope  vars
                     $ D.Body <$> conv body <*> pure (D.expression ())
            fname <- nameF name
            return $ (fname, D.Func D.TypeUnit clScope)
        Just ty -> do
            let retVars = M.singleton name ty
            clScope <- convScope' params
                     $ convScope (vars <> retVars)
                     $ D.Body <$> conv body <*> (D.Atom . D.Access <$> nameV name)
            retType <- conv ty
            fname <- nameF name
            return (fname, D.Func retType clScope)
    
instance Conv S.By where
    type Scalar S.By = D.By
    conv S.ByValue     = pure D.ByValue
    conv S.ByReference = pure D.ByReference

instance Conv S.Type where
    type Scalar S.Type = D.Type
    conv = \case
        S.TypeInteger -> return D.TypeInteger
        S.TypeReal    -> return D.TypeDouble
        S.TypeBoolean -> return D.TypeBoolean
        S.TypeChar    -> return D.TypeChar
        S.TypeString  -> return (D.TypeList D.TypeChar)
        S.TypeArray t -> D.TypeList <$> conv t
        S.TypeCustom _  -> error "Custom types are not implemented"

binary op a b = D.Call op [] [a,b]

convReadLn [e@(S.Access name')] = do
    name <- nameV name'
    typecheck e >>= \case
        S.TypeString -> return $ D.Exec (D.PAccess name) (D.NameSpecial D.OpGetLn) [] []
        ty' -> do
            ty <- conv ty'
            return $ D.Exec (D.PAccess name) (D.NameSpecial D.OpReadLn) [ty] []
convReadLn _ = error "IOMagic supports only single-value read operations"

convWriteLn ln exprs = do
    arg <- traverse convArg exprs <&> \case
        [] -> D.expression ""
        args -> foldr1 (binary (D.NameSpecial D.OpConcat)) args
    let op | ln = D.NameSpecial D.OpPutLn
           | otherwise = D.NameSpecial D.OpPut
    return $ D.Exec D.PUnit op [] [arg]
  where
    convArg expr = do
        tcs <- typecasts expr
        tc <- listToMaybe <$> filterM (\tc -> (==) S.TypeString <$> typecheck tc) tcs
        case tc of
            Just e  -> convExpr e
            Nothing -> case tcs of
                expr':_ -> do
                    e <- convExpr expr'
                    return $ D.Call (D.NameSpecial D.OpShow) [] [e]
                _ -> throwError errorTypecheck

typeOfLiteral :: S.Literal -> S.Type
typeOfLiteral = \case
    S.LitBool _ -> S.TypeBoolean
    S.LitInt  _ -> S.TypeInteger
    S.LitReal _ -> S.TypeReal
    S.LitChar _ -> S.TypeChar
    S.LitStr  _ -> S.TypeString

typeOfAccess :: (E e m, R m) => S.Name -> m S.Type
typeOfAccess name = do
    types <- view (csTypes.tsVariables)
    let mtype = M.lookup name types
    maybe (throwError (errorNoAccess name (M.keys types))) return mtype

typecasts :: (E e m, R m) => S.Expression -> m [S.Expression]
typecasts expr@(S.Primary lit) = return $ typecasting (typeOfLiteral lit) expr
typecasts expr@(S.Access name) = do
    ty <- typeOfAccess name
    return $ typecasting ty expr
typecasts (S.Call nameOp args) = do
    possibleArgs <- traverse typecasts args
    let calls = S.Call nameOp <$> sequenceA possibleArgs
    niceCalls <- traverse typechecking calls
    return (concat niceCalls)
        where typechecking expr =  maybe empty (\_ -> pure expr)
                               <$> typecheck' expr

typecasting :: S.Type -> S.Expression -> [S.Expression]
typecasting ty expr = expr : [op1App tc expr | tc <- tcs]
    where tcs = case ty of
            S.TypeChar    -> [S.OpCharToString]
            S.TypeInteger -> [S.OpIntToReal]
            _ -> []

typecheck :: (E e m, R m) => S.Expression -> m S.Type
typecheck expr = do
    mty <- typecheck' expr
    maybe (throwError errorTypecheck) return mty

typecheck' :: (E e m, R m) => S.Expression -> m (Maybe S.Type)
typecheck' = runMaybeT . \case
    S.Primary lit -> return (typeOfLiteral lit)
    S.Access name -> typeOfAccess name
    S.Call (Right name) args -> do
        mfuncsig <- views (csTypes.tsFunctions) (M.lookup name)
        case mfuncsig of
            Nothing -> throwError (errorNoFunction name)
            Just (S.FuncSig params mtype) -> case mtype of
                Nothing -> badType
                Just t -> do
                    let tys = params & map (\(S.ParamDecl _ (_, ty)) -> ty)
                    (sequenceA -> mtyArgs) <- traverse typecheck' args
                    case mtyArgs of
                        Just tyArgs | tyArgs == tys -> return t
                        _ -> badType
    S.Call (Left op) args -> do
        tys <- traverse typecheck args
        let isNumeric = liftA2 (||) (== S.TypeInteger) (== S.TypeReal)
        case (op, tys) of
            (S.OpAdd     , [t1, t2]) | t1 == t2, isNumeric t1 || t1 == S.TypeString -> return t1
            (S.OpSubtract, [t1, t2]) | t1 == t2, isNumeric t1 -> return t1
            (S.OpMultiply, [t1, t2]) | t1 == t2, isNumeric t1 -> return t1
            (S.OpDivide  , [S.TypeReal   , S.TypeReal   ]) -> return S.TypeReal
            (S.OpDiv     , [S.TypeInteger, S.TypeInteger]) -> return S.TypeInteger
            (S.OpMod     , [S.TypeInteger, S.TypeInteger]) -> return S.TypeInteger
            (S.OpLess    , [t1, t2]) | t1 == t2 -> return S.TypeBoolean
            (S.OpMore    , [t1, t2]) | t1 == t2 -> return S.TypeBoolean
            (S.OpLessEquals, [t1, t2]) | t1 == t2 -> return S.TypeBoolean
            (S.OpMoreEquals, [t1, t2]) | t1 == t2 -> return S.TypeBoolean
            (S.OpEquals  , [t1, t2]) | t1 == t2 -> return S.TypeBoolean
            (S.OpNotEquals, [t1, t2]) | t1 == t2 -> return S.TypeBoolean
            (S.OpAnd     , [S.TypeBoolean, S.TypeBoolean]) -> return S.TypeBoolean
            (S.OpOr      , [S.TypeBoolean, S.TypeBoolean]) -> return S.TypeBoolean
            (S.OpXor     , [S.TypeBoolean, S.TypeBoolean]) -> return S.TypeBoolean
            (S.OpNegate  , [t1]) | isNumeric t1 -> return t1
            (S.OpPlus    , [t1]) | isNumeric t1 -> return t1
            (S.OpNot     , [S.TypeBoolean]) -> return S.TypeBoolean
            (S.OpCharToString, [S.TypeChar   ]) -> return S.TypeString
            (S.OpIntToReal   , [S.TypeInteger]) -> return S.TypeReal
            _ -> badType
    where badType = MaybeT (return Nothing)

op1App :: S.Operator -> S.Expression -> S.Expression
op1App op e = S.Call (Left op) [e]

typecastConv :: (R m, G e m) => S.Type -> S.Expression -> m D.Expression
typecastConv ty expr = do
    tcs <- typecasts expr
    tc <- filterM (\tc -> (==) ty <$> typecheck tc) tcs >>= \case
        [] -> throwError errorTypecheck
        tc:_ -> return tc
    convExpr tc

instance Conv S.Statement where
    type Scalar S.Statement = D.Statement D.Pattern D.Expression
    conv = \case
        S.BodyStatement body -> D.statement <$> conv body
        S.Assign name' expr' -> do
            name <- nameV name'
            tyW <- typecheck (S.Access name')
            expr <- typecastConv tyW expr'
            return $ D.assign name expr
        S.Execute "readln"  exprs -> D.statement <$> convReadLn  exprs
        S.Execute "write"   exprs -> D.statement <$> convWriteLn False exprs
        S.Execute "writeln" exprs -> D.statement <$> convWriteLn True  exprs
        S.Execute name' exprs' -> do
            name <- nameF name'
            exprs <- traverse convExpr exprs'
            return $ D.statement $ D.Exec D.PWildCard name [] exprs
        S.ForCycle name fromExpr toExpr statement -> do
            clName <- nameV name
            clFromExpr <- convExpr fromExpr
            clToExpr   <- convExpr toExpr
            let clRange = binary (D.NameSpecial D.OpRange) clFromExpr clToExpr
            clAction <- conv statement
            let clForCycle = D.statement (D.ForCycle clName clRange clAction)
            return $ D.follow [clForCycle, D.assign clName clToExpr]
        S.IfBranch expr bodyThen mBodyElse
             -> fmap D.statement
             $  D.If
            <$> typecastConv S.TypeBoolean expr
            <*> conv bodyThen
            <*> (D.statements <$> traverse conv mBodyElse)
        S.CaseBranch expr leafs mBodyElse -> do
            clType <- typecheck expr >>= conv
            clExpr <- convExpr expr
            clName <- alias "case"
            let clCaseExpr = D.expression clName
            let instRange = \case
                    Right (exprFrom, exprTo)
                         ->  binary (D.NameSpecial D.OpElem) clCaseExpr
                        <$> (binary (D.NameSpecial D.OpRange)
                            <$> convExpr exprFrom <*> convExpr exprTo)
                    Left expr
                         -> binary (D.NameSpecial D.OpEquals) clCaseExpr
                        <$> convExpr expr
            let instLeaf (exprs, body)
                     =  (,)
                    <$> (foldr1 (binary (D.NameSpecial D.OpOr)) <$> traverse instRange exprs)
                    <*> conv body
            leafs <- traverse instLeaf leafs
            leafElse <- D.statements <$> traverse conv mBodyElse
            let statement = foldr
                    (\(cond, ifThen) ifElse ->
                        D.statement $ D.If cond ifThen ifElse)
                     leafElse leafs
            return $ D.statement $ D.Scope
                        (M.singleton clName clType)
                        (D.follow [D.assign clName clExpr, statement])

-- TODO: use typecastConv everywhere
convExpr :: (R m, G e m) => Kleisli' m S.Expression D.Expression
convExpr = \case
    S.Access name -> D.expression <$> nameV name
    S.Call name' exprs -> do
        let direct op = D.Call (D.NameSpecial op) [] <$> traverse convExpr exprs
        case name' of
            Left S.OpAdd -> do
                traverse typecheck' exprs >>= \case
                    Just S.TypeString : _ -> direct D.OpConcat
                    _ -> direct D.OpAdd
            Left S.OpSubtract -> direct D.OpSubtract
            Left S.OpMultiply -> direct D.OpMultiply
            Left S.OpDivide -> direct D.OpDivide
            Left S.OpDiv  -> direct D.OpDiv
            Left S.OpMod  -> direct D.OpMod
            Left S.OpLess -> direct D.OpLess
            Left S.OpMore -> direct D.OpMore
            Left S.OpLessEquals -> direct D.OpLessEquals
            Left S.OpMoreEquals -> direct D.OpMoreEquals
            Left S.OpNotEquals  -> direct D.OpNotEquals
            Left S.OpEquals -> direct D.OpEquals
            Left S.OpAnd -> direct D.OpAnd
            Left S.OpOr  -> direct D.OpOr
            Left S.OpXor -> direct D.OpXor
            Left S.OpPlus   -> direct D.OpId
            Left S.OpNegate -> direct D.OpNegate
            Left S.OpNot    -> direct D.OpNot
            Left S.OpCharToString -> direct D.OpSingleton
            Left S.OpIntToReal    -> direct D.OpIntToDouble
            Right name  -> D.Call
                       <$> nameF name
                       <*> pure []
                       <*> traverse convExpr exprs
    S.Primary lit -> conv lit

instance Conv S.Literal where
    type Scalar S.Literal = D.Expression
    conv = \case
        S.LitInt  x -> return (D.expression x)
        S.LitReal x -> return (D.expression x)
        S.LitStr  x -> return (D.expression x)
        S.LitChar x -> return (D.expression x)
        S.LitBool x -> return (D.expression x)
