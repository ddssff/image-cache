-- | Maintain a cache of key/value pairs in acid state, where the
-- values are monadically obtained from the keys using the 'build'
-- method of the MonadCache instance, and stored using acid-state.

{-# LANGUAGE CPP, ConstraintKinds #-}
{-# LANGUAGE DeriveAnyClass, DeriveGeneric #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall -Wredundant-constraints -fno-warn-orphans #-}

module Appraisal.AcidCache
    ( -- * Open cache
      CacheMap(..)
    , unCacheMap
    , initCacheMap
    , openCache
    , withCache
    -- * Cached map events
    , PutValue(..)
    , PutValues(..)
    , LookValue(..)
    , LookValues(..)
    , LookMap(..)
    , DeleteValue(..)
    , DeleteValues(..)
    -- * Monad class for cached map
    , HasCache(askCacheAcid, buildCacheValue)
    , cacheMap
    , cacheLook
    , cacheInsert
    , cacheDelete
    -- * Instance
    -- , runMonadCacheT
    ) where

import Control.Lens ((%=), at, makeLenses, view)
import Control.Monad.Catch (bracket, {-MonadCatch,-} MonadMask)
import Control.Monad.Reader (MonadReader(ask))
import Control.Monad.State (liftIO)
import Data.Acid (AcidState, makeAcidic, openLocalStateFrom, Query, query, Update, update)
import Data.Acid.Local (createCheckpointAndClose)
import Data.Generics (Data, Proxy, Typeable)
import Data.Map.Strict as Map (delete, difference, fromSet, insert, intersection, Map, union)
import Data.SafeCopy -- (deriveSafeCopy, extension, Migrate(..), SafeCopy)
import Data.Serialize (label, Serialize)
import Data.Set as Set (Set)
import Extra.Except (liftIOError, MonadIO, MonadIOError)
import GHC.Generics (Generic)

-- Later we could make FileError a type parameter, but right now its
-- tangled with the MonadError type.
data CacheMap key val err = CacheMap {_unCacheMap :: Map key (Either err val)} deriving (Data, Generic, Serialize, Eq, Ord, Show)
$(makeLenses ''CacheMap)

#if 0
$(deriveSafeCopy 2 'extension ''CacheMap)
-- $(safeCopyInstance 2 'extension [t|CacheMap|])
#else
instance (Ord key, SafeCopy key, SafeCopy val, SafeCopy err) => SafeCopy (CacheMap key val err) where
      putCopy (CacheMap a)
        = contain
            (do safeput <- getSafePut
                safeput a
                return ())
      getCopy
        = contain
            ((label "Appraisal.AcidCache.CacheMap:")
               (do safeget <- getSafeGet
                   (return CacheMap <*> safeget)))
      version = 2
      kind = extension
      errorTypeName _ = "Appraisal.AcidCache.CacheMap"
#endif

instance (Ord key, SafeCopy key, SafeCopy val) => Migrate (CacheMap key val err) where
    type MigrateFrom (CacheMap key val err) = Map key val
    migrate mp = CacheMap (fmap Right mp)

-- | Install a key/value pair into the cache.
putValue :: Ord key => key -> Either err val -> Update (CacheMap key val err) ()
putValue key img = unCacheMap %= Map.insert key img

-- | Install several key/value pairs into the cache.
putValues :: Ord key => Map key (Either err val) -> Update (CacheMap key val err) ()
putValues pairs = unCacheMap %= Map.union pairs

-- | Look up a key.
lookValue :: Ord key => key -> Query (CacheMap key val err) (Maybe (Either err val))
lookValue key = view (unCacheMap . at key)

-- | Look up several keys.
lookValues :: Ord key => Set key -> Query (CacheMap key val err) (Map key (Either err val))
lookValues keys = Map.intersection <$> view unCacheMap <*> pure (Map.fromSet (const ()) keys)

-- | Return the entire cache.  (Despite what ghc says, this constraint
-- isn't redundant, without it the makeAcidic call has a missing Ord
-- key instance.)
lookMap :: Ord key => Query (CacheMap key val err) (CacheMap key val err)
lookMap = ask

-- | Remove values from the database.
deleteValue :: (Ord key{-, Serialize key, Serialize val, Serialize e-}) => key -> Update (CacheMap key val err) ()
deleteValue key = unCacheMap %= Map.delete key

deleteValues :: Ord key => Set key -> Update (CacheMap key val err) ()
deleteValues keys = unCacheMap %= (`Map.difference` (Map.fromSet (const ()) keys))

$(makeAcidic ''CacheMap ['putValue, 'putValues, 'lookValue, 'lookValues, 'lookMap, 'deleteValue, 'deleteValues])

initCacheMap :: Ord key => CacheMap key val err
initCacheMap = CacheMap mempty

openCache :: (SafeCopy key, Typeable key, Ord key,
              SafeCopy err, Typeable err,
              SafeCopy val, Typeable val) => FilePath -> IO (AcidState (CacheMap key val err))
openCache path = openLocalStateFrom path initCacheMap

-- | In theory the MonadError type e1 might differ from the error type
-- stored in the map e2.  But I'm not sure if it would work in practice.
withCache :: (MonadIOError e m, MonadMask m,
              SafeCopy val, Typeable val, SafeCopy err, Typeable err,
              Ord key, Typeable key, SafeCopy key) => FilePath -> (AcidState (CacheMap key val err) -> m b) -> m b
withCache path f = bracket (liftIOError (openCache path)) (liftIOError . createCheckpointAndClose) $ f

-- | Note that class 'HasCache' and the 'cacheInsert' function return
-- values containing a 'FileError', but the monad m only has the
-- constraint HasFileError.
class (Ord key, SafeCopy key, Typeable key, Show key, Serialize key,
       SafeCopy val, Typeable val, Serialize val,
       SafeCopy err, Typeable err, MonadIO m) => HasCache key val err m where
    askCacheAcid :: m (AcidState (CacheMap key val err))
    buildCacheValue :: key -> m (Either err val)

-- | Call the build function on cache miss to build the value.
cacheInsert :: forall key val err m. (HasCache key val err m) => key -> m (Either err val)
cacheInsert key = do
  st <- askCacheAcid
  liftIO (query st (LookValue key)) >>= maybe (cacheMiss key) return

cacheMiss :: forall key val err m. (HasCache key val err m) => key -> m (Either err val)
cacheMiss key = do
  st <- askCacheAcid :: m (AcidState (CacheMap key val err))
  val <- buildCacheValue key
  () <- liftIO $ update st (PutValue key val)
  return val

-- | Query the cache, but do nothing on cache miss.
cacheLook :: HasCache key val err m => key -> m (Maybe (Either err val))
cacheLook key = do
  st <- askCacheAcid
  liftIO $ query st (LookValue key)

cacheMap :: HasCache key val err m => m (CacheMap key val err)
cacheMap = do
  st <- askCacheAcid
  liftIO $ query st LookMap

cacheDelete :: forall key val err m. (HasCache key val err m) => Proxy (val, err) -> Set key -> m ()
cacheDelete _ keys = do
  (st :: AcidState (CacheMap key val err)) <- askCacheAcid
  liftIO $ update st (DeleteValues keys)
