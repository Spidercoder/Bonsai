module Semantics
    ( interpret
    ) where

import Ast
import Data.Map.Strict as Map
import Data.Set as Set
import System.IO
import System.Directory

type Sort = String

data Signature = ConstSig Sort
               | FuncSig Sort Sort
               deriving (Eq, Ord)

type Binding = (VarId, Values)

data Bindings = MatchFail
              | Bindings [(VarId, Values)]

type TermConstructor = (TypeId, Signature)
type Env = Map VarId Values
type Sig = Set TermConstructor

stringFromValuesList :: [Values] -> String
stringFromValuesList [] = []
stringFromValuesList ((ConstValue (CharConstAST chr)):xs) = [chr] ++ stringFromValuesList xs
stringFromValuesList _ = error "error: value must be a list of characters."

data Values = ConstValue ConstAST
            | TerValue TypeId
            | TerConsValue TypeId Values
            | ClosureValue VarId ExprAST Env Sig
            | RecClosureValue VarId VarId ExprAST Env Sig
            | SystemValue Integer
            | FileValue Handle Integer
            | PredefinedFileValue String Integer
            | TupleValue [Values]
            | ListValue [Values]
            | PartialValue (Values -> IO Values)

sortsType :: TypeId -> Sort
sortsType typeId = typeName typeId

sorts :: CompTypeAST -> Sort
sorts (CompSimpleAST typeId) = sortsType typeId
sorts (CompListAST comp') = "[" ++ sorts comp' ++ "]"
sorts (CompTupleAST comps') = "(" ++ ([sorts comp' | comp' <- comps'] >>= (++ ", ")) ++ ")"
sorts (CompFuncAST comp1' comp2') = sorts comp1' ++ "->" ++ sorts comp2'

except :: Env -> Binding -> Env
except env (var, value) = Map.insertWith const var value env

unionSig :: Sig -> Sig -> Sig
unionSig sigma1 sigma2 = Set.union sigma1 sigma2

getVar :: Env -> VarId -> Maybe Values
getVar env var = Map.lookup var env

has :: Sig -> TypeId -> Bool
has sigma t = let termCons = Set.toList sigma
                in hasRec termCons t

