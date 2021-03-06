module Lisp.Evaluator where

import Lisp.Types

import Control.Lens
import qualified Data.Map as M
import qualified Data.Set as S
import Safe (lastMay)

data LispState = Form LispValue | Value LispValue |
                 StateList [LispState] Int |
                 Apply LispFunction [LispValue] |
                 InsideClosure LispState Int |
                 Special String [LispState]
               deriving Show

specialForms :: S.Set String
specialForms = S.fromList ["def", "do", "if", "lambda", "quote"]

specialFormCheck :: LispValue -> Maybe (String, [LispValue])
specialFormCheck (LVList ((LVSymbol str):rest)) =
  if str `S.member` specialForms
  then Just (str, rest)
  else Nothing
specialFormCheck _ = Nothing

macroFormCheck :: LispValue -> Lisp Bool
macroFormCheck (LVList ((LVSymbol str):_)) = (S.member str) `fmap` use macros
macroFormCheck _ = return False

(!!?) :: [a] -> Int -> Maybe a
(!!?) list n =
  if n < 0 || n >= (length list)
  then Nothing
  else Just (list !! n)

resolveSymbol :: String -> [LispFrame] -> LispFrame -> Maybe LispValue
resolveSymbol str [] globals' = M.lookup str globals'
resolveSymbol str (frame:rest) globals' =
  case M.lookup str frame of
   Just val -> Just val
   Nothing  -> resolveSymbol str rest globals'

truthy :: LispValue -> Bool
truthy (LVBool False) = False
truthy _              = True

defineSymbol :: String -> LispValue -> Lisp ()
defineSymbol str value =
  globals %= M.insert str value

undefineSymbol :: String -> Lisp ()
undefineSymbol str =
  globals %= M.delete str

mkFrame :: [String] -> [LispValue] -> [(String, LispValue)]
mkFrame names values =
  case lastMay names of
   Just ('&':_) ->
     let n          = length names
         tailValues = drop (n - 1) values
     in zip names $ (take (n - 1) values) ++ [LVList tailValues]
   _            -> zip names values

oneStep :: LispState -> Lisp LispState
oneStep v@(Value _) = return v

