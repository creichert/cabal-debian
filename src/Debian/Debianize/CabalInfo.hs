-- | This module holds a long list of lenses that access the Atoms
-- record, the record that holds the input data from which the
-- debianization is to be constructed.
{-# LANGUAGE CPP, DeriveDataTypeable, OverloadedStrings, TemplateHaskell #-}
{-# OPTIONS_GHC -Wall #-}
module Debian.Debianize.CabalInfo
    ( -- * Types
      CabalInfo
    , PackageInfo(PackageInfo, cabalName, devDeb, docDeb, profDeb)
      -- * Lenses
    , packageDescription
    , debInfo
    , debianNameMap
    , epochMap
    , packageInfo
      -- * Builder
    , newCabalInfo
    ) where

import Control.Category ((.))
import Control.Monad (unless)
import Control.Monad.State (execStateT)
import Control.Monad.Trans (liftIO)
import Data.Generics (Data, Typeable)
import Data.Lens.Lazy (access)
import Data.Lens.Template (nameMakeLens)
import Data.List as List (init, null)
import Data.Map as Map (Map)
import Data.Monoid (Monoid(..))
import Data.Text as Text (null, pack, strip)
import Debian.Debianize.BasicInfo (Flags)
import Debian.Debianize.DebInfo as D (control, copyright, DebInfo, makeDebInfo, noTestSuite, rulesSettings)
import Debian.Debianize.BinaryDebDescription (Canonical(canonical))
import Debian.Debianize.CopyrightDescription (defaultCopyrightDescription)
import Debian.Debianize.InputCabal (inputCabalization)
import Debian.Debianize.Prelude ((~=), (%=))
import Debian.Debianize.SourceDebDescription as S (homepage)
import Debian.Debianize.VersionSplits (VersionSplits)
import Debian.Orphans ()
import Debian.Relation (BinPkgName)
import Debian.Version (DebianVersion)
import Distribution.Package (PackageName)
import Distribution.PackageDescription as Cabal (PackageDescription(homepage, testSuites))
import Prelude hiding ((.), init, init, log, log, null)

-- This enormous record is a mistake - instead it should be an Atom
-- type with lots of constructors, and the Atoms type is a set of
-- these.  Then we can cruise through the atom set converting the
-- elements into other simpler elements until they elements are all
-- simple enough to convert directly into a debianization.  At the
-- moment I really need this for the Install atoms, so I will try to
-- convert just that portion of the type to this new scheme.

-- | Bits and pieces of information about the mapping from cabal package
-- names and versions to debian package names and versions.  In essence,
-- an 'Atoms' value represents a package's debianization.  The lenses in
-- this module are used to get and set the values hidden in this Atoms
-- value.  Many of the values should be left alone to be set when the
-- debianization is finalized.
data CabalInfo
    = CabalInfo
      { packageDescription_ :: PackageDescription
      -- ^ The result of reading a cabal configuration file.
      , debInfo_ :: DebInfo
      -- ^ Information required to represent a non-cabal debianization.
      , debianNameMap_ :: Map PackageName VersionSplits
      -- ^ Mapping from cabal package name and version to debian source
      -- package name.  This allows different ranges of cabal versions to
      -- map to different debian source package names.
      , epochMap_ :: Map PackageName Int
      -- ^ Specify epoch numbers for the debian package generated from a
      -- cabal package.  Example: @EpochMapping (PackageName "HTTP") 1@.
      , packageInfo_ :: Map PackageName PackageInfo
      -- ^ Supply some info about a cabal package.
      } deriving (Show, Data, Typeable)

data PackageInfo = PackageInfo { cabalName :: PackageName
                               , devDeb :: Maybe (BinPkgName, DebianVersion)
                               , profDeb :: Maybe (BinPkgName, DebianVersion)
                               , docDeb :: Maybe (BinPkgName, DebianVersion) } deriving (Eq, Ord, Show, Data, Typeable)

$(let f s = case s of
              (_ : _) | last s == '_' -> Just (init s)
              _ -> Nothing in
  nameMakeLens ''CabalInfo f)

instance Canonical CabalInfo where
    canonical x = x {debInfo_ = canonical (debInfo_ x)}

-- | Given the 'Flags' value read the cabalization and build a new
-- 'CabalInfo' record.
newCabalInfo :: Flags -> IO CabalInfo
newCabalInfo flags' = do
  pkgDesc <- inputCabalization flags'
  copyrt <- liftIO $ defaultCopyrightDescription pkgDesc
  execStateT
    (do (copyright . debInfo) ~= Just copyrt
        (S.homepage . control . debInfo) ~= case strip (pack (Cabal.homepage pkgDesc)) of
                                              x | Text.null x -> Nothing
                                              x -> Just x
        noTests <- access (noTestSuite . debInfo)
        unless (List.null (Cabal.testSuites pkgDesc) || noTests)
               (do (rulesSettings . debInfo) %= (++ ["DEB_ENABLE_TESTS = yes"])
                   -- ...
               ))
    (makeCabalInfo flags' pkgDesc)

makeCabalInfo :: Flags -> PackageDescription -> CabalInfo
makeCabalInfo fs pkgDesc =
    CabalInfo
      { packageDescription_ = pkgDesc
      , epochMap_ = mempty
      , packageInfo_ = mempty
      , debianNameMap_ = mempty
      , debInfo_ = makeDebInfo fs
      }
