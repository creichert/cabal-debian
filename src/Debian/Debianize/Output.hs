-- | Wrappers around the debianization function to perform various
-- tasks - output, describe, validate a debianization, run an external
-- script to produce a debianization.

{-# LANGUAGE FlexibleInstances, OverloadedStrings, ScopedTypeVariables, StandaloneDeriving, TupleSections, TypeSynonymInstances #-}
{-# OPTIONS -Wall -fno-warn-name-shadowing -fno-warn-orphans #-}

module Debian.Debianize.Output
    ( doDebianizeAction
    , runDebianizeScript
    , writeDebianization
    , describeDebianization
    , compareDebianization
    , validateDebianization
    ) where

import Control.Category ((.))
import Control.Exception as E (throw)
import Control.Monad.State (get)
import Control.Monad.Trans (liftIO, MonadIO)
import Data.Algorithm.Diff.Context (contextDiff)
import Data.Algorithm.Diff.Pretty (prettyDiff)
import Data.Lens.Lazy (getL)
import Data.Map as Map (elems, toList)
import Data.Maybe (fromMaybe)
import Data.Text as Text (split, Text, unpack)
import Debian.Changes (ChangeLog(..), ChangeLogEntry(..))
import Debian.Debianize.BasicInfo (dryRun, validate)
import qualified Debian.Debianize.DebInfo as D
import Debian.Debianize.Files (debianizationFileMap)
import Debian.Debianize.InputDebian (inputDebianization)
import Debian.Debianize.Monad (DebianT, evalDebianT)
import Debian.Debianize.Options (putEnvironmentArgs)
import Debian.Debianize.Prelude (indent, replaceFile, zipMaps)
import Debian.Debianize.BinaryDebDescription as B (canonical, package)
import qualified Debian.Debianize.SourceDebDescription as S
import Debian.Pretty (ppDisplay, ppPrint)
import Prelude hiding ((.), unlines, writeFile)
import System.Directory (createDirectoryIfMissing, doesFileExist, getPermissions, Permissions(executable), setPermissions)
import System.Exit (ExitCode(ExitSuccess))
import System.FilePath ((</>), takeDirectory)
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode, showCommandForUser)
import Text.PrettyPrint.HughesPJClass (text)

-- | Run the script in @debian/Debianize.hs@ with the given command
-- line arguments.  Returns @True@ if the script exists and succeeds.
-- In this case it may be assumed that a debianization was created (or
-- updated) in the debian subdirectory of the current directory.  In
-- this way we can include a script in a package to produce a
-- customized debianization more sophisticated than the one that would
-- be produced by the cabal-debian executable.  An example is included
-- in the debian subdirectory of this library.
runDebianizeScript :: [String] -> IO Bool
runDebianizeScript args =
    -- getEnv "HOME" >>= \ home ->
    doesFileExist "debian/Debianize.hs" >>= \ exists ->
    case exists of
      False -> return False
      True -> do
        let args' = ["debian/Debianize.hs"] ++ args
        putEnvironmentArgs args
        hPutStrLn stderr (showCommandForUser "runhaskell" args')
        result <- readProcessWithExitCode "runhaskell" args' ""
        case result of
          (ExitSuccess, _, _) -> return True
          (code, out, err) -> error ("runDebianizeScript: " ++ showCommandForUser "runhaskell" args' ++ " -> " ++ show code ++
                                     "\n stdout: " ++ show out ++"\n stderr: " ++ show err)

-- | Depending on the options in @atoms@, either validate, describe,
-- or write the generated debianization.
doDebianizeAction :: (MonadIO m, Functor m) => DebianT m ()
doDebianizeAction =
    do new <- get
       case () of
         _ | getL (validate . D.flags) new ->
               do inputDebianization
                  old <- get
                  return $ validateDebianization old new
         _ | getL (dryRun . D.flags) new ->
               do inputDebianization
                  old <- get
                  diff <- liftIO $ compareDebianization old new
                  liftIO $ putStr ("Debianization (dry run):\n" ++ diff)
         _ -> writeDebianization

-- | Write the files of the debianization @d@ to ./debian
writeDebianization :: (MonadIO m, Functor m) => DebianT m ()
writeDebianization =
    do files <- debianizationFileMap
       liftIO $ mapM_ (uncurry doFile) (Map.toList files)
       liftIO $ getPermissions "debian/rules" >>= setPermissions "debian/rules" . (\ p -> p {executable = True})
    where
      doFile path text =
          do createDirectoryIfMissing True (takeDirectory path)
             replaceFile path (unpack text)

-- | Return a string describing the debianization - a list of file
-- names and their contents in a somewhat human readable format.
describeDebianization :: (MonadIO m, Functor m) => DebianT m String
describeDebianization =
    debianizationFileMap >>= return . concatMap (\ (path, text) -> path ++ ": " ++ indent " > " (unpack text)) . Map.toList

-- | Compare the old and new debianizations, returning a string
-- describing the differences.
compareDebianization :: D.DebInfo -> D.DebInfo -> IO String
compareDebianization old new =
    do oldFiles <- evalDebianT debianizationFileMap (canonical old)
       newFiles <- evalDebianT debianizationFileMap (canonical new)
       return $ concat $ Map.elems $ zipMaps doFile oldFiles newFiles
    where
      doFile :: FilePath -> Maybe Text -> Maybe Text -> Maybe String
      doFile path (Just _) Nothing = Just (path ++ ": Deleted\n")
      doFile path Nothing (Just n) = Just (path ++ ": Created\n" ++ indent " | " (unpack n))
      doFile path (Just o) (Just n) =
          if o == n
          then Nothing -- Just (path ++ ": Unchanged\n")
          else Just (show (prettyDiff (text ("old" </> path)) (text ("new" </> path)) (text . unpack) (contextDiff 2 (split (== '\n') o) (split (== '\n') n))))
      doFile _path Nothing Nothing = error "Internal error in zipMaps"

-- | Make sure the new debianization matches the existing
-- debianization in several ways - specifically, version number, and
-- the names of the source and binary packages.  Some debian packages
-- come with a skeleton debianization that needs to be filled in, this
-- can be used to make sure the debianization we produce is usable.
validateDebianization :: D.DebInfo -> D.DebInfo -> ()
validateDebianization old new =
    case () of
      _ | oldVersion /= newVersion -> throw (userError ("Version mismatch, expected " ++ ppDisplay oldVersion ++ ", found " ++ ppDisplay newVersion))
        | oldSource /= newSource -> throw (userError ("Source mismatch, expected " ++ ppDisplay oldSource ++ ", found " ++ ppDisplay newSource))
        | oldPackages /= newPackages -> throw (userError ("Package mismatch, expected " ++ show (map ppPrint oldPackages) ++ ", found " ++ show (map ppPrint newPackages)))
        | True -> ()
    where
      oldVersion = logVersion (head (unChangeLog (fromMaybe (error "Missing changelog") (getL D.changelog old))))
      newVersion = logVersion (head (unChangeLog (fromMaybe (error "Missing changelog") (getL D.changelog new))))
      oldSource = getL (S.source . D.control) old
      newSource = getL (S.source . D.control) new
      oldPackages = map (getL B.package) $ getL (S.binaryPackages . D.control) old
      newPackages = map (getL B.package) $ getL (S.binaryPackages . D.control) new
      unChangeLog :: ChangeLog -> [ChangeLogEntry]
      unChangeLog (ChangeLog x) = x
