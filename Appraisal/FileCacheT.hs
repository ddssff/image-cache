-- | Maintain a cache of files.
--
-- A data structure representing a local cache of a data file.  The
-- cached file persists across runs of our application, and can be
-- accessed by name and passed to software which requires a file, for
-- example a document formatter such as LaTeX.  The original data can
-- be supplied as either a URI, a local file path, or as a ByteString.
-- The file is then downloaded and stored on the local machine at a
-- location based on the file's checksum.

{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS -Wall #-}

module Appraisal.FileCacheT
    ( FileError(..)
    , IsFileError(fromFileError)
    , logFileError
      -- * Monad and Class
    , FileCacheTop(..)
    , HasFileCacheTop(fileCacheTop)
    , MonadFileCache
    , ensureFileCacheTop
    , FileCacheT
    , runFileCacheT
    , runFileCacheTop
    , runFileCache
    , mapFileCacheT
    ) where

import Control.Exception as E (ErrorCall(ErrorCallWithLocation))
import Control.Exception (fromException, IOException, SomeException, throw, try)
import Control.Lens (_2, view)
import Control.Monad.Except -- (ExceptT(ExceptT), liftEither, MonadError(..), runExceptT, withExceptT)
import Control.Monad.Identity (Identity, runIdentity)
import Control.Monad.Reader (mapReaderT, MonadReader(ask, local), ReaderT, runReaderT)
import Control.Monad.Trans (lift, MonadIO(..), MonadTrans)
#ifdef LAZYIMAGES
import qualified Data.ByteString.Lazy as P
#else
import qualified Data.ByteString as P
#endif
import Data.Data (Data)
import Data.String (IsString(fromString))
import Debug.Show (V(V))
import Data.Text (pack, Text, unpack)
import System.Directory (createDirectoryIfMissing)
import System.Log.Logger ( logM, Priority(ERROR) )

data FileError
    = IOException {-IOException-} Text
    | ErrorCall {-E.ErrorCall-} Text
    | Command {-CreateProcess ExitCode-} Text Text
    | CommandInput P.ByteString FileError
    | CommandOut P.ByteString FileError
    | CommandErr P.ByteString FileError
    | FunctionName String FileError
    | Description String FileError
    | SomeFileError String
    deriving (Data, Eq, Ord, Show)

instance IsString FileError where fromString = SomeFileError
class IsFileError e where fromFileError :: FileError -> e
instance IsFileError FileError where fromFileError = id

instance Show (V FileError) where show (V x) = show x

logFileError :: String -> FileError -> IO ()
logFileError prefix (Description s e) = logM prefix ERROR (" - error description: " <> s) >> logFileError prefix e
logFileError prefix (FunctionName n e) = logM prefix ERROR (" - error function " <> n) >> logFileError prefix e
logFileError prefix (IOException e) = logM prefix ERROR (" - IO exception: " <> unpack e)
logFileError prefix (SomeFileError s) = logM prefix ERROR (" - failure: " <> s)
logFileError prefix (Command cmd code) = logM prefix ERROR (" - shell command failed: " <> show cmd <> " -> " <> show code)
logFileError prefix (ErrorCall e) = logM prefix ERROR (" - error call: " <> show e)
logFileError prefix (CommandInput bs e) = logM prefix ERROR (" - command input: " <> show (P.take 1000 bs)) >> logFileError prefix e
logFileError prefix (CommandOut bs e) = logM prefix ERROR (" - command stdout: " <> show (P.take 1000 bs)) >> logFileError prefix e
logFileError prefix (CommandErr bs e) = logM prefix ERROR (" - command stderr: " <> show (P.take 1000 bs)) >> logFileError prefix e

newtype FileCacheTop = FileCacheTop {unFileCacheTop :: FilePath} deriving Show

-- | Class of monads with a 'FilePath' value containing the top
-- of a 'FileCache'.  MonadIO is not a superclass here because
-- some FileCache operations (e.g. path construction) do not need it.
class Monad m => HasFileCacheTop m where
    fileCacheTop :: m FileCacheTop

newtype FileCacheT st e m a =
    FileCacheT {unFileCacheT :: ReaderT (st, FilePath) (ExceptT e m) a}
    deriving (Monad, Applicative, Functor)

type FileCache st e a = FileCacheT st FileError Identity a

instance MonadTrans (FileCacheT st FileError) where
    lift = FileCacheT . lift . lift

type MonadFileCache e m = (MonadIO m, IsFileError e, Show e, MonadError e m, HasFileCacheTop m)

#if !MIN_VERSION_mtl(2,2,2)
liftEither :: MonadError e m => Either e a -> m a
liftEither = either throwError return
#endif

instance MonadIO m => MonadIO (FileCacheT st FileError m) where
    -- liftIO = mapFileCacheT IOException . FileCacheT . liftIO
    liftIO io = (FileCacheT . liftIO . runExceptT . withExceptT toFileError . ExceptT . logErrorCall . try $ io) >>= liftEither
     where
      logErrorCall :: IO (Either SomeException a) -> IO (Either SomeException a)
      logErrorCall x =
          x >>= either (\e -> case fromException e :: Maybe E.ErrorCall of
                                Just (ErrorCallWithLocation msg loc) -> logM "FileCache.hs" ERROR (show loc ++ ": " ++ msg) >> return (Left e)
                                _ -> return (Left e)) (return . Right)
      toFileError :: SomeException -> FileError
      toFileError e =
          maybe (throw e)
                id
                (msum [fmap (IOException . pack . show) (fromException e :: Maybe IOException),
                       fmap (Appraisal.FileCacheT.ErrorCall . pack . show) (fromException e :: Maybe E.ErrorCall)])

instance (Monad m, MonadReader (st, FilePath) (FileCacheT st FileError m)) => HasFileCacheTop (FileCacheT st FileError m) where
    fileCacheTop = (FileCacheTop . view _2) <$> ask

instance (Monad m, e ~ FileError) => MonadError e (FileCacheT st e m) where
    throwError :: e -> FileCacheT st FileError m a
    throwError e = FileCacheT $ throwError e
    catchError :: FileCacheT st FileError m a -> (e -> FileCacheT st FileError m a) -> FileCacheT st FileError m a
    catchError (FileCacheT m) c = FileCacheT $ m `catchError` (unFileCacheT . c)

instance Monad m => MonadReader (st, FilePath) (FileCacheT st FileError m) where
    ask = FileCacheT ask
    local f action = FileCacheT (local f (unFileCacheT action))

runFileCacheT ::
       st
    -> FileCacheTop
    -> FileCacheT st FileError m a
    -> m (Either FileError a)
runFileCacheT fileAcidState (FileCacheTop fileCacheDir) action =
    runExceptT (runReaderT (unFileCacheT action) (fileAcidState, fileCacheDir))

runFileCacheTop ::
       FileCacheTop
    -> FileCacheT () e m a
    -> m (Either e a)
runFileCacheTop (FileCacheTop fileCacheDir) action =
    runExceptT (runReaderT (unFileCacheT action) ((), fileCacheDir))

runFileCache ::
       FileCacheTop
    -> FileCache () () a
    -> a
runFileCache (FileCacheTop fileCacheDir) action =
    (\(Right x) -> x) $ runIdentity (runExceptT (runReaderT (unFileCacheT action) ((), fileCacheDir)))

mapFileCacheT :: Functor m => (e -> e') -> FileCacheT st e m a -> FileCacheT st e' m a
mapFileCacheT f = FileCacheT . mapReaderT (withExceptT f) . unFileCacheT

ensureFileCacheTop :: MonadIO m => FileCacheT st FileError m ()
ensureFileCacheTop = fileCacheTop >>= liftIO . createDirectoryIfMissing True . unFileCacheTop
