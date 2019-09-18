{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE BangPatterns #-}

module Language.Haskell.Liquid.Synthesize.Monad where


import           Language.Haskell.Liquid.Types hiding (SVar)
import           Language.Haskell.Liquid.Constraint.Types
import           Language.Haskell.Liquid.Constraint.Generate 
import           Language.Haskell.Liquid.Constraint.Env 
import qualified Language.Haskell.Liquid.Types.RefType as R
import           Language.Haskell.Liquid.GHC.Misc (showPpr)
import           Language.Haskell.Liquid.Synthesize.Termination
import           Language.Haskell.Liquid.Synthesize.GHC
import           Language.Haskell.Liquid.Synthesize.Misc
import           Language.Haskell.Liquid.Constraint.Fresh (trueTy)
import qualified Language.Fixpoint.Smt.Interface as SMT
import           Language.Fixpoint.Types hiding (SEnv, SVar, Error)
import qualified Language.Fixpoint.Types        as F 
import qualified Language.Fixpoint.Types.Config as F

import CoreSyn (CoreExpr)
import qualified CoreSyn as GHC
import Var 
import TyCon
import DataCon
import TysWiredIn
import qualified TyCoRep as GHC 
import           Text.PrettyPrint.HughesPJ ((<+>), text, char, Doc, vcat, ($+$))

import           Control.Monad.State.Lazy
import qualified Data.HashMap.Strict as M 
import           Data.Default 
import           Data.Graph (SCC(..))
import qualified Data.Text as T
import           Data.Maybe
import           Debug.Trace 
import           Language.Haskell.Liquid.GHC.TypeRep
import           Language.Haskell.Liquid.Synthesis
import           Data.List 
import qualified Data.Map as Map 
import           Data.List.Extra


maxDepth :: Int 
maxDepth = 1 

-------------------------------------------------------------------------------
-- | Synthesis Monad ----------------------------------------------------------
-------------------------------------------------------------------------------

-- The state keeps a unique index for generation of fresh variables 
-- and the environment of variables to types that is expanded on lambda terms
type SSEnv = M.HashMap Symbol (SpecType, Var)
type SSDecrTerm = [(Var, [Var])]

-- Initialized with basic type expressions
-- e.g. b  --- x_s3
--     [b] --- [], x_s0, x_s4
type ExprMemory = [(Type, CoreExpr, Int)]
data SState 
  = SState { rEnv       :: REnv -- Local Binders Generated during Synthesis 
           , ssEnv      :: SSEnv -- Local Binders Generated during Synthesis 
           , ssIdx      :: Int
           , ssDecrTerm :: SSDecrTerm 
           , sContext   :: SMT.Context
           , sCGI       :: CGInfo
           , sCGEnv     :: CGEnv
           , sFCfg      :: F.Config
           , sDepth     :: Int
           , sExprMem   :: ExprMemory 
           , sAppDepth  :: Int
           }
type SM = StateT SState IO

maxAppDepth :: Int 
maxAppDepth = 4

locally :: SM a -> SM a 
locally act = do 
  st <- get 
  r <- act 
  modify $ \s -> s{sCGEnv = sCGEnv st, sCGI = sCGI st}
  return r 


evalSM :: SM a -> FilePath -> F.Config -> CGInfo -> CGEnv -> REnv -> SSEnv -> IO a 
evalSM act tgt fcfg cgi cgenv renv env = do 
  ctx <- SMT.makeContext fcfg tgt  
  r <- evalStateT act (SState renv env 0 [] ctx cgi cgenv fcfg 0 exprMem0 0)
  SMT.cleanupContext ctx 
  return r 
  where exprMem0 = initExprMem env

getSEnv :: SM SSEnv
getSEnv = ssEnv <$> get 

type LEnv = M.HashMap Symbol SpecType -- | Local env.

getLocalEnv :: SM LEnv
getLocalEnv = (reLocal . rEnv) <$> get

getSDecrTerms :: SM SSDecrTerm 
getSDecrTerms = ssDecrTerm <$> get

addsEnv :: [(Var, SpecType)] -> SM () 
addsEnv xts = 
  mapM_ (\(x,t) -> modify (\s -> s {ssEnv = M.insert (symbol x) (t,x) (ssEnv s)})) xts  

addsEmem :: [(Var, SpecType)] -> SM () 
addsEmem xts = do 
  curAppDepth <- sAppDepth <$> get
  trace (" [ addsEmem ] " ++ show curAppDepth) $ mapM_ (\(x,t) -> modify (\s -> s {sExprMem = (toType t, GHC.Var x, curAppDepth) : (sExprMem s)})) xts  
  

addEnv :: Var -> SpecType -> SM ()
addEnv x t = do 
  liftCG0 (\γ -> γ += ("arg", symbol x, t))
  modify (\s -> s {ssEnv = M.insert (symbol x) (t,x) (ssEnv s)}) 

addEmem :: Var -> SpecType -> SM ()
addEmem x t = do 
  curAppDepth <- sAppDepth <$> get
  liftCG0 (\γ -> γ += ("arg", symbol x, t))
  trace (" [ addElem ] " ++ show curAppDepth) $ modify (\s -> s {sExprMem = (toType t, GHC.Var x, curAppDepth) : (sExprMem s)})



addDecrTerm :: Var -> [Var] -> SM ()
addDecrTerm x vars = do
  decrTerms <- getSDecrTerms 
  case lookup x decrTerms of 
    Nothing    -> modify (\s -> s { ssDecrTerm = (x, vars) : (ssDecrTerm s) } )
    Just vars' -> do
      let ix = elemIndex (x, vars') decrTerms
      case ix of 
        Nothing  -> error $ "[addDecrTerm] It should have been there " ++ show x 
        Just ix' -> 
          let (left, right) = splitAt ix' decrTerms 
          in  modify (\s -> s { ssDecrTerm =  left ++ [(x, vars ++ vars')] ++ right } )


liftCG0 :: (CGEnv -> CG CGEnv) -> SM () 
liftCG0 act = do 
  st <- get 
  let (cgenv, cgi) = runState (act (sCGEnv st)) (sCGI st) 
  modify (\s -> s {sCGI = cgi, sCGEnv = cgenv}) 



liftCG :: CG a -> SM a 
liftCG act = do 
  st <- get 
  let (x, cgi) = runState act (sCGI st) 
  modify (\s -> s {sCGI = cgi})
  return x 


freshVar :: SpecType -> SM Var
freshVar t = (\i -> mkVar (Just "x") i (toType t)) <$> incrSM

withIncrDepth :: Monoid a => SM a -> SM a
withIncrDepth m = do 
    s <- get 
    let d = sDepth s

    if d + 1 > maxDepth then
        return mempty

    else do
        put s{sDepth = d + 1}

        r <- m

        modify $ \s -> s{sDepth = d}

        return r


incrSM :: SM Int 
incrSM = do s <- get 
            put s{ssIdx = ssIdx s + 1}
            return (ssIdx s)

symbolExpr :: Type -> F.Symbol -> SM CoreExpr 
symbolExpr τ x = incrSM >>= (\i -> return $ F.notracepp ("symExpr for " ++ F.showpp x) $  GHC.Var $ mkVar (Just $ F.symbolString x) i τ)

-- to be removed
-- initExprMemory :: Type -> SSEnv -> ExprMemory
-- initExprMemory τ ssenv = 
--   let senv    = M.toList ssenv 
--       senv'   = filter (\(_, (t, _)) -> isBasic (toType t)) senv 
--       senv''  = map (\(_, (t, v)) -> (toType t, GHC.Var v)) senv' 
--       senv''' = map (\(t, e) -> (instantiateType τ t, e)) senv''
--   in  senv'''

initExprMem :: SSEnv -> ExprMemory
initExprMem ssenv = 
  let senv  = M.toList ssenv 
      -- Init `ExprMemory` with 0
      senv'  = map (\(_, (t, v)) -> (toType t, GHC.Var v, 0)) senv
  in  senv'

-- Misc
showEmem  emem = show $ showEmem' emem
showEmem' emem = map (\(t, e, i) -> (showTy t, show e, show i)) emem
  