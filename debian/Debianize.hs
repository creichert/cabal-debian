-- To run the test: runhaskell -isrc -DMIN_VERSION_Cabal\(a,b,c\)=1 debian/Debianize.hs
--
-- This doesn't actually modify the debianization, it just sees
-- whether the debianization it would have generated matches the one
-- that is already in debian/.  If not it either means a bug was
-- introduced, or the changes are good and need to be checked in.
--
-- Be sure to run it with the local-debian flag turned off!

import Control.Category ((.))
import Control.Exception (throw)
import Control.Monad.State (get)
import Data.Default (def)
import Data.Lens.Lazy (getL, access)
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Monoid (mempty)
import Data.Set as Set (singleton, insert)
import Data.Text as Text (Text, pack)
import Debian.Changes (ChangeLog(ChangeLog))
import Debian.Debianize
{-
import Debian.Debianize (inputChangeLog, inputDebianization)
import Debian.Debianize.Details (debianDefaultAtoms)
import Debian.Debianize.Finalize (debianize)
import Debian.Debianize.InputCabalPackageDescription (newFlags)
import Debian.Debianize.Types as T
    (changelog, compat, conflicts, control, depends, debianDescription, homepage, packageDescription,
     installCabalExec, sourceFormat, standardsVersion, utilsPackageNameBase, copyright, xDescription)
import Debian.Debianize.Types.Atoms as T (Atoms, newAtoms, DebInfo, debInfo, makeDebInfo, atomSet, Atom(..))
import Debian.Debianize.Monad (Atoms, CabalT, execCabalT, evalCabalT, execDebianT, liftCabal)
import Debian.Debianize.Output (compareDebianization)
import Debian.Debianize.Prelude ((~=), (~?=), (%=), (+=), (++=))
import Debian.Debianize.Types.CopyrightDescription (CopyrightDescription(..), FilesOrLicenseDescription(..), newCopyrightDescription)
import Debian.Debianize.Types.SourceDebDescription (SourceDebDescription)
import Debian.Policy (SourceFormat(Native3), StandardsVersion(StandardsVersion), License(OtherLicense))
-}
import Debian.Relation (BinPkgName(BinPkgName), Relation(Rel), VersionReq(SLT, GRE), Relations, parseRelations)
import Debian.Version (parseDebianVersion)
import Distribution.Compiler(CompilerFlavor(GHC))
import Prelude hiding (log, (.))
import System.Directory (copyFile)

main :: IO ()
main =
    do -- Copy the changelog into the top directory so that hackage
       -- will see it.
       copyFile "debian/changelog" "changelog"
       -- This is both a debianization script and a unit test - it
       -- makes sure the debianization generated matches the one
       -- checked into version control.
       log <- newFlags >>= newCabalInfo >>= evalCabalT (liftCabal inputChangeLog >> access (changelog . debInfo))
       old <- newFlags >>= execDebianT inputDebianization . makeDebInfo
       new <- newFlags >>= newCabalInfo >>= execCabalT (debianize (do debianDefaults
                                                                      (changelog . debInfo) ~?= log
                                                                      customize
                                                                      copyFirstLogEntry old))
       diff <- compareDebianization old (getL debInfo new)
       case diff of
         "" -> return ()
         s -> error $ "Debianization mismatch:\n" ++ s
       -- This would overwrite the existing debianization rather than
       -- just make sure it matches:
       -- writeDebianization "." new
    where
      customize :: Monad m => CabalT m ()
      customize =
          do (sourceFormat . debInfo) ~= Just Native3
             (standardsVersion . control . debInfo) ~= Just (StandardsVersion 3 9 3 Nothing)
             (compat . debInfo) ~= Just 9
             (utilsPackageNameBase . debInfo) ~= Just "cabal-debian"
             (copyright . debInfo) %= (Just . copyrightFn . fromMaybe def)
             (conflicts . relations . binaryDebDescription (BinPkgName "cabal-debian") . debInfo) %= (++ (rels "haskell-debian-utils (<< 3.59)"))
             (depends . relations . binaryDebDescription (BinPkgName "cabal-debian") . debInfo) %= (++ (rels "apt-file, debian-policy, debhelper, haskell-devscripts (>= 0.8.19)"))
             (depends . relations . binaryDebDescription (BinPkgName "libghc-cabal-debian-dev") . debInfo) %= (++ (rels "debian-policy"))
             (atomSet . debInfo) %= (Set.insert $ InstallCabalExec (BinPkgName "cabal-debian-tests") "cabal-debian-tests" "/usr/bin")
             (atomSet . debInfo) %= (Set.insert $ InstallCabalExec (BinPkgName "cabal-debian") "cabal-debian" "/usr/bin")
             (utilsPackageNameBase . debInfo) ~= Just "cabal-debian"
             -- extraDevDeps (BinPkgName "debian-policy")
             (homepage . control . debInfo) ~= Just (pack "https://github.com/ddssff/cabal-debian")

