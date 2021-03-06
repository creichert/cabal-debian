{-# LANGUAGE CPP, OverloadedStrings #-}

import Control.Category ((.))
import Data.Lens.Lazy (getL, modL, access)
import Data.Maybe (fromMaybe)
import Data.Monoid (mempty)
import Data.Set as Set (singleton, insert)
import Data.Text as Text (intercalate)
import Debian.Changes (ChangeLog(..))
import Debian.Debianize -- (debianize, doBackups, doExecutable, doServer, doWebsite, inputChangeLog, inputDebianization, debianDefaultAtoms)
-- import Debian.Debianize.BasicFlags (newFlags)
-- import qualified Debian.Debianize.Atoms as A
-- import Debian.Debianize.Atoms (Atoms, Atom(..), newAtoms, InstallFile(..), Server(..), Site(..), DebInfo, debInfo, atomSet, makeDebInfo)
-- import Debian.Debianize.Monad (execCabalT, evalCabalT, CabalT, liftCabal, execDebianT)
-- import Debian.Debianize.SourceDebDescription (SourceDebDescription)
-- import Debian.Debianize.Output (compareDebianization)
-- import Debian.Debianize.Prelude ((~=), (%=), (+=), (++=), (+++=), (~?=), withCurrentDirectory)
import Debian.Pretty (ppDisplay)
import Debian.Policy (databaseDirectory, PackageArchitectures(All), StandardsVersion(StandardsVersion))
import Debian.Relation (BinPkgName(BinPkgName), Relation(Rel), SrcPkgName(..), VersionReq(SLT))
import Debian.Version (parseDebianVersion)
import Prelude hiding ((.))

-- This looks somewhat like a "real" Debianize.hs file except that (1) it
-- expects to be run from the cabal-debian source directory and (2) it returns
-- the comparison string instead of doing a writeDebianization, and (3) it reads
-- and writes the test-data directories instead of ".".  Also, you wouldn't want
-- to copyFirstLogEntry in real life, this is to make sure old and new match.
main :: IO ()
main =
    do log <- withCurrentDirectory "test-data/artvaluereport2/input" $ newFlags >>= newCabalInfo >>= evalCabalT (liftCabal inputChangeLog >> access (changelog . debInfo))
       new <- withCurrentDirectory "test-data/artvaluereport2/input" $ newFlags >>= newCabalInfo >>= execCabalT (debianize (debianDefaults >> customize log {- >> removeFirstLogEntry -}))
       old <- withCurrentDirectory "test-data/artvaluereport2/output" $ newFlags >>= execDebianT inputDebianization . makeDebInfo
       -- The newest log entry gets modified when the Debianization is
       -- generated, it won't match so drop it for the comparison.
       compareDebianization old ({-copyFirstLogEntry old $ -} getL debInfo new) >>= putStr
    where
      customize :: Maybe ChangeLog -> CabalT IO ()
      customize log =
          do (revision . debInfo) ~= Nothing
             (sourceFormat . debInfo) ~= Just Native3
             (changelog . debInfo) ~?= log
             (atomSet . debInfo) %= (Set.insert $ InstallCabalExec (BinPkgName "appraisalscope") "lookatareport" "usr/bin")
             doExecutable (BinPkgName "appraisalscope") (InstallFile {execName = "appraisalscope", sourceDir = Nothing, destDir = Nothing, destName = "appraisalscope"})
             doServer (BinPkgName "artvaluereport2-development") (theServer (BinPkgName "artvaluereport2-development"))
             doServer (BinPkgName "artvaluereport2-staging") (theServer (BinPkgName "artvaluereport2-staging"))
             doWebsite (BinPkgName "artvaluereport2-production") (theSite (BinPkgName "artvaluereport2-production"))
             doBackups (BinPkgName "artvaluereport2-backups") "artvaluereport2-backups"
             -- This should go into the "real" data directory.  And maybe a different icon for each server?
             -- install (BinPkgName "artvaluereport2-server") ("theme/ArtValueReport_SunsetSpectrum.ico", "usr/share/artvaluereport2-data")
             (description . binaryDebDescription (BinPkgName "artvaluereport2-backups") . debInfo) ~=
                     Just (Text.intercalate "\n"
                                  [ "backup program for the appraisalreportonline.com site"
                                  , "  Install this somewhere other than where the server is running get"
                                  , "  automated backups of the database." ])
             addDep (BinPkgName "artvaluereport2-production") (BinPkgName "apache2")
             addServerData
             addServerDeps
             (description . binaryDebDescription (BinPkgName "appraisalscope") . debInfo) ~= Just "Offline manipulation of appraisal database"
             (buildDependsIndep . control . debInfo) %= (++ [[Rel (BinPkgName "libjs-jquery-ui") (Just (SLT (parseDebianVersion ("1.10" :: String)))) Nothing]])
             (buildDependsIndep . control . debInfo) %= (++ [[Rel (BinPkgName "libjs-jquery") Nothing Nothing]])
             (buildDependsIndep . control . debInfo) %= (++ [[Rel (BinPkgName "libjs-jcrop") Nothing Nothing]])
             (architecture . binaryDebDescription (BinPkgName "artvaluereport2-staging") . debInfo) ~= Just All
             (architecture . binaryDebDescription (BinPkgName "artvaluereport2-production") . debInfo) ~= Just All
             (architecture . binaryDebDescription (BinPkgName "artvaluereport2-development") . debInfo) ~= Just All
             -- utilsPackageNames [BinPkgName "artvaluereport2-server"]
             (sourcePackageName . debInfo) ~= Just (SrcPkgName "haskell-artvaluereport2")
             (standardsVersion . control . debInfo) ~= Just (StandardsVersion 3 9 1 Nothing)
             (homepage . control . debInfo) ~= Just "http://appraisalreportonline.com"
             (compat . debInfo) ~= Just 7

      addServerDeps :: CabalT IO ()
      addServerDeps = mapM_ addDeps (map BinPkgName ["artvaluereport2-development", "artvaluereport2-staging", "artvaluereport2-production"])
      addDeps p = mapM_ (addDep p) (map BinPkgName ["libjpeg-progs", "libjs-jcrop", "libjs-jquery", "libjs-jquery-ui", "netpbm", "texlive-fonts-extra", "texlive-fonts-recommended", "texlive-latex-extra", "texlive-latex-recommended"])
      addDep p dep = (depends . relations . binaryDebDescription p . debInfo) %= (++ [[Rel dep Nothing Nothing]])

      addServerData :: CabalT IO ()
      addServerData = mapM_ addData (map BinPkgName ["artvaluereport2-development", "artvaluereport2-staging", "artvaluereport2-production"])
      addData p =
          do (atomSet . debInfo) %= (Set.insert $ InstallData p "theme/ArtValueReport_SunsetSpectrum.ico" "ArtValueReport_SunsetSpectrum.ico")
             mapM_ (addDataFile p) ["Udon.js", "flexbox.css", "DataTables-1.8.2", "html5sortable", "jGFeed", "searchMag.png",
                                    "Clouds.jpg", "tweaks.css", "verticalTabs.css", "blueprint", "jquery.blockUI", "jquery.tinyscrollbar"]
      addDataFile p path = (atomSet . debInfo) %= (Set.insert $ InstallData p path path)

      theSite :: BinPkgName -> Site
      theSite deb =
          Site { domain = hostname'
               , serverAdmin = "logic@seereason.com"
               , server = theServer deb }
      theServer :: BinPkgName -> Server
      theServer deb =
          Server { hostname =
                       case deb of
                         BinPkgName "artvaluereport2-production" -> hostname'
                         _ -> hostname'
                 , port = portNum deb
                 , headerMessage = "Generated by artvaluereport2/Setup.hs"
                 , retry = "60"
                 , serverFlags =
                    ([ "--http-port", show (portNum deb)
                     , "--base-uri", case deb of
                                       BinPkgName "artvaluereport2-production" -> "http://" ++ hostname' ++ "/"
                                       _ -> "http://seereason.com:" ++ show (portNum deb) ++ "/"
                     , "--top", databaseDirectory deb
                     , "--logs", "/var/log/" ++ ppDisplay deb
                     , "--log-mode", case deb of
                                       BinPkgName "artvaluereport2-production" -> "Production"
                                       _ -> "Development"
                     , "--static", "/usr/share/artvaluereport2-data"
                     , "--no-validate" ] ++
                     (case deb of
                        BinPkgName "artvaluereport2-production" -> [{-"--enable-analytics"-}]
                        _ -> []) {- ++
                     [ "--jquery-path", "/usr/share/javascript/jquery/"
                     , "--jqueryui-path", "/usr/share/javascript/jquery-ui/"
                     , "--jstree-path", jstreePath
                     , "--json2-path",json2Path ] -})
                 , installFile =
                     InstallFile { execName   = "artvaluereport2-server"
                                 , destName   = ppDisplay deb
                                 , sourceDir  = Nothing
                                 , destDir    = Nothing }
                 }
      hostname' = "my.appraisalreportonline.com"
      portNum :: BinPkgName -> Int
      portNum (BinPkgName deb) =
          case deb of
            "artvaluereport2-production"  -> 9027
            "artvaluereport2-staging"     -> 9031
            "artvaluereport2-development" -> 9032
            _ -> error $ "Unexpected package name: " ++ deb

anyrel :: BinPkgName -> Relation
anyrel b = Rel b Nothing Nothing

removeFirstLogEntry :: Monad m => CabalT m ()
removeFirstLogEntry = (changelog . debInfo) %= fmap (\ (ChangeLog (_ : tl)) -> ChangeLog tl)

copyFirstLogEntry :: DebInfo -> DebInfo -> DebInfo
copyFirstLogEntry deb1 deb2 =
    modL changelog (const (Just (ChangeLog (hd1 : tl2)))) deb2
    where
      ChangeLog (hd1 : _) = fromMaybe (error "Missing debian/changelog") (getL changelog deb1)
      ChangeLog (_ : tl2) = fromMaybe (error "Missing debian/changelog") (getL changelog deb2)
