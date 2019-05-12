module Inference
    (
      infer
    ) where

import Ast
import Data.Map.Strict as Map
import Data.Set as Set
import Data.List as List
import Control.Monad.Except
import Control.Monad.State
import Prettifier
import Actions

data TypeClass = TClass String (Type -> Bool)

instance Eq TypeClass where
    TClass name1 _ == TClass name2 _ = name1 == name2

instance Ord TypeClass where
    TClass name1 _ `compare` TClass name2 _ = name1 `compare` name2

instance Show TypeClass where
    show (TClass name _) = name

data Type = PrimT Prim
          | FuncT Type Type
          | TuplT [Type]
          | ListT Type
          | AlgeT TypeId [Type]
          | UniqT Type Bool
          | PolyT TypeVar
          deriving (Eq, Ord)

instance Show Type where
    show (PrimT prim)                = show prim 
    show (FuncT typ1 typ2)           = "(" ++ show typ1 ++ " -> " ++ show typ2 ++ ")"
    show (TuplT typs)                = "(" ++ ([show typ | typ <- init typs] >>= (++ ", ")) ++ show (last typs) ++ ")"
    show (ListT typ)                 = "[" ++ show typ ++ "]"
    show (AlgeT typeId [])           = typeName typeId
    show (AlgeT typeId ps)           = typeName typeId ++ "<" ++ ([show typ' | typ' <- init ps] >>= (++ ", ")) ++ show (last ps) ++ ">"
    show (UniqT typ _)               = show typ ++ "*"
    show (PolyT (TVar name []))      = name
    show (PolyT (TVar name classes)) = name ++ "<<" ++ ([show class' | class' <- init classes] >>= (++ ", ")) ++ show (last classes) ++ ">>"
    
-- a termconstructor has a name an associated type and optionally a signature
type TermConstructor = (TypeId, Type, Type)

type Sig = Set TermConstructor

type Constraint = (Type, Type, UtilData)

type Substitution = Map TypeVar Type

data TypeVar = TVar String [TypeClass]

instance Eq TypeVar where
    TVar name1 _ == TVar name2 _ = name1 == name2

instance Ord TypeVar where
    TVar name1 _ `compare` TVar name2 _ = name1 `compare` name2

data Scheme = ForAll [TypeVar] Type
            | LazyT ExprAST

-- type-environment type
newtype TypeEnv = TypeEnv (Map VarId Scheme)

-- type-environment binding format
type Binding = (VarId, Scheme)

class Substitutable a where
    ftv :: a -> Set TypeVar
    substitute :: Substitution ->  a -> a

instance Substitutable Type where
    ftv (PrimT _)         = Set.empty
    ftv (FuncT typ1 typ2) = (ftv typ1) `Set.union` (ftv typ2)
    ftv (TuplT typs)      = (List.foldr (Set.union . ftv) Set.empty) typs
    ftv (ListT typ)       = ftv typ
    ftv (AlgeT _ typs)    = (List.foldr (Set.union . ftv) Set.empty) typs
    ftv (UniqT typ _)     = ftv typ
    ftv (PolyT var)       = Set.singleton var

    substitute _ typ@(PrimT _)       = typ
    substitute sub (FuncT typ1 typ2) = FuncT (substitute sub typ1) (substitute sub typ2)
    substitute sub (TuplT typs)      = TuplT [substitute sub typ | typ <- typs]
    substitute sub (ListT typ)       = ListT (substitute sub typ)
    substitute sub (AlgeT name typs) = AlgeT name [substitute sub typ | typ <- typs]
    substitute sub (UniqT typ valid) = UniqT (substitute sub typ) valid
    substitute sub typ@(PolyT var)   = Map.findWithDefault typ var sub

instance Substitutable Scheme where
    ftv (ForAll vars typ) = (ftv typ) `Set.difference` Set.fromList vars
    ftv (LazyT _) = Set.empty

    substitute sub (ForAll vars typ) = ForAll vars (substitute (List.foldr Map.delete sub vars) typ)

instance Substitutable a => Substitutable [a] where
    ftv = List.foldr (Set.union . ftv) Set.empty

    substitute = fmap . substitute -- http://dev.stephendiehl.com/fun/006_hindley_milner.html

instance Substitutable TypeEnv where
    ftv (TypeEnv env) = ftv (Map.elems env)

    substitute sub (TypeEnv env) = TypeEnv (Map.map (substitute sub) env)

data TypeError = LinearTypeError Type UtilData
               | VariableScopeError VarId UtilData
               | VariableRedefinitionError VarId UtilData
               | TypeRedefinitionError TypeId UtilData
               | TermConstructorRedefinitionError TypeId UtilData
               | UndefinedTermConstructorError TypeId UtilData
               | UndefinedTypeError TypeId UtilData
               | TermConstructorTypeMisuseError TypeId VarId UtilData
               | NotAlgebraicTypeError Type UtilData
               | TermConstructorPatternMisuseError TypeId UtilData
               | TypeClassMismatchError Type Type UtilData
               | TypeMismatchError Type Type UtilData
               | MatchPatternMismatchError Type PatternAST UtilData
               | LengthMismatchError UtilData

data InferState = InferState { 
                               next        :: Integer
                             , constraints :: [Constraint]
                             , sigma       :: Sig
                             }

