-- | Things that seem like they could be clients of this library, but
-- are instead included as part of the library.
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
module Debian.Debianize.Goodies
    ( tightDependencyFixup
    , doServer
    , doWebsite
    , doBackups
    , doExecutable
    , describe
    , watchAtom
    , oldClckwrksSiteFlags
    , oldClckwrksServerFlags
    , siteAtoms
    , serverAtoms
    , backupAtoms
    , execAtoms
    ) where

import Control.Category ((.))
import Data.Char (isSpace)
import Data.Lens.Lazy (access, modL)
import Data.List as List (dropWhileEnd, intercalate, intersperse, map)
import Data.Map as Map (insertWith)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Set as Set (insert, singleton, union)
import Data.Text as Text (pack, Text, unlines)
import qualified Debian.Debianize.DebInfo as D
import Debian.Debianize.Monad (CabalInfo, CabalT, DebianT, execCabalM)
import Debian.Debianize.Prelude ((%=), (+++=), (++=), (+=), stripWith)
import qualified Debian.Debianize.CabalInfo as A
import qualified Debian.Debianize.BinaryDebDescription as B
import Debian.Orphans ()
import Debian.Policy (apacheAccessLog, apacheErrorLog, apacheLogDirectory, databaseDirectory, serverAccessLog, serverAppLog)
import Debian.Pretty (ppDisplay, ppDisplay')
import Debian.Relation (BinPkgName(BinPkgName), Relation(Rel))
import Distribution.Package (PackageName(PackageName))
import Distribution.PackageDescription as Cabal (PackageDescription(package, synopsis, description))
import Prelude hiding ((.), init, log, map, unlines, writeFile)
import System.FilePath ((</>))

showCommand :: String -> [String] -> String
showCommand cmd args =
    unwords (map translate (cmd : args))

translate :: String -> String
translate str =
    '"' : foldr escape "\"" str
    where
      escape '"' = showString "\\\""
      escape c = showChar c

-- | Create equals dependencies.  For each pair (A, B), use dpkg-query
-- to find out B's version number, version B.  Then write a rule into
-- P's .substvar that makes P require that that exact version of A,
-- and another that makes P conflict with any older version of A.
tightDependencyFixup :: Monad m => [(BinPkgName, BinPkgName)] -> BinPkgName -> DebianT m ()
tightDependencyFixup [] _ = return ()
tightDependencyFixup pairs p =
    D.rulesFragments +=
          (Text.unlines $
               ([ "binary-fixup/" <> name <> "::"
                , "\techo -n 'haskell:Depends=' >> debian/" <> name <> ".substvars" ] ++
                intersperse ("\techo -n ', ' >> debian/" <> name <> ".substvars") (List.map equals pairs) ++
                [ "\techo '' >> debian/" <> name <> ".substvars"
                , "\techo -n 'haskell:Conflicts=' >> debian/" <> name <> ".substvars" ] ++
                intersperse ("\techo -n ', ' >> debian/" <> name <> ".substvars") (List.map newer pairs) ++
                [ "\techo '' >> debian/" <> name <> ".substvars" ]))
    where
      equals (installed, dependent) = "\tdpkg-query -W -f='" <> display' dependent <> " (=$${Version})' " <>  display' installed <> " >> debian/" <> name <> ".substvars"
      newer  (installed, dependent) = "\tdpkg-query -W -f='" <> display' dependent <> " (>>$${Version})' " <> display' installed <> " >> debian/" <> name <> ".substvars"
      name = display' p
      display' = ppDisplay'

-- | Add a debian binary package to the debianization containing a cabal executable file.
doExecutable :: Monad m => BinPkgName -> D.InstallFile -> CabalT m ()
doExecutable p f = (D.executable . A.debInfo) ++= (p, f)

-- | Add a debian binary package to the debianization containing a cabal executable file set up to be a server.
doServer :: Monad m => BinPkgName -> D.Server -> CabalT m ()
doServer p s = (D.serverInfo . A.debInfo) ++= (p, s)

-- | Add a debian binary package to the debianization containing a cabal executable file set up to be a web site.
doWebsite :: Monad m => BinPkgName -> D.Site -> CabalT m ()
doWebsite p w = (D.website . A.debInfo) ++= (p, w)

-- | Add a debian binary package to the debianization containing a cabal executable file set up to be a backup script.
doBackups :: Monad m => BinPkgName -> String -> CabalT m ()
doBackups bin s =
    do (D.backups . A.debInfo) ++= (bin, s)
       (B.depends . B.relations . D.binaryDebDescription bin . A.debInfo) %= (++ [[Rel (BinPkgName "anacron") Nothing Nothing]])
       -- depends +++= (bin, Rel (BinPkgName "anacron") Nothing Nothing)

describe :: Monad m => CabalT m Text
describe =
    do p <- access A.packageDescription
       return $
          debianDescriptionBase p {- <> "\n" <>
          case typ of
            Just B.Profiling ->
                Text.intercalate "\n"
                        [" .",
                         " This package provides a library for the Haskell programming language, compiled",
                         " for profiling.  See http:///www.haskell.org/ for more information on Haskell."]
            Just B.Development ->
                Text.intercalate "\n"
                        [" .",
                         " This package provides a library for the Haskell programming language.",
                         " See http:///www.haskell.org/ for more information on Haskell."]
            Just B.Documentation ->
                Text.intercalate "\n"
                        [" .",
                         " This package provides the documentation for a library for the Haskell",
                         " programming language.",
                         " See http:///www.haskell.org/ for more information on Haskell." ]
            Just B.Exec ->
                Text.intercalate "\n"
                        [" .",
                         " An executable built from the " <> pack (display (pkgName (Cabal.package p))) <> " package."]
      {-    ServerPackage ->
                Text.intercalate "\n"
                        [" .",
                         " A server built from the " <> pack (display (pkgName pkgId)) <> " package."] -}
            _ {-Utilities-} ->
                Text.intercalate "\n"
                        [" .",
                         " Files associated with the " <> pack (display (pkgName (Cabal.package p))) <> " package."]
            -- x -> error $ "Unexpected library package name suffix: " ++ show x
-}

-- | The Cabal package has one synopsis and one description field
-- for the entire package, while in a Debian package there is a
-- description field (of which the first line is synopsis) in
-- each binary package.  So the cabal description forms the base
-- of the debian description, each of which is amended.
debianDescriptionBase :: PackageDescription -> Text
debianDescriptionBase p =
    pack $ List.intercalate "\n " $ (synop' : desc)
    where
      -- If we have a one line description and no synopsis, use
      -- the description as the synopsis.
      synop' = if null synop && length desc /= 1
               then "WARNING: No synopsis available for package " ++ ppDisplay (package p)
               else synop
      synop :: String
      -- I don't know why (unwords . words) was applied here.  Maybe I'll find out when
      -- this version goes into production.  :-/  Ok, now I know, because sometimes the
      -- short cabal description has more than one line.
      synop = intercalate " " $ map (dropWhileEnd isSpace) $ lines $ Cabal.synopsis p
      desc :: [String]
      desc = List.map addDot . stripWith null $ map (dropWhileEnd isSpace) $ lines $ Cabal.description p
      addDot line = if null line then "." else line

oldClckwrksSiteFlags :: D.Site -> [String]
oldClckwrksSiteFlags x =
    [ -- According to the happstack-server documentation this needs a trailing slash.
      "--base-uri", "http://" ++ D.domain x ++ "/"
    , "--http-port", show D.port]
oldClckwrksServerFlags :: D.Server -> [String]
oldClckwrksServerFlags x =
    [ -- According to the happstack-server documentation this needs a trailing slash.
      "--base-uri", "http://" ++ D.hostname x ++ ":" ++ show (D.port x) ++ "/"
    , "--http-port", show D.port]

watchAtom :: PackageName -> Text
watchAtom (PackageName pkgname) =
    pack $ "version=3\nhttp://hackage.haskell.org/package/" ++ pkgname ++ "/distro-monitor .*-([0-9\\.]+)\\.(?:zip|tgz|tbz|txz|(?:tar\\.(?:gz|bz2|xz)))\n"

siteAtoms :: BinPkgName -> D.Site -> CabalInfo -> CabalInfo
siteAtoms b site =
    execCabalM
      (do (D.atomSet . A.debInfo) %= (Set.insert $ D.InstallDir b "/etc/apache2/sites-available")
          (D.atomSet . A.debInfo) %= (Set.insert $ D.Link b ("/etc/apache2/sites-available/" ++ D.domain site) ("/etc/apache2/sites-enabled/" ++ D.domain site))
          (D.atomSet . A.debInfo) %= (Set.insert $ D.File b ("/etc/apache2/sites-available" </> D.domain site) apacheConfig)
          (D.atomSet . A.debInfo) %= (Set.insert $ D.InstallDir b (apacheLogDirectory b))
          (D.logrotateStanza . A.debInfo) +++=
                              (b, singleton
                                   (Text.unlines $ [ pack (apacheAccessLog b) <> " {"
                                                   , "  copytruncate" -- hslogger doesn't notice when the log is rotated, maybe this will help
                                                   , "  weekly"
                                                   , "  rotate 5"
                                                   , "  compress"
                                                   , "  missingok"
                                                   , "}"]))
          (D.logrotateStanza . A.debInfo) +++=
                              (b, singleton
                                   (Text.unlines $ [ pack (apacheErrorLog b) <> " {"
                                                   , "  copytruncate"
                                                   , "  weekly"
                                                   , "  rotate 5"
                                                   , "  compress"
                                                   , "  missingok"
                                                   , "}" ]))) .
      serverAtoms b (D.server site) True
    where
      -- An apache site configuration file.  This is installed via a line
      -- in debianFiles.
      apacheConfig =
          Text.unlines $
                   [  "<VirtualHost *:80>"
                   , "    ServerAdmin " <> pack (D.serverAdmin site)
                   , "    ServerName www." <> pack (D.domain site)
                   , "    ServerAlias " <> pack (D.domain site)
                   , ""
                   , "    ErrorLog " <> pack (apacheErrorLog b)
                   , "    CustomLog " <> pack (apacheAccessLog b) <> " combined"
                   , ""
                   , "    ProxyRequests Off"
                   , "    AllowEncodedSlashes NoDecode"
                   , ""
                   , "    <Proxy *>"
                   , "                AddDefaultCharset off"
                   , "                Order deny,allow"
                   , "                #Allow from .example.com"
                   , "                Deny from all"
                   , "                #Allow from all"
                   , "    </Proxy>"
                   , ""
                   , "    <Proxy http://127.0.0.1:" <> port' <> "/*>"
                   , "                AddDefaultCharset off"
                   , "                Order deny,allow"
                   , "                #Allow from .example.com"
                   , "                #Deny from all"
                   , "                Allow from all"
                   , "    </Proxy>"
                   , ""
                   , "    SetEnv proxy-sendcl 1"
                   , ""
                   , "    ProxyPass / http://127.0.0.1:" <> port' <> "/ nocanon"
                   , "    ProxyPassReverse / http://127.0.0.1:" <> port' <> "/"
                   , "</VirtualHost>" ]
      port' = pack (show (D.port (D.server site)))

serverAtoms :: BinPkgName -> D.Server -> Bool -> CabalInfo -> CabalInfo
serverAtoms b server' isSite =
    modL (D.postInst . A.debInfo) (insertWith (\ old new -> if old /= new then error ("serverAtoms: " ++ show old ++ " -> " ++ show new) else old) b debianPostinst) .
    modL (D.installInit . A.debInfo) (Map.insertWith (\ old new -> if old /= new then error ("serverAtoms: " ++ show old ++ " -> " ++ show new) else old) b debianInit) .
    serverLogrotate' b .
    execAtoms b exec
    where
      exec = D.installFile server'
      debianInit =
          Text.unlines $
                   [ "#! /bin/sh -e"
                   , ""
                   , ". /lib/lsb/init-functions"
                   , "test -f /etc/default/" <> pack (D.destName exec) <> " && . /etc/default/" <> pack (D.destName exec)
                   , ""
                   , "case \"$1\" in"
                   , "  start)"
                   , "    test -x /usr/bin/" <> pack (D.destName exec) <> " || exit 0"
                   , "    log_begin_msg \"Starting " <> pack (D.destName exec) <> "...\""
                   , "    mkdir -p " <> pack (databaseDirectory b)
                   , "    " <> startCommand
                   , "    log_end_msg $?"
                   , "    ;;"
                   , "  stop)"
                   , "    log_begin_msg \"Stopping " <> pack (D.destName exec) <> "...\""
                   , "    " <> stopCommand
                   , "    log_end_msg $?"
                   , "    ;;"
                   , "  *)"
                   , "    log_success_msg \"Usage: ${0} {start|stop}\""
                   , "    exit 1"
                   , "esac"
                   , ""
                   , "exit 0" ]
      startCommand = pack $ showCommand "start-stop-daemon" (startOptions ++ commonOptions ++ ["--"] ++ D.serverFlags server')
      stopCommand = pack $ showCommand "start-stop-daemon" (stopOptions ++ commonOptions)
      commonOptions = ["--pidfile", "/var/run/" ++ D.destName exec]
      startOptions = ["--start", "-b", "--make-pidfile", "-d", databaseDirectory b, "--exec", "/usr/bin" </> D.destName exec]
      stopOptions = ["--stop", "--oknodo"] ++ if D.retry server' /= "" then ["--retry=" ++ D.retry server' ] else []

      debianPostinst =
          Text.unlines $
                   ([ "#!/bin/sh"
                    , ""
                    , "case \"$1\" in"
                    , "  configure)" ] ++
                    (if isSite
                     then [ "    # Apache won't start if this directory doesn't exist"
                          , "    mkdir -p " <> pack (apacheLogDirectory b)
                          , "    # Restart apache so it sees the new file in /etc/apache2/sites-enabled"
                          , "    /usr/sbin/a2enmod proxy"
                          , "    /usr/sbin/a2enmod proxy_http"
                          , "    service apache2 restart" ]
                     else []) ++
                    [ -- This gets done by the #DEBHELPER# code below.
                      {- "    service " <> pack (show (pPrint b)) <> " start", -}
                      "    ;;"
                    , "esac"
                    , ""
                    , "#DEBHELPER#"
                    , ""
                    , "exit 0" ])

-- | A configuration file for the logrotate facility, installed via a line
-- in debianFiles.
serverLogrotate' :: BinPkgName -> CabalInfo -> CabalInfo
serverLogrotate' b =
    modL (D.logrotateStanza . A.debInfo) (insertWith Set.union b (singleton (Text.unlines $ [ pack (serverAccessLog b) <> " {"
                                 , "  weekly"
                                 , "  rotate 5"
                                 , "  compress"
                                 , "  missingok"
                                 , "}" ]))) .
    modL (D.logrotateStanza . A.debInfo) (insertWith Set.union b (singleton (Text.unlines $ [ pack (serverAppLog b) <> " {"
                                 , "  weekly"
                                 , "  rotate 5"
                                 , "  compress"
                                 , "  missingok"
                                 , "}" ])))

backupAtoms :: BinPkgName -> String -> CabalInfo -> CabalInfo
backupAtoms b name =
    modL (D.postInst . A.debInfo) (insertWith (\ old new -> if old /= new then error $ "backupAtoms: " ++ show old ++ " -> " ++ show new else old) b
                 (Text.unlines $
                  [ "#!/bin/sh"
                  , ""
                  , "case \"$1\" in"
                  , "  configure)"
                  , "    " <> pack ("/etc/cron.hourly" </> name) <> " --initialize"
                  , "    ;;"
                  , "esac" ])) .
    execAtoms b (D.InstallFile { D.execName = name
                               , D.destName = name
                               , D.sourceDir = Nothing
                               , D.destDir = Just "/etc/cron.hourly" })

execAtoms :: BinPkgName -> D.InstallFile -> CabalInfo -> CabalInfo
execAtoms b ifile r =
    modL (D.rulesFragments . A.debInfo) (Set.insert (pack ("build" </> ppDisplay b ++ ":: build-ghc-stamp\n"))) .
    fileAtoms b ifile $
    r

fileAtoms :: BinPkgName -> D.InstallFile -> CabalInfo -> CabalInfo
fileAtoms b installFile' r =
    fileAtoms' b (D.sourceDir installFile') (D.execName installFile') (D.destDir installFile') (D.destName installFile') r

fileAtoms' :: BinPkgName -> Maybe FilePath -> String -> Maybe FilePath -> String -> CabalInfo -> CabalInfo
fileAtoms' b sourceDir' execName' destDir' destName' r =
    case (sourceDir', execName' == destName') of
      (Nothing, True) -> execCabalM ((D.atomSet . A.debInfo) %= (Set.insert $ D.InstallCabalExec b execName' d)) r
      (Just s, True) -> execCabalM ((D.atomSet . A.debInfo) %= (Set.insert $ D.Install b (s </> execName') d)) r
      (Nothing, False) -> execCabalM ((D.atomSet . A.debInfo) %= (Set.insert $ D.InstallCabalExecTo b execName' (d </> destName'))) r
      (Just s, False) -> execCabalM ((D.atomSet . A.debInfo) %= (Set.insert $ D.InstallTo b (s </> execName') (d </> destName'))) r
    where
      d = fromMaybe "usr/bin" destDir'
