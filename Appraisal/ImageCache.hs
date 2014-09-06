-- | Database transactions to manage a cache of image files.  This
-- allows us to find derived versions of an image (resized, cropped,
-- rotated) given the ImageKey for the desired version, which contains
-- the checksum of the original image and the desired transformation.
-- If the desired transformation is not in the cached it is produced
-- and added.
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS -Wall #-}
module Appraisal.ImageCache
    ( ImageKey(..)
    , ImageCacheMap
    , ImageCacheState
    , ImageCacheIO
    , runImageCacheIO
    , fileCachePath'
    ) where

import Appraisal.Cache (CacheState, MonadCache(..), runMonadCacheT)
import Appraisal.Config (Paths)
import Appraisal.File (fileCachePath)
import Appraisal.Image (ImageCrop, ImageSize, scaleFromDPI)
import Appraisal.ImageFile (ImageFile(imageFile), editImage, scaleImage, uprightImage)
import Appraisal.Utils.ErrorWithIO (ErrorWithIO)
import Appraisal.Utils.Pretty (Doc, Pretty(pretty), text)
import Control.Monad.Reader (MonadReader(ask), MonadTrans(lift), ReaderT, runReaderT)
import Data.Generics (Data, Typeable)
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.SafeCopy (base, deriveSafeCopy)
import Appraisal.Utils.Prelude

data ImageKey
    = ImageOriginal ImageFile
    | ImageCropped ImageCrop ImageKey
    | ImageScaled ImageSize Double ImageKey
    | ImageUpright ImageKey
    deriving (Eq, Ord, Show, Typeable, Data)

instance Pretty Doc ImageKey where
    pretty (ImageOriginal x) = pretty x
    pretty (ImageUpright x) = text "Upright (" <> pretty x <> text ")"
    pretty (ImageCropped crop x) = text "Crop (" <> pretty crop <> text ") (" <> pretty x <> text ")"
    pretty (ImageScaled size dpi x) = text "Scale (" <> pretty size <> text " @" <> text (show dpi) <> text "dpi) (" <> pretty x <> text ")"

$(deriveSafeCopy 1 'base ''ImageKey)

data ImageCacheMap = ImageCacheMap (Map ImageKey ImageFile) deriving (Eq, Ord, Show, Typeable, Data)

$(deriveSafeCopy 1 'base ''ImageCacheMap)

type ImageCacheState = CacheState ImageKey ImageFile
type ImageCacheIO p = ReaderT p (ReaderT ImageCacheState ErrorWithIO)

runImageCacheIO :: Paths p => ImageCacheIO p a -> p -> ImageCacheState -> ErrorWithIO a
runImageCacheIO action p st = runMonadCacheT (runReaderT action p) st

instance Paths p => MonadCache ImageKey ImageFile (ImageCacheIO p) where
    askAcidState = lift ask
    build (ImageOriginal img) = return img
    build (ImageUpright key) = do
      top <- ask
      img <- build key
      lift (lift (uprightImage top img))
    build (ImageScaled sz dpi key) = do
      top <- ask
      img <- build key
      let scale = scaleFromDPI dpi sz img
      lift (lift (scaleImage (fromMaybe 1.0 scale) top img))
    build (ImageCropped crop key) = do
      top <- ask
      img <- build key
      lift (lift (editImage crop top img))

-- | Compute 'Appraisal.File.fileCachePath' for an ImageFile.
fileCachePath' :: Paths p => ImageFile -> ImageCacheIO p FilePath
fileCachePath' x =
    do ver <- ask
       return $ fileCachePath ver (imageFile x)