type InferT a = ExceptT TypeError (State InferState) a

initState = InferState { next = 0, constraints = [], sigma = Set.empty }

runInferT :: InferT Substitution -> Maybe String
runInferT m = case evalState (runExceptT m) initState of
    (Left err) -> Just $ evalError err
    (Right _)  -> Nothing

evalError :: TypeError -> String
evalError (LinearTypeError typ utilData)                      = formatErr ("instance of unique type '" ++ show typ ++ "' cannot be used more than once") utilData
evalError (VariableScopeError varId utilData)                 = formatErr ("variable '" ++ varName varId ++ "' is out of scope") utilData
evalError (VariableRedefinitionError varId utilData)          = formatErr ("global variable '" ++ varName varId ++ "' cannot be redefined globally") utilData
evalError (TypeRedefinitionError typeId utilData)             = formatErr ("algebraic type '" ++ typeName typeId ++  "' cannot be redefined") utilData
evalError (TermConstructorRedefinitionError typeId utilData)  = formatErr ("termconstructor '" ++ typeName typeId ++ "' cannot be redefined") utilData
evalError (UndefinedTermConstructorError typeId utilData)     = formatErr ("unknown termconstructor '" ++  typeName typeId ++ "'") utilData
evalError (UndefinedTypeError typeId utilData)                = formatErr ("unknown type '" ++ typeName typeId ++ "'") utilData
evalError (TermConstructorTypeMisuseError id varId utilData)  = formatErr ("algebraic type '" ++ typeName id ++ "' does not have typevariable '" ++ varName varId ++ "'") utilData
evalError (NotAlgebraicTypeError typ utilData)                = formatErr ("type '" ++ show typ ++ "' cannot be used polymorphically") utilData
evalError (TermConstructorPatternMisuseError typeId utilData) = formatErr ("termconstructor '" ++ typeName typeId ++ "' cannot be used as a constant") utilData
evalError (TypeClassMismatchError typ1 typ2 utilData)         = formatErr ("type mismatch, expected '" ++ show typ1 ++ "' but actual type '" ++ show typ2 ++ "' does not conform to the typeclasses") utilData
evalError (TypeMismatchError typ1 typ2 utilData)              = formatErr ("type mismatch, could not match expected type '" ++ show typ1 ++ "' with actual type '" ++ show typ2 ++ "'") utilData
evalError (MatchPatternMismatchError typ pat utilData)        = formatErr ("type-pattern mismatch, could not match type '" ++ show typ ++ "' with pattern '" ++ prettyShow pat 0 ++ "'") utilData
evalError (LengthMismatchError utilData)                      = formatErr ("cannot match types of different numbers of immediates") utilData

genTVar :: [TypeClass] -> InferT Type
genTVar classes = do
    state <- get
    put state{ next = next state + 1 }
    return $ PolyT (TVar (".a" ++ show (next state)) classes)

-- error message creation

-- returns a formated error message
-- based on input message and utility data
formatErr :: String -> UtilData -> String
formatErr err UtilData{position=pos, sourceLine=line} = 
    let (l, c, o) = pos
        in (show l ++ ":" ++ show c ++ ": error: " ++ 
            err ++ " in:\n" ++ (Prelude.take (o - 1) (repeat ' ')) ++ 
            "   " ++ line ++ "\n" ++ 
            "   " ++ (getIndicator (o - 1) (length line)))

getIndicator :: Int -> Int -> String
getIndicator offset len = Prelude.take offset (repeat ' ') ++ Prelude.take len (repeat '^')

-- utility functions

except :: TypeEnv -> Binding -> TypeEnv
except (TypeEnv env) (var, scheme) = TypeEnv $ Map.insert var scheme env

