{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Main where

import Appraisal.AcidCache
import Appraisal.FileCache
import Appraisal.FileCacheT
import Appraisal.FileError
import Control.Monad.Catch (MonadCatch)
import Control.Monad.Except (ExceptT, MonadError, runExceptT)
import Control.Monad.Reader (ask, ReaderT)
import Control.Monad.RWS
import Control.Monad.Trans (lift)
import Data.Acid (AcidState)
import Data.ByteString (ByteString, pack)
import Data.Char (ord)
import Data.Typeable (Proxy(Proxy))
import Data.Map (fromList)
import qualified Exif (tests)
import qualified LaTeX
import System.Exit (exitWith, ExitCode(ExitSuccess, ExitFailure))
import System.FilePath.Extra3 (removeRecursiveSafely)
import Test.HUnit (assertEqual, Test(TestList, TestCase), runTestTT, Counts(errors, failures))

main =
    do counts <- runTestTT Main.tests
       putStrLn ("Test results: " ++ show counts)
       case (errors counts + failures counts) of
         0 -> exitWith ExitSuccess
         _ -> exitWith (ExitFailure 1)
       putStrLn (unlines ["Other Things that should be tested:",
                          "FileCache: fileFromPath, fileFromCmd, fileFromCmdViaTemp, fileFromURI, fileURI, fileCacheURI",
                          "ImageCache: getFileType, uprightImage, scaleImage, editImage"
                         ])

tests :: Test
tests = TestList [Exif.tests, LaTeX.tests, acid1, file1]

-- The directory that holds the acid state event logs and checkpoints.
acidDir = "Tests/acid"
fileAcidDir = "Tests/fileacid"
fileCacheDir' = FileCacheTop "Tests/filecache"

-- The oldest file in /usr/share/doc
oldfile :: FilePath
oldfile = "/usr/share/doc/cron/THANKS"

type AcidM m = RWST (AcidState (CacheMap String String FileError)) () () m
type FileM m = FileCacheT (AcidState (CacheMap String String FileError)) () () m

-- | A simple cache - its builder simply reverses the key.  The
-- IO monad is required to query and update the acid state database.
instance (MonadIO m, MonadCatch m, MonadError FileError m) => HasCache String String FileError (AcidM m) where
    askCacheAcid = ask
    buildCacheValue = return . Cached . reverse

instance HasCache String String FileError m => HasCache String String FileError (ReaderT FilePath m) where
    askCacheAcid = lift askCacheAcid
    buildCacheValue = lift . buildCacheValue

runMonadCacheT ::
    Monad m
    => RWST (AcidState (CacheMap key val err)) () s m a
    -> s
    -> AcidState (CacheMap key val err)
    -> m a
runMonadCacheT action s acid = fst <$> evalRWST action acid s

acid1 :: Test
acid1 = TestCase $ do
          removeRecursiveSafely acidDir
          (value1 :: Either FileError (Maybe (CacheValue FileError String))) <- runExceptT $ withCache acidDir (runMonadCacheT (cacheLook "Hello, world!" :: AcidM (ExceptT FileError IO) (Maybe (CacheValue FileError String))) ())
          (value2 :: Either FileError (CacheMap String String FileError)) <- runExceptT $ withCache acidDir (runMonadCacheT (cacheMap :: AcidM (ExceptT FileError IO) (CacheMap String String FileError)) ())
          value3 <- runExceptT $ withCache acidDir (runMonadCacheT (cacheInsert "Hello, world!" :: AcidM (ExceptT FileError IO) (CacheValue FileError String)) ())
          value4 <- runExceptT $ withCache acidDir (runMonadCacheT (cacheLook "Hello, world!" :: AcidM (ExceptT FileError IO) (Maybe (CacheValue FileError String))) ())
          value5 <- runExceptT $ withCache acidDir (runMonadCacheT (cacheMap :: AcidM (ExceptT FileError IO) (CacheMap String String FileError)) ())
          assertEqual "acid1"
                          (Right Nothing,
                           Right (CacheMap (fromList [])),
                           Right (Cached "!dlrow ,olleH"),
                           Right (Just (Cached "!dlrow ,olleH")),
                           Right (CacheMap (fromList [("Hello, world!",Cached "!dlrow ,olleH")])))
                          (value1, value2, value3, value4, value5)

-- runEitherT :: EitherT e m a -> m (Either e a)

file1 :: Test
file1 = TestCase $ do
          removeRecursiveSafely fileAcidDir
          Right value1 <- runExceptT (withCache fileAcidDir f) :: IO (Either FileError (File, ByteString))
          assertEqual "file1" expected value1
    where
      f :: AcidState (CacheMap String String FileError) -> ExceptT FileError IO (File, ByteString)
      f fileAcidState =
          runFileCacheT Proxy () fileAcidState fileCacheDir'
            (fileFromPath return (pure "") oldfile :: FileCacheT st () () (ExceptT FileError IO) (File, ByteString))
             {-liftIO (try (fileFromPath return (pure "") oldfile) >>= either (throwError . IOException) return)-}
      expected :: (File, ByteString)
      expected = (File {_fileSource = Just (ThePath "/usr/share/doc/cron/THANKS"),
                         _fileChksum = "8f57348732b9755b264ef1c15b0e6485",
                         _fileMessages = [],
                         _fileExt = "" },
                  (pack $ map (fromIntegral . ord) $ unlines
                   ["15 January 1990",
                    "Paul Vixie",
                    "",
                    "Many people have contributed to cron.  Many more than I can remember, in fact.",
                    "Rich Salz and Carl Gutekunst were each of enormous help to me in V1; Carl for",
                    "helping me understand UNIX well enough to write it, and Rich for helping me",
                    "get the features right.",
                    "",
                    "John Gilmore wrote me a wonderful review of V2, which took me a whole year to",
                    "answer even though it made me clean up some really awful things in the code.",
                    "(According to John the most awful things are still in here, of course.)",
                    "",
                    "Paul Close made a suggestion which led to /etc/crond.pid and the mutex locking",
                    "on it.  Kevin Braunsdorf of Purdue made a suggestion that led to @reboot and",
                    "its brothers and sisters; he also sent some diffs that lead cron toward compil-",
                    "ability with System V, though without at(1) capabilities, this cron isn't going",
                    "to be that useful on System V.  Bob Alverson fixed a silly bug in the line",
                    "number counting.  Brian Reid made suggestions which led to the run queue and",
                    "the source-file labelling in installed crontabs.",
                    "",
                    "Scott Narveson ported V2 to a Sequent, and sent in the most useful single batch",
                    "of diffs I got from anybody.  Changes attributable to Scott are:",
                    "\t-> sendmail won't time out if the command is slow to generate output",
                    "\t-> day-of-week names aren't off by one anymore",
                    "\t-> crontab says the right thing if you do something you shouldn't do",
                    "\t-> crontab(5) man page is longer and more informative",
                    "\t-> misc changes related to the side effects of fclose()",
                    "\t-> Sequent \"universe\" support added (may also help on Pyramids)",
                    "\t-> null pw_shell is dealt with now; default is /bin/sh"]))