rels :: String -> Relations
rels = either (throw . userError . show) id . parseRelations

-- | Demonstrates the structure of the new copyright type.
copyrightFn :: CopyrightDescription -> CopyrightDescription
copyrightFn =
    const $ def     { _filesAndLicenses =       [FilesDescription { _filesPattern = "*"
                                                                  , _filesCopyright = pack (unlines [ "Copyright (c) 2007, David Fox"
                                                                                                    , "Copyright (c) 2007, Jeremy Shaw" ])
                                                                  , _filesLicense = OtherLicense "Proprietary"
                                                                  , _filesComment = Just $ pack $ unlines
                                                                                    [ "All rights reserved."
                                                                                    , ""
                                                                                    , "The packageing was adjusted to Debian conventions by Joachim Breitner"
                                                                                    , "<nomeata@debian.org> on Sat, 01 May 2010 21:16:18 +0200, and is licenced under"
                                                                                    , "the same terms as the package itself.."
                                                                                    , ""
                                                                                    , "Redistribution and use in source and binary forms, with or without"
                                                                                    , "modification, are permitted provided that the following conditions are"
                                                                                    , "met:"
                                                                                    , ""
                                                                                    , "    * Redistributions of source code must retain the above copyright"
                                                                                    , "      notice, this list of conditions and the following disclaimer."
                                                                                    , ""
                                                                                    , "    * Redistributions in binary form must reproduce the above"
                                                                                    , "      copyright notice, this list of conditions and the following"
                                                                                    , "      disclaimer in the documentation and/or other materials provided"
                                                                                    , "      with the distribution."
                                                                                    , ""
                                                                                    , "    * The names of contributors may not be used to endorse or promote"
                                                                                    , "      products derived from this software without specific prior"
                                                                                    , "      written permission."
                                                                                    , ""
                                                                                    , "THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS"
                                                                                    , "\"AS IS\" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT"
                                                                                    , "LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR"
                                                                                    , "A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT"
                                                                                    , "OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,"
                                                                                    , "SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT"
                                                                                    , "LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,"
                                                                                    , "DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY"
                                                                                    , "THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT"
                                                                                    , "(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE"
                                                                                    , "OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE." ] }]
                    , _summaryComment = Just $ pack "This package is not part of the Debian GNU/Linux distribution." }

-- | This copies the first log entry of deb1 into deb2.  Because the
-- debianization process updates that log entry, we need to undo that
-- update in order to get a clean comparison.
copyFirstLogEntry :: Monad m => DebInfo -> CabalT m ()
copyFirstLogEntry src =
    do dst <- get
       let Just (ChangeLog (hd1 : _)) = getL changelog src
           Just (ChangeLog (_ : tl2)) = getL (changelog . debInfo) dst
       (changelog . debInfo) ~= Just (ChangeLog (hd1 : tl2))
{-
    get >>= \ dst -> 
copyFirstLogEntry :: Atoms -> Atoms -> Atoms
copyFirstLogEntry deb1 deb2 =
    modL changelog (const (Just (ChangeLog (hd1 : tl2)))) deb2
    where
      ChangeLog (hd1 : _) = fromMaybe (error "Missing debian/changelog") (getL changelog deb1)
      ChangeLog (_ : tl2) = fromMaybe (error "Missing debian/changelog") (getL changelog deb2)
-}