hasRec :: [TermConstructor] -> TypeId -> Bool
hasRec [] _            = False
hasRec ((t', _):remainder) t = 
    if t' == t
        then True
        else hasRec remainder t

evaluateTermCons :: ConsAST -> TypeId -> TermConstructor
evaluateTermCons (SingleConsAST t) typeId          = (t, ConstSig (sortsType typeId))
evaluateTermCons (DoubleConsAST t compType) typeId = (t, FuncSig (sorts compType) (sortsType typeId))

interpret :: ProgAST -> IO Values
interpret (ProgAST dt dv) = do
    sigma <- evalTypeDcl dt (Set.empty)
    env <- evalVarDcl dv initEnv sigma
    let (maybeMain) = env `getVar` (VarId "main")
        in case maybeMain of
            Nothing -> error "error: main is not defined"
            (Just (RecClosureValue _ x e env2 sigma2)) -> 
                let env' = env2 `except` (x, SystemValue 0)
                    in evalExpr e env' sigma2
            _ -> error "error: invalid main signature."
    where
        stdin' = PredefinedFileValue "stdin" 0
        stdout' = PredefinedFileValue "stdout" 0
        initEnv = Map.fromList [(VarId "stdin", stdin'), (VarId "stdout", stdout')] 

evalTypeDcl :: TypeDclAST -> Sig -> IO Sig
evalTypeDcl dt sigma =
    case dt of
        EpsTypeDclAST              -> return sigma
        TypeDclAST typeId cons dt' -> evalTypeDcl dt' (sigma `unionSig` (Set.fromList [evaluateTermCons ts typeId | ts <- cons])) 

evalVarDcl :: VarDclAST -> Env -> Sig -> IO Env
evalVarDcl dv env sigma =
    case dv of
        EpsVarDclAST          -> return env
        VarDclAST xt expr dv' -> do
            value <- evalExpr expr env sigma
            case value of
                (ClosureValue x' e' env2 sigma') -> evalVarDcl dv' (env `except` (x, RecClosureValue x x' e' env2 sigma')) sigma
                _                                -> evalVarDcl dv' (env `except` (x, value)) sigma
            where
                x = case xt of
                    UntypedVarAST varId -> varId
                    TypedVarAST varId _ -> varId

evalExpr :: ExprAST -> Env -> Sig -> IO Values
evalExpr expr env sigma = do
    case expr of
        (VarExprAST varId)            -> evalVarExpr varId env sigma
        (TypeExprAST typeId)          -> return $ TerValue typeId
        (ConstExprAST c)              -> return $ ConstValue c
        (ParenExprAST expr')          -> evalExpr expr' env sigma
        (LambdaExprAST varId expr')   -> return $ ClosureValue varId expr' env sigma
        (FunAppExprAST expr1 expr2)   -> evalFunApp expr1 expr2 env sigma
        (TupleExprAST exprs)          -> evalTuple exprs env sigma
        (ListExprAST exprs)           -> evalList exprs env sigma
        (CaseExprAST branches)        -> evalCase branches env sigma
        (LetInExprAST xt expr1 expr2) -> evalLetIn xt expr1 expr2 env sigma
        (MatchExprAST expr' branches) -> do
            value <- evalExpr expr' env sigma
            evalMatch value branches env sigma

evalVarExpr :: VarId -> Env -> Sig -> IO Values
evalVarExpr varId env _ =
    case maybeValue of
        Nothing      -> error $ "error: variable '" ++ varName varId ++ "' is out of scope."
        (Just value) -> return value
    where
        maybeValue = env `getVar` varId

evalTuple :: [ExprAST] -> Env -> Sig -> IO Values
evalTuple exprs env sigma = do
    body <- evalExprs exprs env sigma
    return $ TupleValue body

evalList :: [ExprAST] -> Env -> Sig -> IO Values
evalList exprs env sigma = do
    body <- evalExprs exprs env sigma
    return $ ListValue body

evalExprs :: [ExprAST] -> Env -> Sig -> IO [Values]
evalExprs [] _ _           = return []
evalExprs (e:es) env sigma = do 
    value <- evalExpr e env sigma
    values <- evalExprs es env sigma
    return (value:values)

evalFunApp :: ExprAST -> ExprAST -> Env -> Sig -> IO Values
evalFunApp expr1 expr2 env sigma = do
    v <- evalExpr expr1 env sigma
    v' <- evalExpr expr2 env sigma
    case v of
        (ConstValue c)                      -> partiallyApply c v'
        (PartialValue f)                    -> f v'
        (ClosureValue x e env' sigma')      -> evalExpr e (env' `except` (x, v')) sigma'
        (RecClosureValue f x e env' sigma') -> evalExpr e ((env' `except` (x, v')) `except` (f, v)) sigma'   
        (TerValue t)                        -> return $ TerConsValue t v'
        _                                   -> error "error: invalid function type."

partiallyApply :: ConstAST -> Values -> IO Values
partiallyApply UnaryMinusConstAST value     = apply UnaryMinusConstAST [value]
partiallyApply NotConstAST value            = apply NotConstAST [value]
partiallyApply PlusConstAST value           = return $ PartialValue (\y -> apply PlusConstAST [value, y])
partiallyApply MinusConstAST value          = return $ PartialValue (\y -> apply MinusConstAST [value, y])
partiallyApply TimesConstAST value          = return $ PartialValue (\y -> apply TimesConstAST [value, y])
partiallyApply DivideConstAST value         = return $ PartialValue (\y -> apply DivideConstAST [value, y])
partiallyApply ModuloConstAST value         = return $ PartialValue (\y -> apply ModuloConstAST [value, y])
partiallyApply EqualsConstAST value         = return $ PartialValue (\y -> apply EqualsConstAST [value, y])
partiallyApply GreaterConstAST value        = return $ PartialValue (\y -> apply GreaterConstAST [value, y])
partiallyApply LessConstAST value           = return $ PartialValue (\y -> apply LessConstAST [value, y])
partiallyApply GreaterOrEqualConstAST value = return $ PartialValue (\y -> apply GreaterOrEqualConstAST [value, y])
partiallyApply LessOrEqualConstAST value    = return $ PartialValue (\y -> apply LessOrEqualConstAST [value, y])
partiallyApply AppenConstAST value          = return $ PartialValue (\y -> apply AppenConstAST [value, y])
partiallyApply ConcatenateConstAST value    = return $ PartialValue (\y -> apply ConcatenateConstAST [value, y])
partiallyApply AndConstAST value            = return $ PartialValue (\y -> apply AndConstAST [value, y])
partiallyApply OrConstAST value             = return $ PartialValue (\y -> apply OrConstAST [value, y])
partiallyApply OpenReadConstAST value       = return $ PartialValue (\y -> apply OpenReadConstAST [value, y])
partiallyApply OpenWriteConstAST value      = return $ PartialValue (\y -> apply OpenWriteConstAST [value, y])
partiallyApply CloseConstAST value          = return $ PartialValue (\y -> apply CloseConstAST [value, y])
partiallyApply ReadConstAST value           = return $ PartialValue (\y -> apply ReadConstAST [value, y])
partiallyApply WriteConstAST value          = return $ PartialValue (\y -> apply WriteConstAST [value, y])
partiallyApply DeleteConstAST value         = return $ PartialValue (\y -> apply DeleteConstAST [value, y])
partiallyApply _ _                          = error "error: cannot partially apply a non-function constant."

evalLetIn :: TypeVarAST -> ExprAST -> ExprAST -> Env -> Sig -> IO Values
evalLetIn xt expr1 expr2 env sigma = do
    value <- evalExpr expr1 env sigma
    case value of
        (ClosureValue x' expr' env' sigma') -> evalExpr expr2 (env `except` (x, RecClosureValue x x' expr' env' sigma')) sigma
        _                  -> evalExpr expr2 (env `except` (x, value)) sigma
    where
        x = case xt of
            UntypedVarAST varId -> varId
            TypedVarAST varId _ -> varId

evalCase :: [(PredAST, ExprAST)] -> Env -> Sig -> IO Values
evalCase [] _ _ = error "error: non-exhaustive case branches."
evalCase ((pred', expr'):branches') env sigma = do
    res <- handlePred pred' env sigma
    if res
        then evalExpr expr' env sigma
        else evalCase branches' env sigma

handlePred :: PredAST -> Env -> Sig -> IO Bool
handlePred PredWildAST _ _              = return True
handlePred (PredExprAST expr) env sigma = do 
    res <- evalExpr expr env sigma
    case res of
        (ConstValue (BoolConstAST b)) -> return b
        _                             -> error "error: case condition must be a predicate or wildcard."


evalMatch :: Values -> [(PatternAST, ExprAST)] -> Env -> Sig -> IO Values
evalMatch _ [] _ _                                 = error "error: non-exhaustive match branches."
evalMatch value ((pat', expr'):branches') env sigma =
    case match value pat' sigma of
        MatchFail      -> evalMatch value branches' env sigma
        Bindings delta -> evalExpr expr' (applyBindings env delta) sigma

applyBindings :: Env -> [Binding] -> Env -- TODO! test intersection ..
applyBindings env []     = env
applyBindings env (b:bs) = applyBindings (env `except` b) bs

match :: Values -> PatternAST -> Sig -> Bindings
match value (VarPatternAST varId) _ = Bindings [(varId, value)]

match _ WildPatternAST _ = Bindings []

match (ConstValue c1) (ConstPatternAST c2) _ = 
    if c1 == c2 
        then Bindings [] 
        else MatchFail

match (TerValue t1) (TypePatternAST t2) sigma =
    if (sigma `has` t1) && (sigma `has` t2)
        then if t1 == t2 
                then Bindings []
                else MatchFail
        else error "error: unknown term constructor." 

match (ListValue (v:vs)) (DecompPatternAST pat' varId) sigma =
    case delta of
       MatchFail      -> MatchFail
       Bindings binds -> Bindings ((varId, v'):binds)
    where
        v' = ListValue vs
        delta = match v pat' sigma

match (TupleValue vs) (TuplePatternAST ps) sigma = matchMultiple vs ps sigma

match (ListValue []) (ListPatternAST []) _ = Bindings []
match (ListValue vs) (ListPatternAST ps) sigma = matchMultiple vs ps sigma                

match (TerConsValue t1 value) (TypeConsPatternAST t2 pat') sigma =
    if (sigma `has` t1) && (sigma `has` t2)
        then if t1 == t2 
                then match value pat' sigma
                else MatchFail
        else error "error: unknown term constructor."

match _ _ _ = MatchFail


matchMultiple :: [Values] -> [PatternAST] -> Sig -> Bindings
matchMultiple [] [] _             = Bindings []
matchMultiple (v:vs) (p:ps) sigma =
    if (length vs) /= (length ps)
        then MatchFail
        else case (bind, binds) of
                (MatchFail, _)             -> MatchFail
                (_, MatchFail)             -> MatchFail
                (Bindings l1, Bindings l2) -> Bindings (l1 ++ l2)
            where
                bind  = match v p sigma
                binds = matchMultiple vs ps sigma

matchMultiple _ _ _ = MatchFail


advanceSystem :: Values -> Values
advanceSystem (SystemValue sys) = SystemValue (sys + 1)
advanceSystem _                 = error "error: cannot advance a non-system value."

advanceFile :: Values -> Values
advanceFile (FileValue h id')          = FileValue h (id' + 1)
advanceFile (PredefinedFileValue s f) = PredefinedFileValue s (f + 1)
advanceFile _                         = error "error: cannot advance a non-file value."

apply :: ConstAST -> [Values] -> IO Values
apply UnaryMinusConstAST [ConstValue (IntConstAST v1)]                                    = return $ ConstValue (IntConstAST (-v1))
apply UnaryMinusConstAST [ConstValue (FloatConstAST v1)]                                  = return $ ConstValue (FloatConstAST (-v1))
apply PlusConstAST [ConstValue (IntConstAST v1), ConstValue (IntConstAST v2)]             = return $ ConstValue (IntConstAST (v1 + v2))
apply PlusConstAST [ConstValue (FloatConstAST v1), ConstValue (FloatConstAST v2)]         = return $ ConstValue (FloatConstAST (v1 + v2))
apply MinusConstAST [ConstValue (IntConstAST v1), ConstValue (IntConstAST v2)]            = return $ ConstValue (IntConstAST (v1 - v2))
apply MinusConstAST [ConstValue (FloatConstAST v1), ConstValue (FloatConstAST v2)]        = return $ ConstValue (FloatConstAST (v1 - v2))
apply TimesConstAST [ConstValue (IntConstAST v1), ConstValue (IntConstAST v2)]            = return $ ConstValue (IntConstAST (v1 * v2))
apply TimesConstAST [ConstValue (FloatConstAST v1), ConstValue (FloatConstAST v2)]        = return $ ConstValue (FloatConstAST (v1 * v2))
apply DivideConstAST [ConstValue (IntConstAST v1), ConstValue (IntConstAST v2)]           = return $ ConstValue (IntConstAST (v1 `div` v2))
apply DivideConstAST [ConstValue (FloatConstAST v1), ConstValue (FloatConstAST v2)]       = return $ ConstValue (FloatConstAST (v1 / v2))
apply ModuloConstAST [ConstValue (IntConstAST v1), ConstValue (IntConstAST v2)]           = return $ ConstValue (IntConstAST (v1 `mod` v2))
apply EqualsConstAST [ConstValue (BoolConstAST v1), ConstValue (BoolConstAST v2)]         = return $ ConstValue (BoolConstAST (v1 == v2))
apply NotConstAST [ConstValue (BoolConstAST v1)]                                          = return $ ConstValue (BoolConstAST (not v1))
apply GreaterConstAST [ConstValue (BoolConstAST v1), ConstValue (BoolConstAST v2)]        = return $ ConstValue (BoolConstAST (v1 > v2))
apply LessConstAST [ConstValue (BoolConstAST v1), ConstValue (BoolConstAST v2)]           = return $ ConstValue (BoolConstAST (v1 < v2))
apply GreaterOrEqualConstAST [ConstValue (BoolConstAST v1), ConstValue (BoolConstAST v2)] = return $ ConstValue (BoolConstAST (v1 >= v2))
apply LessOrEqualConstAST [ConstValue (BoolConstAST v1), ConstValue (BoolConstAST v2)]    = return $ ConstValue (BoolConstAST (v1 <= v2))
apply AppenConstAST [v1, ListValue v2]                                                    = return $ ListValue (v1:v2)
apply ConcatenateConstAST [ListValue v1, ListValue v2]                                    = return $ ListValue (v1 ++ v2)
apply AndConstAST [ConstValue (BoolConstAST v1), ConstValue (BoolConstAST v2)]            = return $ ConstValue (BoolConstAST (v1 && v2))
apply OrConstAST [ConstValue (BoolConstAST v1), ConstValue (BoolConstAST v2)]             = return $ ConstValue (BoolConstAST (v1 || v2))

--TODO i alle io apply funktioner, tilføj error checking
apply OpenReadConstAST [sys, (ListValue pathList)] = do
    h <- openFile path ReadMode
    a <- return $ ConstValue (BoolConstAST True)
    f <- return (FileValue h 0)
    return $ TupleValue [a, sys', f]
    where
        path = stringFromValuesList pathList
        sys' = advanceSystem sys

apply OpenWriteConstAST [sys, (ListValue pathList)] = do
    h <- openFile path WriteMode
    a <- return $ ConstValue (BoolConstAST True)
    f <- return (FileValue h 0)
    return $ TupleValue [a, sys', f]
    where
        path = stringFromValuesList pathList
        sys' = advanceSystem sys

apply CloseConstAST [sys, (FileValue handle _)] = do
    a <- return $ ConstValue (BoolConstAST True)
    hClose handle
    return $ TupleValue [a, sys']
    where
        sys' = advanceSystem sys

apply DeleteConstAST [sys, (ListValue pathList)] = do
    a <- return $ ConstValue (BoolConstAST True)
    removeFile path    
    return $ TupleValue [a, sys']
    where
        path = stringFromValuesList pathList
        sys' = advanceSystem sys

apply ReadConstAST [file@(FileValue handle _)] = do
    a <- return $ ConstValue (BoolConstAST True)
    c <- hGetChar handle
    return $ TupleValue [a, (ConstValue (CharConstAST c)), f]
    where
        f = advanceFile file

apply WriteConstAST [(ConstValue (CharConstAST ch)), file@(FileValue handle _)] = do
    a <- return $ ConstValue (BoolConstAST True)
    hPutChar handle ch
    return $ TupleValue [a, f]
    where
        f = advanceFile file

apply WriteConstAST [(ConstValue (CharConstAST ch)), file@(PredefinedFileValue "stdout" _)] = do
    a <- return $ ConstValue (BoolConstAST True)
    putChar ch
    return $ TupleValue [a, f]
    where
        f = advanceFile file

apply _ _ = error "error: invalid arguments for apply."
--TODO !! udvid apply for boolske operatorer: hvad med tal osv?
