{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -Wall #-}
module Debian.Debianize.Monad
    ( CabalInfo
    , CabalT
    , runCabalT
    , evalCabalT
    , execCabalT
    , CabalM
    , runCabalM
    , evalCabalM
    , execCabalM

    -- * modify cabal to debian package version map
    -- , mapCabal
    -- , splitCabal

    , DebianT
    , evalDebianT
    , execDebianT
    , liftCabal
    ) where

import Control.Monad.State (evalState, evalStateT, execState, execStateT, runState, State, StateT(runStateT))
import Data.Lens.Lazy (focus)
import Debian.Debianize.DebInfo (DebInfo)
import Debian.Debianize.CabalInfo (CabalInfo, debInfo)
import Debian.Orphans ()
import Prelude hiding (init, log, unlines)

type CabalT m = StateT CabalInfo m -- Better name - CabalT?
type CabalM = State CabalInfo

execCabalT :: Monad m => CabalT m a -> CabalInfo -> m CabalInfo
execCabalT action atoms = execStateT action atoms

evalCabalT :: Monad m => CabalT m a -> CabalInfo -> m a
evalCabalT action atoms = evalStateT action atoms

runCabalT :: Monad m => CabalT m a -> CabalInfo -> m (a, CabalInfo)
runCabalT action atoms = runStateT action atoms

execCabalM :: CabalM a -> CabalInfo -> CabalInfo
execCabalM action atoms = execState action atoms

evalCabalM :: CabalM a -> CabalInfo -> a
evalCabalM action atoms = evalState action atoms

runCabalM :: CabalM a -> CabalInfo -> (a, CabalInfo)
runCabalM action atoms = runState action atoms

type DebianT m = StateT DebInfo m

evalDebianT :: Monad m => DebianT m a -> DebInfo -> m a
evalDebianT = evalStateT

execDebianT :: Monad m => DebianT m () -> DebInfo -> m DebInfo
execDebianT = execStateT

liftCabal :: Monad m => StateT DebInfo m a -> StateT CabalInfo m a
liftCabal = focus debInfo