-- checks whether the input termconstructor (by name)
-- is defined in input set of Algebraic types
has :: Sig -> TypeId -> Bool
has sigma t =
    case find (\(t', _, _) -> t' == t) (Set.toList sigma) of
        Nothing            -> False
        (Just (_, _, _)) -> True

getSignature :: Sig -> TypeId -> Maybe Type
getSignature sigma t =
    case find (\(t', _, _) -> t' == t) (Set.toList sigma) of
        Nothing            -> Nothing
        (Just (_, _, typ)) -> Just typ
        
getTermConstructor :: Sig -> TypeId -> Maybe TermConstructor
getTermConstructor sigma t = find (\(t', _, _) -> t' == t) (Set.toList sigma)
        
-- unification

unifyAll :: InferT Substitution
unifyAll = do
    state <- get
    case constraints state of
        [] -> return Map.empty
        ((typ1, typ2, utilData):c') -> do
            put state{ constraints = c' }
            sub  <- unify typ1 typ2 utilData
            sub' <- unifyAll
            return $ sub `Map.union` sub'

unify :: Type -> Type -> UtilData -> InferT Substitution
unify typ1@(PrimT prim1) typ2@(PrimT prim2) utilData =
    if prim1 == prim2
        then return Map.empty
        else throwError $ TypeMismatchError typ1 typ2 utilData

unify typ1@(PolyT var@(TVar _ classes1)) typ2@(PolyT (TVar id classes2)) _ = do
    state <- get
    put state{ constraints = List.map (substituteConstraint) (constraints state) }
    return sub
    where
        classes' = classes1 `List.union` classes2
        sub = Map.singleton var (PolyT (TVar id classes'))
        substituteConstraint = \(t1, t2, utilData) -> (substitute sub t1, substitute sub t2, utilData)

unify typ1@(PolyT var@(TVar _ classes)) typ2 utilData =
    if List.foldr ((&&) . (checkClass typ2)) True classes
        then do 
            state <- get
            put state{ constraints = List.map (substituteConstraint) (constraints state) }
            return sub
        else throwError $ TypeClassMismatchError typ1 typ2 utilData
    where
        sub = Map.singleton var typ2
        substituteConstraint = \(t1, t2, utilData) -> (substitute sub t1, substitute sub t2, utilData)

unify typ1 typ2@(PolyT var@(TVar _ classes)) utilData =
    if List.foldr ((&&) . (checkClass typ1)) True classes
        then do 
            state <- get
            put state{ constraints = List.map (substituteConstraint) (constraints state) }
            return sub
        else throwError $ TypeClassMismatchError typ2 typ1 utilData
    where
        sub = Map.singleton var typ1
        substituteConstraint = \(t1, t2, utilData) -> (substitute sub t1, substitute sub t2, utilData)

unify (FuncT s1 s2) (FuncT t1 t2) utilData = do
    addConstraints [(s1, t1, utilData), (s2, t2, utilData)]
    return Map.empty

unify typ1@(TuplT typs1) typ2@(TuplT typs2) utilData =
    if length typs1 == length typs2
        then do
            addConstraints (List.map (\(t1, t2) -> (t1, t2, utilData)) (zip typs1 typs2))
            return Map.empty
        else throwError $ TypeMismatchError typ1 typ2 utilData

unify (ListT typ1) (ListT typ2) utilData = do
    addConstraints [(typ1, typ2, utilData)]
    return Map.empty

unify typ1@(AlgeT name1 typs1) typ2@(AlgeT name2 typs2) utilData = do
    state <- get
    if name1 == name2  && (sigma state) `has` name1 && length typs1 == length typs2
        then do
            addConstraints (List.map (\(t1, t2) -> (t1, t2, utilData)) (zip typs1 typs2))
            return Map.empty
        else throwError $ TypeMismatchError typ1 typ2 utilData

unify typ1@(UniqT typ1' valid1) typ2@(UniqT typ2' valid2) utilData =
    case (valid1, valid2) of
        (False, True)  -> throwError $ LinearTypeError typ1 utilData
        (True, False)  -> throwError $ LinearTypeError typ2 utilData
        _              -> do
            addConstraints [(typ1', typ2', utilData)]
            return Map.empty

-- catch all
unify typ1 typ2 utilData = throwError $ TypeMismatchError typ1 typ2 utilData

checkClass :: Type -> TypeClass -> Bool
checkClass typ (TClass _ fun) = fun typ

numClass  = TClass "Num" numFun 
eqClass   = TClass "Eq" eqFun
ordClass  = TClass "Ord" ordFun
showClass = TClass "Show" showFun
biClass   = TClass "Bi" biFun

numFun :: Type -> Bool
numFun (PrimT IntPrim)          = True
numFun (PrimT FloatPrim)        = True
numFun (PrimT CharPrim)         = True
numFun (UniqT typ _)            = numFun typ
numFun (PolyT (TVar _ classes)) = elem numClass classes
numFun _                        = False

eqFun :: Type -> Bool
eqFun (PrimT _)                 = True
eqFun (FuncT _ _)               = False
eqFun (TuplT typs)              = List.foldr ((&&) . eqFun) True typs
eqFun (ListT typ)               = eqFun typ
eqFun (AlgeT _ typs)            = List.foldr ((&&) . eqFun) True typs
eqFun (PolyT (TVar _ classes))  = elem eqClass classes
eqFun (UniqT typ _)             = eqFun typ

ordFun :: Type -> Bool
ordFun (PrimT IntPrim)          = True
ordFun (PrimT FloatPrim)        = True
ordFun (PrimT CharPrim)         = True
ordFun (ListT typ)              = ordFun typ
ordFun (UniqT typ _)            = ordFun typ
ordFun (PolyT (TVar _ classes)) = elem ordClass classes
ordFun _                        = False

showFun :: Type -> Bool
showFun (PrimT _)                = True
showFun (FuncT _ _)              = False
showFun (TuplT typs)             = List.foldr ((&&) . showFun) True typs
showFun (ListT typ)              = eqFun typ
showFun (AlgeT _ typs)           = List.foldr ((&&) . showFun) True typs
showFun (PolyT (TVar _ classes)) = elem showClass classes
showFun (UniqT typ _)            = showFun typ

biFun :: Type -> Bool
biFun (PrimT IntPrim)            = True
biFun (PrimT CharPrim)           = True
biFun (UniqT typ _)              = biFun typ
biFun (PolyT (TVar _ classes))   = elem biClass classes
biFun _                          = False

-- constraint rules begin

addConstraint :: Type -> Type -> UtilData -> InferT ()
addConstraint typ1 typ2 utilData = do
    state <- get
    put state{ constraints = constraints state ++ [(typ1, typ2, utilData)] }

addConstraints :: [Constraint] -> InferT ()
addConstraints constraints' = do
    state <- get
    put state{ constraints = constraints state ++ constraints' }

proj :: Scheme -> InferT Type
proj (ForAll vars typ) = do
    vars' <- mapM fresh vars
    let s = Map.fromList (zip vars vars')
    return $ substitute s typ
    where
        fresh = \(TVar _ classes) -> genTVar classes

gen :: TypeEnv -> Type -> Scheme -- http://dev.stephendiehl.com/fun/006_hindley_milner.html
gen env typ = ForAll vars typ
    where
        vars = Set.toList (ftv typ `Set.difference` ftv env)

infer :: FilePath -> ProgAST -> Maybe String
infer path ast =
    case runInferT (inferProg ast initEnv) of
        Nothing  -> Nothing
        Just msg -> Just (path ++ ":" ++ msg)
    where
        stdin'  = (VarId "stdin" Untyped, ForAll [] (UniqT (PrimT FilePrim) True))
        stdout' = (VarId "stdout" Untyped, ForAll [] (UniqT (PrimT FilePrim) True))
        initEnv = TypeEnv $ Map.fromList [stdin', stdout']

inferProg :: ProgAST -> TypeEnv -> InferT Substitution -- TODO: typeDcl and main!
inferProg (ProgAST dt dv utilData) env = do
    lsigma <- inferTypeDclLazily dt Set.empty
    inferTypeDcl dt lsigma
    env'   <- inferVarDclLazily dv env
    _      <- inferVarDcl dv env'
    unifyAll

inferTypeDclLazily :: TypeDclAST -> LazySig -> InferT LazySig
inferTypeDclLazily EpsTypeDclAST lsigma = return lsigma
inferTypeDclLazily (TypeDclAST name _ dt utilData) lsigma =
    case find (\(name', _) -> name' == name) (Set.toList lsigma) of
        Just _ -> throwError $ TypeRedefinitionError name utilData
        Nothing -> do
            let lsigma' = Set.insert (name, []) lsigma 
            inferTypeDclLazily dt lsigma'

inferTypeDclLazily (TypePolyDclAST name polys _ dt utilData) lsigma =
    case find (\(name', _) -> name' == name) (Set.toList lsigma) of
        Just _ -> throwError $ TypeRedefinitionError name utilData
        Nothing -> do
            let lsigma' = Set.insert (name, vars) lsigma 
            inferTypeDclLazily dt lsigma'
    where
        vars = List.map varName polys

inferTypeDcl :: TypeDclAST -> LazySig -> InferT ()
inferTypeDcl EpsTypeDclAST _ = return ()
inferTypeDcl (TypeDclAST name cons dt _) lsigma = do
    evalCons cons name [] Map.empty lsigma
    inferTypeDcl dt lsigma

inferTypeDcl (TypePolyDclAST name polys cons dt _) lsigma = do
    evalCons cons name vars Map.empty lsigma
    inferTypeDcl dt lsigma
    where
        vars = List.map varName polys

getAlgebraicType :: TypeId -> [String] -> InferT Type
getAlgebraicType name vars = do
    tvars <- mapVars vars
    return $ AlgeT name tvars

mapVars :: [String] -> InferT [Type]
mapVars [] = return []
mapVars (v:vs) = do
    tvar <- genTVar []
    tvars <- mapVars vs
    return (tvar:tvars)

evalCons :: [ConsAST] -> TypeId -> [String] -> Map VarId Type -> LazySig -> InferT (Map VarId Type)
evalCons [] _ _ binds _ = return binds
evalCons (tc:tcs') memberName vars binds lsigma = do
    state <- get
    memberTyp <- getAlgebraicType memberName vars
    case tc of
        (SingleConsAST name utilData) ->
            if (sigma state) `has` name
                then throwError $ TermConstructorRedefinitionError name utilData
                else do
                    put state{ sigma = Set.insert (name, memberTyp, memberTyp) (sigma state) }
                    evalCons tcs' memberName vars binds lsigma
        (DoubleConsAST name s utilData) ->
            if (sigma state) `has` name
                then throwError $ TermConstructorRedefinitionError name utilData
                else do
                    (sig, binds') <- buildSignature s memberName vars binds lsigma
                    put state{ sigma = Set.insert (name, memberTyp, FuncT sig memberTyp)  (sigma state) }
                    evalCons tcs' memberName vars binds' lsigma

buildSignature :: CompTypeAST -> TypeId -> [String] -> Map VarId Type -> LazySig -> InferT (Type, Map VarId Type)
buildSignature (CompSimpleAST typeId utilData) _ _ binds ls = do 
    typ <- lazyIdToTypes typeId ls utilData
    return (typ, binds)

buildSignature (CompSimplePolyAST varId utilData) memberName vars binds _ =
    if elem (varName varId) vars
        then case Map.lookup varId binds of
            Just tvar -> return (tvar, binds)
            Nothing -> do
                tvar <- genTVar []
                return (tvar, Map.insert varId tvar binds)
        else throwError $ TermConstructorTypeMisuseError memberName varId utilData

buildSignature (CompPolyAST typeId comps' utilData) memberName vars binds ls = do
    typ <- lazyIdToTypes typeId ls utilData
    case typ of
        AlgeT _ polys ->
            if length polys == length comps'
                then do
                    (typs, binds') <- buildSignatureList comps' memberName vars binds ls
                    return (AlgeT typeId typs, binds')
                else throwError $ LengthMismatchError utilData
        _ -> throwError $ NotAlgebraicTypeError typ utilData

buildSignature (CompListAST comp' _) memberName vars binds ls = do
    (typ, binds') <- buildSignature comp' memberName vars binds ls
    return (ListT typ, binds')

buildSignature (CompTupleAST comps' _) memberName vars binds ls = do
    (typs, binds') <- buildSignatureList comps' memberName vars binds ls
    return (TuplT typs, binds')

buildSignature (CompFuncAST comp1' comp2' _) memberName vars binds ls = do
    (typ1, binds')  <- buildSignature comp1' memberName vars binds ls
    (typ2, binds'') <- buildSignature comp2' memberName vars binds' ls
    return (FuncT typ1 typ2, binds'')

buildSignatureList :: [CompTypeAST] -> TypeId -> [String] -> Map VarId Type -> LazySig -> InferT ([Type], Map VarId Type)
buildSignatureList [] _ _ binds _ = return ([], binds)
buildSignatureList (comp:comps') memberName vars binds ls = do
    (typ, binds')   <- buildSignature comp memberName vars binds ls
    (typs, binds'') <- buildSignatureList comps' memberName vars binds' ls
    return (typ:typs, binds'')

lazyIdToTypes :: TypeId -> LazySig -> UtilData -> InferT Type
lazyIdToTypes id ls utilData =
    if last (typeName id) == '*'
        then case stringToNonUniquePrim (init (typeName id)) of
            (Just typ) -> return $ UniqT typ True
            Nothing    ->
                case find (\(id', _) -> typeName id' == init (typeName id)) (Set.toList ls) of
                    (Just (name, polys)) -> do 
                        typ <- getAlgebraicType name polys
                        return $ UniqT typ True
                    Nothing -> throwError $ UndefinedTypeError id utilData
        else case stringToNonUniquePrim (typeName id) of
            (Just typ) -> return typ
            Nothing    ->
                case find (\(id', _) -> id' == id) (Set.toList ls) of
                    (Just (name, polys)) -> getAlgebraicType name polys
                    Nothing -> throwError $ UndefinedTypeError id utilData

stringToNonUniquePrim :: String -> Maybe Type
stringToNonUniquePrim "Int"    = Just $ PrimT IntPrim
stringToNonUniquePrim "Float"  = Just $ PrimT FloatPrim
stringToNonUniquePrim "Bool"   = Just $ PrimT BoolPrim
stringToNonUniquePrim "Char"   = Just $ PrimT CharPrim
stringToNonUniquePrim "File"   = Just $ PrimT FilePrim
stringToNonUniquePrim "System" = Just $ PrimT SystemPrim
stringToNonUniquePrim "String" = Just $ ListT (PrimT CharPrim)
stringToNonUniquePrim _        = Nothing

freshType :: Type -> InferT Type
freshType typ@(PrimT _) = return typ
freshType (FuncT typ1 typ2) = do
    typ1' <- freshType typ1
    typ2' <- freshType typ2
    return $ FuncT typ1' typ1'

freshType (TuplT typs) = do
    typs' <- freshTypes typs
    return $ TuplT typs'

freshType (ListT typ) = do
    typ' <- freshType typ
    return $ ListT typ'

freshType (AlgeT name typs) = do
    typs' <- freshTypes typs
    return $ AlgeT name typs'

freshType (UniqT typ valid) = do
    typ' <- freshType typ
    return $ UniqT typ' valid

freshType (PolyT (TVar _ classes)) = genTVar classes

freshTypes :: [Type] -> InferT [Type]
freshTypes [] = return []
freshTypes (typ:typs) = do
    typ  <- freshType typ
    typs <- freshTypes typs
    return (typ:typs)

inferVarDclLazily :: VarDclAST -> TypeEnv -> InferT TypeEnv
inferVarDclLazily EpsVarDclAST env = return env
inferVarDclLazily (VarDclAST (UntypedVarAST varId _) expr dv utilData) env = inferVarDclLazily dv (env `except` (varId, LazyT expr))

inferVarDclLazily (VarDclAST (TypedVarAST varId s _) _ dv utilData) env = error "not yet implemented!" -- TODO: annotations

inferVarDcl :: VarDclAST -> TypeEnv -> InferT TypeEnv
inferVarDcl EpsVarDclAST env = return env
inferVarDcl (VarDclAST (UntypedVarAST varId _) expr dv utilData) env = do
    tvar <- genTVar []
    _ <- inferExpr expr (env `except` (varId, ForAll [] tvar))
    inferVarDcl dv env

inferVarDcl (VarDclAST (TypedVarAST varId s _) expr dv utilData) env = error "not yet implemented!" -- TODO: annotations  

inferExpr :: ExprAST -> TypeEnv -> InferT (Type, [Binding])
inferExpr (VarExprAST varId utilData) env@(TypeEnv env') =
    case Map.lookup varId env' of
        Nothing -> throwError $ VariableScopeError varId utilData
        Just (LazyT expr) -> do
            tvar <- genTVar []
            (typ, binds) <- inferExpr expr (env `except` (varId, ForAll [] tvar))
            let typ' = case typ of
                    UniqT utyp _ -> UniqT utyp False
                    _            -> typ   
            return (typ, binds ++ [(varId, ForAll [] typ')])
        Just typ@(ForAll vars typ') -> do
            ins <- proj typ
            return (ins, [(varId, ForAll vars typ'')])
            where
                typ'' = case typ' of
                    UniqT utyp _ -> UniqT utyp False
                    _            -> typ'   

inferExpr (ConstExprAST c _) _ = do 
    typ <- inferConst c
    return (typ, [])

inferExpr (TypeExprAST typeId utilData) _ = do
    state <- get
    case getSignature (sigma state) typeId of
        Nothing  -> throwError $ UndefinedTermConstructorError typeId utilData
        Just typ -> do 
            typ' <- freshType typ
            return (typ', [])

inferExpr (ParenExprAST expr _) env = inferExpr expr env

inferExpr (LambdaExprAST (UntypedVarAST varId _) expr _) env = do
    tvar <- genTVar []
    let env' = env `except` (varId, ForAll [] tvar)
    (typ, bindings) <- inferExpr expr env'
    return (FuncT tvar typ, bindings)

inferExpr (FunAppExprAST expr1 expr2 utilData) env = do
    (typ1, binds)  <- inferExpr expr1 env
    let env' = applyBindings env binds
    (typ2, binds') <- inferExpr expr2 env'
    tvar <- genTVar []
    addConstraint typ1 (FuncT typ2 tvar) utilData
    return (tvar, binds ++ binds')

inferExpr (TupleExprAST exprs _) env = do
    (typs, binds) <- inferExprs exprs env
    return (TuplT typs, binds)

inferExpr (ListExprAST exprs utilData) env = do
    (typs, binds) <- inferExprs exprs env
    case typs of
        [] -> do
            tvar <- genTVar []
            return (ListT tvar, binds)
        (typ:typs') -> do
            addConstraints [(typ, typ', utilData) | typ' <- typs']
            return (ListT typ, binds) 

inferExpr (LetInExprAST (UntypedVarAST varId _) expr1 expr2 utilData) env = do
    tvar <- genTVar []
    let env' = env `except` (varId, ForAll [] tvar)
    (_, binds) <- inferExpr expr1 env'
    let env'' = applyBindings env' binds
    let scheme = LazyT expr1
    (typ2, binds') <- inferExpr expr2 (env'' `except` (varId, scheme))
    return (typ2, binds ++ binds')

inferExpr (CaseExprAST branches utilData) env = do
    typs <- inferCaseBranches branches env
    case typs of
        [] -> error "a case expression must have at least one branch" -- should not happen
        (typ:typs') -> do
            addConstraints [(typ, typ', utilData) | typ' <- typs']
            return (typ, [])

inferExpr (MatchExprAST expr branches utilData) env = do
    (typ1, binds) <- inferExpr expr env
    let env' = applyBindings env binds
    typ2s <- inferMatchBranches typ1 branches env'
    case typ2s of
        [] -> error "a match expression must have at least one branch" -- should not happen
        (typ2:typ2s') -> do 
            addConstraints [(typ2, typ2', utilData) | typ2' <- typ2s']
            return (typ2, binds)

inferExprs :: [ExprAST] -> TypeEnv -> InferT ([Type], [Binding])
inferExprs [] _ = return ([], [])
inferExprs (e:es) env = do
    (typ, binds)   <- inferExpr e env
    let env' = applyBindings env binds
    (typs, binds') <- inferExprs es env
    return (typ:typs, binds ++ binds')

applyBindings :: TypeEnv -> [Binding] -> TypeEnv
applyBindings env binds = List.foldr (flip except) env binds

inferCaseBranches :: [(PredAST, ExprAST)] -> TypeEnv -> InferT [Type]
inferCaseBranches [] _ = return []
inferCaseBranches ((PredWildAST _, expr):branches) env = do
    (typ, _) <- inferExpr expr env
    typs <- inferCaseBranches branches env
    return (typ:typs)

inferCaseBranches ((PredExprAST expr1 utilData, expr2):branches) env = do
    (typ1, binds) <- inferExpr expr1 env
    let env' = applyBindings env binds
    (typ2, _) <- inferExpr expr2 env'
    addConstraint typ1 (PrimT BoolPrim) utilData
    typ2s <- inferCaseBranches branches env
    return (typ2:typ2s)

inferMatchBranches :: Type -> [(PatternAST, ExprAST)] -> TypeEnv -> InferT [Type]
inferMatchBranches _ [] _ = return []
inferMatchBranches typ1 ((pat, expr):branches) env = do
    (typ1', binds) <- match typ1 pat
    let env' = applyBindings env binds
    (typ2, _) <- inferExpr expr env'
    typs2 <- inferMatchBranches typ1' branches env
    return (typ2:typs2)

binaryFun :: [TypeClass] -> InferT Type
binaryFun classes = do
    tvar <- genTVar classes
    return $ FuncT tvar (FuncT tvar tvar)

inferConst :: ConstAST -> InferT Type
inferConst (IntConstAST _ _)   = return $ PrimT IntPrim
inferConst (BoolConstAST _ _)  = return $ PrimT BoolPrim 
inferConst (FloatConstAST _ _) = return $ PrimT FloatPrim
inferConst (CharConstAST _ _)  = return $ PrimT CharPrim

inferConst (UnaryMinusConstAST _) = do
    tvar <- genTVar [numClass]
    return $ FuncT tvar tvar

inferConst (PlusConstAST _)   = binaryFun [numClass]
inferConst (MinusConstAST _)  = binaryFun [numClass]
inferConst (TimesConstAST _)  = binaryFun [numClass]
inferConst (DivideConstAST _) = binaryFun [numClass]
inferConst (ModuloConstAST _) = binaryFun [numClass]

inferConst (EqualsConstAST _) = do
    tvar <- genTVar [eqClass]
    return $ FuncT tvar (FuncT tvar (PrimT BoolPrim))

inferConst (NotConstAST _) = return $ FuncT (PrimT BoolPrim) (PrimT BoolPrim)

inferConst (GreaterConstAST _) = do
    tvar <- genTVar [ordClass]
    return $ FuncT tvar (FuncT tvar (PrimT BoolPrim))

inferConst (LessConstAST _) = do
    tvar <- genTVar [ordClass]
    return $ FuncT tvar (FuncT tvar (PrimT BoolPrim)) 

inferConst (GreaterOrEqualConstAST _) = do
    tvar <- genTVar [ordClass]
    return $ FuncT tvar (FuncT tvar (PrimT BoolPrim))

inferConst (LessOrEqualConstAST _) = do
    tvar <- genTVar [ordClass]
    return $ FuncT tvar (FuncT tvar (PrimT BoolPrim)) 

inferConst (AppenConstAST _) = do
    tvar <- genTVar []
    return $ FuncT (tvar) (FuncT (ListT tvar) (ListT tvar))

inferConst (ConcatenateConstAST _) = do
    tvar <- genTVar []
    return $ FuncT (ListT tvar) (FuncT (ListT tvar) (ListT tvar))

inferConst (AndConstAST _) = return $ FuncT (PrimT BoolPrim) (FuncT (PrimT BoolPrim) (PrimT BoolPrim)) 
inferConst (OrConstAST _)  = return $ FuncT (PrimT BoolPrim) (FuncT (PrimT BoolPrim) (PrimT BoolPrim))

inferConst (BiLShiftConstAST _) = binaryFun [biClass] 
inferConst (BiRShiftConstAST _) = binaryFun [biClass] 
inferConst (BiNotConstAST _)    = binaryFun [biClass] 
inferConst (BiAndConstAST _)    = binaryFun [biClass] 
inferConst (BiXorConstAST _)    = binaryFun [biClass] 
inferConst (BiOrConstAST _)     = binaryFun [biClass] 

inferConst (OpenReadConstAST _)  = return $ FuncT (UniqT (PrimT SystemPrim) True) (FuncT (ListT (PrimT CharPrim)) (TuplT [PrimT BoolPrim, UniqT (PrimT SystemPrim) True, UniqT (PrimT FilePrim) True]))
inferConst (OpenWriteConstAST _) = return $ FuncT (UniqT (PrimT SystemPrim) True) (FuncT (ListT (PrimT CharPrim)) (TuplT [PrimT BoolPrim, UniqT (PrimT SystemPrim) True, UniqT (PrimT FilePrim) True]))
inferConst (CloseConstAST _)     = return $ FuncT (UniqT (PrimT SystemPrim) True) (FuncT (UniqT (PrimT FilePrim) True) (TuplT [PrimT BoolPrim, UniqT (PrimT SystemPrim) True]))
inferConst (ReadConstAST _)      = return $ FuncT (UniqT (PrimT FilePrim) True) (TuplT [PrimT BoolPrim, PrimT CharPrim, UniqT (PrimT FilePrim) True])
inferConst (WriteConstAST _)     = return $ FuncT (PrimT CharPrim) (FuncT (UniqT (PrimT FilePrim) True) (TuplT [PrimT BoolPrim, UniqT (PrimT FilePrim) True]))
inferConst (DeleteConstAST _)    = return $ FuncT (UniqT (PrimT SystemPrim) True) (FuncT (UniqT (PrimT FilePrim) True) (TuplT [PrimT BoolPrim, UniqT (PrimT SystemPrim) True]))
inferConst (ToIntConstAST _)     = return $ FuncT (ListT (PrimT CharPrim)) (TuplT [PrimT BoolPrim, PrimT IntPrim])
inferConst (ToFloatConstAST _)   = return $ FuncT (ListT (PrimT CharPrim)) (TuplT [PrimT BoolPrim, PrimT FloatPrim])
inferConst (IntToCharAST _)      = return $ FuncT (PrimT IntPrim) (PrimT CharPrim)
inferConst (CharToIntAST _)      = return $ FuncT (PrimT CharPrim) (PrimT IntPrim)

inferConst (ShowConstAST _)      = do
    tvar <- genTVar [showClass]
    return $ FuncT tvar (ListT (PrimT CharPrim))

inferPat :: PatternAST -> InferT (Type, [Binding])
inferPat (ConstPatternAST c _) = do
    typ <- inferConst c
    return (typ, [])

inferPat (VarPatternAST varId _) = do
    tvar <- genTVar []
    return (tvar, [(varId, ForAll [] tvar)])

inferPat (WildPatternAST _) = do
    tvar <- genTVar []
    return (tvar, [])

inferPat (TypePatternAST typeId utilData) = do
    state <- get
    case getTermConstructor (sigma state) typeId of
        Nothing -> throwError $ UndefinedTermConstructorError typeId utilData
        (Just (_, _, typ@(AlgeT name' _))) -> return (typ, [])
        (Just _) -> throwError $ TermConstructorPatternMisuseError typeId utilData

inferPat (TypeConsPatternAST typeId pat' utilData) = do
    state <- get
    case getTermConstructor (sigma state) typeId of
        Nothing -> throwError $ UndefinedTermConstructorError typeId utilData
        (Just (_, _, FuncT sig (AlgeT _ _))) -> do
            sig' <- freshType sig
            match sig' pat'
        (Just _) -> throwError $ TermConstructorPatternMisuseError typeId utilData

inferPat (ListPatternAST [] _) = do
    tvar <- genTVar []
    return (ListT tvar, [])

inferPat (ListPatternAST (pat:pats) utilData) = do
     (typ, binds) <- inferPat pat
     let typs = List.take (length pats) (repeat typ)
     (_, binds') <- matchMultiple typs pats utilData
     return (ListT typ, binds ++ binds')

inferPat (TuplePatternAST pats _) = do
    (typs, binds) <- inferPats pats
    return (TuplT typs, binds)

inferPat (DecompPatternAST pat varId _) = do
    (typ, binds) <- inferPat pat
    return (ListT typ, [(varId, ForAll [] typ)])

inferPats :: [PatternAST] -> InferT ([Type], [Binding])
inferPats [] = return ([], [])
inferPats (pat:pats) = do
    (typ, binds)   <- inferPat pat
    (typs, binds') <- inferPats pats
    return (typ:typs, binds ++ binds')

match :: Type -> PatternAST -> InferT (Type, [Binding])
match typ (VarPatternAST varId _) = return (typ, [(varId, ForAll [] typ)])

match typ (WildPatternAST _) = return (typ, [])

match typ@(PolyT (TVar _ classes)) pat = do
    (typ', binds) <- inferPat pat
    if List.foldr ((&&) . (checkClass typ')) True classes
        then return (typ', binds)
        else throwError $ MatchPatternMismatchError typ pat (getUtilDataPat pat)

match typ@(PrimT (IntPrim)) (ConstPatternAST (IntConstAST _ _) _)     = return (typ, [])
match typ@(PrimT (FloatPrim)) (ConstPatternAST (FloatConstAST _ _) _) = return (typ, [])
match typ@(PrimT (BoolPrim)) (ConstPatternAST (BoolConstAST _ _) _)   = return (typ, [])
match typ@(PrimT (CharPrim)) (ConstPatternAST (CharConstAST _ _) _)   = return (typ, [])

match typ@(AlgeT name _) pat@(TypePatternAST typeId utilData) = do
    state <- get
    case getTermConstructor (sigma state) typeId of
        Nothing -> throwError $ UndefinedTermConstructorError typeId utilData
        (Just (_, _, AlgeT name' _)) ->
            if name' == name
                then return (typ, [])
                else throwError $ MatchPatternMismatchError typ pat utilData
        (Just _) -> throwError $ MatchPatternMismatchError typ pat utilData

match (ListT typ') (DecompPatternAST pat' varId _) = do
    (typ'', binds) <- match typ' pat'
    return (ListT typ'', ((varId, ForAll [] (ListT typ'')):binds))

match typ@(AlgeT name typs) pat@(TypeConsPatternAST typeId pat' utilData) = do
    state <- get
    case getTermConstructor (sigma state) typeId of
        Nothing             -> throwError $ UndefinedTermConstructorError typeId utilData
        Just (_, _, FuncT sig (AlgeT name' typs')) ->
            if name' == name
                then do
                    sub <- analyzeVars typs' typs Map.empty
                    let sig' = substitute sub sig
                    match sig' pat'
                else throwError $ MatchPatternMismatchError typ pat utilData
        Just _ -> throwError $ MatchPatternMismatchError typ pat utilData

match typ@(TuplT typs) pat@(TuplePatternAST ps utilData) = do 
    (typs, binds) <- matchMultiple typs ps utilData
    return (TuplT typs, binds)

match typ@(ListT typ') (ListPatternAST ps utilData) = do 
    (typs'', binds) <- matchMultiple typs' ps utilData
    case typs'' of
        []        -> return (typ, binds)
        (typ'':_) -> return (ListT typ'', binds)
    where
        typs' = List.take (length ps) (repeat typ')

match typ pat = throwError $ MatchPatternMismatchError typ pat (getUtilDataPat pat)

matchMultiple :: [Type] -> [PatternAST] -> UtilData -> InferT ([Type], [Binding])
matchMultiple [] [] _       = return ([], [])
matchMultiple [] _ utilData = throwError $ LengthMismatchError utilData
matchMultiple _ [] utilData = throwError $ LengthMismatchError utilData
matchMultiple (t:ts) (p:ps) utilData = do
    (typ, binds)   <- match t p
    (typs, binds') <- matchMultiple ts ps utilData
    return $ (typ:typs, binds ++ binds')

analyzeVars :: [Type] -> [Type] -> Substitution -> InferT Substitution
analyzeVars [] [] sub = return sub
analyzeVars ((PolyT tvar):t1s) (t2:t2s) sub = analyzeVars t1s t2s (Map.insert tvar t2 sub)
analyzeVars _ _ _ = error "mismatched typevariables" -- should not happen