oneStep (Apply lispFn lispValues) =
  case lispFn of
    (LFPrimitive _ apply) ->
      case apply lispValues of
        Left  err -> lispFail err
        Right v   -> return $ Value v
    (LFAction _ action) ->
      Value `fmap` action lispValues
    s@(LFClosure name stack' params body) -> do
      let self       = LVFunction s
          --TODO: need to handle TCO properly.
          newFrame   = M.fromList $ mkFrame (name:params) (self:lispValues)
          newStack   = newFrame:stack'
      nFrames <- pushFrames newStack
      return $ InsideClosure (Form body) nFrames

oneStep (InsideClosure value@(Value _) nFrames) = do
  popFrames nFrames
  return $ value

oneStep (InsideClosure state nFrames) = do
  state' <- oneStep state
  -- TODO: if the closure is a tail call, TCO can be done here.
  return $ InsideClosure state' nFrames

oneStep (Form (LVSymbol str)) = do
  theStack   <- use stack
  theGlobals <- use globals
  case resolveSymbol str theStack theGlobals of
   Just value -> return $ Value value
   Nothing    -> lispFail $ LispError (LVString $ "Can't resolve symbol: " ++ str)

-- empty list is "self-evaluating"
oneStep (Form (LVList [])) = return $ Value (LVList [])

oneStep (Form form@(LVList list)) =
  case specialFormCheck form of
    Just (string, rest) ->
      return $ Special string (map Form rest)
    Nothing -> do
      macro <- macroFormCheck form
      if macro
      then error "Illegal state." -- macros should be expanded before we get here.
      else return $ StateList (map Form list) 0

oneStep (Form selfEval) = return $ Value selfEval

oneStep (Special "quote" [(Form val)]) =
  return $ Value val

oneStep (Special "quote" _) =
  failWithString "quote : requires one form"

oneStep (Special "if" [(Value x), thenForm, elseForm]) =
  return $ if truthy x then thenForm else elseForm

oneStep (Special "if" [condState, thenForm, elseForm]) = do
  condState1 <- oneStep condState
  return $ Special "if" [condState1, thenForm, elseForm]

oneStep (Special "if" _) = failWithString  "if : requires 3 forms"

oneStep (Special "def" [(Form (LVSymbol str)), (Value x)]) = do
  defineSymbol str x
  return $ Value $ LVBool True

oneStep (Special "def" [name, defState]) = do
  defState1 <- oneStep defState
  return $ Special "def" [name, defState1]

oneStep (Special "def" _) = failWithString "def : requires a name (symbol) and 1 form"

oneStep (Special "do" []) = return $ Value $ LVBool True

oneStep (Special "do" ((Value x):[])) = return $ Value x

oneStep (Special "do" ((Value _):rest)) = return $ Special "do" rest

oneStep (Special "do" (state:rest)) = do
  state1 <- oneStep state
  return $ Special "do" (state1:rest)

oneStep (Special "lambda" [(Form (LVSymbol name)), (Form params), (Form body)]) = do
  closure <- mkClosure name params body
  return . Value . LVFunction $ closure

oneStep (Special "lambda" [(Form params), (Form body)]) = do
  name <- genStr
  closure <- mkClosure name params body
  return . Value . LVFunction $ closure

oneStep (Special "lambda" _) = failWithString "lambda : requires 2 or 3 forms"

oneStep (Special name _) = error $ "illegal state : unknown special form " ++ name

oneStep (StateList states n) =
  if n >= length states
  then case states of
        -- safe pattern match because n >= len --> all Value
        (Value (LVFunction f)):vals ->
          return $ Apply f (map (\(Value x) -> x) vals)
        _ -> lispFail $ LispError $ LVString "function required in application position"
  else case (states !! n) of
        Value _ -> return $ StateList states (n + 1)
        state'  -> do
          state1 <- oneStep state'
          return $ StateList ((take n states) ++ [state1] ++ (drop (n+1) states)) n

oneStepTillValue :: LispState -> Lisp LispValue
oneStepTillValue ls =
  loop ls
  where loop state' =
          case state' of
            (Value v) -> return v
            _         -> oneStep state' >>= loop

-- eval0 :: Eval without macros (or after macroexpansion).
eval0 :: LispValue -> Lisp LispValue
eval0 lv = oneStepTillValue (Form lv)

evalMacro :: LispValue -> Lisp LispValue
evalMacro lv =
  case lv of
    LVList ((LVSymbol name):rest) -> do
      theStack   <- use stack
      theGlobals <- use globals
      case resolveSymbol name theStack theGlobals of
       Just (LVFunction f) -> oneStepTillValue (Apply f rest)
       _ -> return lv
    _ -> return lv

macroexpand1 :: LispValue -> Lisp LispValue
macroexpand1 lv = do
  macro <- macroFormCheck lv
  if macro
  then evalMacro lv
  else return lv

macroexpand :: LispValue -> Lisp LispValue
macroexpand lv = do
  macro <- macroFormCheck lv
  if macro
  then do
    lv' <- macroexpand1 lv
    macroexpand lv'
  else return lv

-- macroexpands a Lisp form with left-most outer-most macroexpansion.
macroexpandAll :: LispValue -> Lisp LispValue
macroexpandAll lv =
  case lv of
    LVList ((LVSymbol "quote"):_) -> return lv
    _ -> do
      lv1 <- macroexpand lv
      case lv1 of
        LVList subforms -> do
          expandedForms <- mapM macroexpandAll subforms
          return $ LVList expandedForms
        _               -> return lv1

eval :: LispValue -> Lisp LispValue
eval value = do
  -- FIXME : replace macroexpand with macroexpandAll once completed.
  value' <- macroexpandAll value
  eval0 value'
