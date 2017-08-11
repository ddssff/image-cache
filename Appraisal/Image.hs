-- | Pure functions to deal with image data.

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Appraisal.Image
    ( ImageSize(..), ImageSize_1(..)
    , approx
    , rationalIso
    , ImageCrop(..)
    , Dimension(..)
    , Units(..)
    , ImageFile(..)
    , imageFileArea
    , PixmapShape(..)
    , ImageType(..)
    , fileExtension
    , ImageKey(..)
    , ImageKey_1(..)
    , ImageCacheMap
    , scaleFromDPI
    , widthInInches
    , widthInInches'
    , heightInInches
    , lens_saneSize
    , defaultSize
    , tests
    ) where

import Appraisal.FileCache (File(..), FileSource(..))
import Control.Lens (Iso', iso, Lens', lens, view)
#if MIN_VERSION_aeson(1,0,0)
import Data.Aeson (ToJSONKey, FromJSONKey)
#endif
import Data.Aeson.TH (deriveJSON)
import Data.Aeson.Types (defaultOptions)
import Data.Default (Default(def))
import Data.Generics (Data, Typeable)
import Data.Map (Map)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Monoid ((<>))
import Data.Ratio ((%), approxRational)
import Data.SafeCopy (base, deriveSafeCopy, extension, Migrate(..))
import Data.Serialize (Serialize(..))
import GHC.Generics (Generic)
import Language.Haskell.TH.Lift (deriveLiftMany)
import Numeric (fromRat, readSigned, readFloat, showSigned, showFFloat)
import Test.HUnit
import Test.QuickCheck (Arbitrary(..), choose, elements, Gen, oneof)
import Text.PrettyPrint.HughesPJClass (Pretty(pPrint), text)

-- I can't move these to FileCache.hs because DeriveAnyTime, which they
-- use, messes up another declartion there
deriving instance Serialize FileSource
deriving instance Serialize File

-- |This can describe an image size in various ways.
data ImageSize_1
    = ImageSize_1
      { _dim_1 :: Dimension
      , _size_1 :: Double
      , _units_1 :: Units
      } deriving (Show, Read, Eq, Ord, Typeable, Data, Generic, Serialize)

instance Migrate ImageSize where
    type MigrateFrom ImageSize = ImageSize_1
    migrate (ImageSize_1 d s u) =
        -- We want a ratio which approximates the double
        -- to about four significant digits.
        ImageSize d s' u
        where
          s' :: Rational
          s' = approx (toRational s)

-- | Simplify the ratio to avoid a long representation:
--
-- > λ> toRational 0.123456
-- > 8895942329546431 % 72057594037927936
-- > λ> approxRational (toRational 0.123456) (1 % 10000)
-- > 10 % 81
-- > λ> 10 / 81
-- > 0.12345679012345678   (wow, that's wierd)
--
-- This is important for values that might become part of a path,
-- we don't want them to be too long or subject to rounding errors.
approx :: Rational -> Rational
approx x = approxRational x (1 % 10000)

-- | readShowLens is not a good choice for rational numbers,  because
-- it only understands strings like "15 % 4", not "15" or "3.5".
-- If an invalid string is input this returns 0.
rationalLens :: Lens' Rational String
rationalLens = lens showRational (\r s -> fromMaybe r (readRationalMaybe s))

rationalIso :: Iso' Rational String
rationalIso = iso showRational (readRational 0)
    where
      readRational :: Rational -> String -> Rational
      readRational d = fromMaybe d . readRationalMaybe

showRational :: Rational -> String
showRational x = showSigned (showFFloat Nothing) 0 (fromRat x :: Double) ""

readRationalMaybe :: String -> Maybe Rational
readRationalMaybe = listToMaybe . map fst . filter (null . snd) . readSigned readFloat

-- mapRatio :: (Integral a, Integral b) => (a -> b) -> Ratio a -> Ratio b
-- mapRatio f r = f (numerator r) % f (denominator r)

data ImageSize
    = ImageSize
      { dim :: Dimension
      , size :: Rational
      , units :: Units
      } deriving (Show, Read, Eq, Ord, Typeable, Data, Generic, Serialize)

instance Default ImageSize where
    def = ImageSize TheArea 15.0 Inches

data Dimension
    = TheHeight
    | TheWidth
    | TheArea
    | Invalid String
    deriving (Show, Read, Eq, Ord, Typeable, Data, Generic, Serialize)

data Units
    = Inches
    | Cm
    | Points
    deriving (Show, Read, Eq, Ord, Typeable, Data, Enum, Bounded, Generic, Serialize)

-- |This describes the cropping and rotation of an image.
data ImageCrop
    = ImageCrop
      { topCrop :: Int
      , bottomCrop :: Int
      , leftCrop :: Int
      , rightCrop :: Int
      , rotation :: Int         -- 0, 90, 180, 270
      } deriving (Show, Read, Eq, Ord, Typeable, Data, Generic, Serialize)

instance Default ImageCrop where
    def = ImageCrop 0 0 0 0 0

-- | A class whose primary (only?) instance is ImageFile.  Access to
-- the original dimensions of the image, so we can compute the aspect
-- ratio.
class PixmapShape a where
    pixmapHeight :: a -> Int
    pixmapWidth :: a -> Int
    pixmapMaxVal :: a -> Int

-- |Given the desired DPI and image dimensions, return the factor by
-- which an image should be scaled.
scaleFromDPI :: PixmapShape a => Rational -> ImageSize -> a -> Maybe Rational
scaleFromDPI dpi sz file =
    case dim sz of
      _ | size sz < 0.000001 || size sz > 1000000.0 -> Nothing
      TheHeight -> Just $ inches sz * dpi / h
      TheWidth -> Just $ inches sz * dpi / w
      -- If we want an area of 9 square inches, and the dpi is 100, and the image
      -- size is 640x480 pixels, the scale is (9 * 100 * 100) / (640 * 480)
      TheArea -> Just (rsqrt (inches sz * dpi * dpi / (w * h)))
      _ -> fail "Invalid dimension"
    where
      w = fromIntegral (pixmapWidth file)
      h = fromIntegral (pixmapHeight file)

widthInInches :: PixmapShape a => a -> ImageSize -> Rational
widthInInches p s =
    case dim s of
      TheWidth -> toInches (units s) (size s)
      TheHeight -> widthInInches p (s {dim = TheWidth, size = approx (size s / r)})
      TheArea -> widthInInches p (s {dim = TheWidth, size = approx (rsqrt (size s / r))})
      _ -> error "Invalid dimension"
    where
      r :: Rational
      r = fromIntegral (pixmapHeight p) % fromIntegral (pixmapWidth p)
      toInches :: Units -> Rational -> Rational
      toInches Inches x = x
      toInches Cm x = x / (254 % 100)
      toInches Points x = x / (7227 % 100)

rsqrt :: Rational -> Rational
rsqrt = toRational . (sqrt :: Double -> Double) . fromRat

heightInInches :: PixmapShape a => a -> ImageSize -> Rational
heightInInches p s =
    case dim s of
      TheHeight -> toInches (units s) (size s)
      TheWidth -> heightInInches p (s {dim = TheHeight, size = approx (size s / r)})
      TheArea -> heightInInches p (s {dim = TheHeight, size = approx (rsqrt (size s / r))})
      _ -> error "Invalid dimension"
    where
      r :: Rational
      r = fromIntegral (pixmapHeight p) % fromIntegral (pixmapWidth p)
      toInches Inches x = x
      toInches Cm x = x / (254 % 100)
      toInches Points x = x / (7227 % 100)

-- |Modify an ImageSize so that the dimension is width and the units
-- are inches.  This way we can figure out how many images fit across
-- the page.
widthInInches' :: PixmapShape a => a -> ImageSize -> ImageSize
widthInInches' p s = s {units = Inches, size = approx (widthInInches p s), dim = TheWidth}

saneSize :: ImageSize -> ImageSize
saneSize sz =
    case (dim sz, inches sz) of
      (TheArea, n) | n < minArea -> sz {units = Inches, size = minArea}
      (TheArea, n) | n > maxArea -> sz {units = Inches, size = maxArea}
      (_, n) | n < minDist -> sz {units = Inches, size = toRational minDist}
      (_, n) | n > maxDist -> sz {units = Inches, size = maxDist}
      _ -> sz
    where
      -- inches and square inches
      minDist = 25 % 100
      maxDist = 25
      minArea = 625 % 10000
      maxArea = 625

lens_saneSize :: Iso' ImageSize ImageSize
lens_saneSize = iso saneSize saneSize

tests :: Test
tests = TestList [ TestCase (assertEqual "lens_saneSize 1"
                               (ImageSize {dim = TheHeight, size = 0.25, units = Inches})
                               (view lens_saneSize (ImageSize {dim = TheHeight, size = 0.0, units = Inches})))
                 ]

defaultSize :: ImageSize
defaultSize = ImageSize {dim = TheArea, units = Inches, size = 6.0}

-- | Return the value of size in inches
inches :: ImageSize -> Rational
inches sz =
    size sz / case (dim sz, units sz) of
                (_, Inches) -> 1
                (TheArea, Cm) -> (254 % 100) * (254 % 100)
                (TheArea, Points) -> (7227 % 100) * (7227 % 100)
                (_, Cm) -> 254 % 100
                (_, Points) -> 7227 % 100

instance Pretty Dimension where
    pPrint TheHeight = text "h"
    pPrint TheWidth = text "w"
    pPrint TheArea = text "a"
    pPrint x = text (show x)

instance Pretty Units where
    pPrint Inches = text "in"
    pPrint Cm = text "cm"
    pPrint Points = text "pt"

instance Pretty ImageSize where
    pPrint (ImageSize d sz u) = pPrint d <> text ("=" <> show sz <> " ") <> pPrint u

instance Pretty ImageCrop where
    pPrint (ImageCrop t b l r _) = text $ "crop (" <> show (b, l) <> " -> " <> show (t, r) <> ")"

-- | A file containing an image plus meta info.
data ImageFile
    = ImageFile
      { imageFile :: File
      , imageFileType :: ImageType
      , imageFileWidth :: Int
      , imageFileHeight :: Int
      , imageFileMaxVal :: Int
      } deriving (Show, Read, Eq, Ord, Data, Typeable, Generic, Serialize)

data ImageType = PPM | JPEG | GIF | PNG deriving (Show, Read, Eq, Ord, Typeable, Data, Generic, Serialize)

instance PixmapShape ImageFile where
    pixmapHeight = imageFileHeight
    pixmapWidth = imageFileWidth
    pixmapMaxVal = imageFileMaxVal

instance Pretty ImageFile where
    pPrint (ImageFile f typ w h _mx) = text "ImageFile(" <> pPrint f <> text (" " <> show w <> "x" <> show h <> " " <> show typ <> ")")

-- |Return the area of an image in square pixels.
imageFileArea :: ImageFile -> Int
imageFileArea image = imageFileWidth image * imageFileHeight image

fileExtension :: ImageType -> String
fileExtension JPEG = ".jpg"
fileExtension PPM = ".ppm"
fileExtension GIF = ".gif"
fileExtension PNG = ".png"

data ImageKey_1
    = ImageOriginal_1 ImageFile
    -- ^ An unmodified upload
    | ImageCropped_1 ImageCrop ImageKey
    -- ^ A cropped version of another image
    | ImageScaled_1 ImageSize Double ImageKey
    -- ^ A resized version of another image
    | ImageUpright_1 ImageKey
    -- ^ Image uprighted using the EXIF orientation code, see  "Appraisal.Exif"
    deriving (Eq, Ord, Read, Show, Typeable, Data, Generic, Serialize)

-- | Describes an ImageFile and, if it was derived from other image
-- files, how.
data ImageKey
    = ImageOriginal ImageFile
    -- ^ An unmodified upload
    | ImageCropped ImageCrop ImageKey
    -- ^ A cropped version of another image
    | ImageScaled ImageSize Rational ImageKey
    -- ^ A resized version of another image
    | ImageUpright ImageKey
    -- ^ Image uprighted using the EXIF orientation code, see  "Appraisal.Exif"
    deriving (Eq, Ord, Read, Show, Typeable, Data, Generic, Serialize)

instance Migrate ImageKey where
    type MigrateFrom ImageKey = ImageKey_1
    migrate (ImageOriginal_1 f) = ImageOriginal f
    migrate (ImageCropped_1 c k) = ImageCropped c k
    -- Change scale factor to a rational with about four significant digits.
    migrate (ImageScaled_1 s f k) = ImageScaled s (approx (toRational f)) k
    migrate (ImageUpright_1 k) = ImageUpright k

instance Pretty ImageKey where
    pPrint (ImageOriginal x) = pPrint x
    pPrint (ImageUpright x) = text "Upright (" <> pPrint x <> text ")"
    pPrint (ImageCropped crop x) = text "Crop (" <> pPrint crop <> text ") (" <> pPrint x <> text ")"
    pPrint (ImageScaled size dpi x) = text "Scale (" <> pPrint size <> text " @" <> text (show dpi) <> text "dpi) (" <> pPrint x <> text ")"

type ImageCacheMap = Map ImageKey ImageFile

$(deriveJSON defaultOptions ''Units)
$(deriveJSON defaultOptions ''Dimension)
$(deriveJSON defaultOptions ''ImageCrop)
$(deriveJSON defaultOptions ''ImageSize)
$(deriveJSON defaultOptions ''ImageSize_1)
$(deriveJSON defaultOptions ''ImageKey)
$(deriveJSON defaultOptions ''ImageKey_1)
$(deriveJSON defaultOptions ''ImageType)
$(deriveJSON defaultOptions ''ImageFile)

#if MIN_VERSION_aeson(1,0,0)
instance FromJSONKey Rational
instance ToJSONKey Rational
instance FromJSONKey ImageFile
instance ToJSONKey ImageFile
instance FromJSONKey ImageCrop
instance ToJSONKey ImageCrop
instance FromJSONKey ImageSize
instance ToJSONKey ImageSize
instance FromJSONKey ImageSize_1
instance ToJSONKey ImageSize_1
instance FromJSONKey ImageKey
instance ToJSONKey ImageKey
#endif

instance Arbitrary Units where
    arbitrary = elements [Inches, Cm, Points]

instance Arbitrary ImageType where
    arbitrary = elements [PPM, JPEG, GIF, PNG]

instance Arbitrary Dimension where
    arbitrary = oneof [pure TheHeight, pure TheWidth, pure TheArea, Invalid <$> arbitrary]

instance Arbitrary ImageSize where
    arbitrary = ImageSize <$> arbitrary <*> ((% 100) <$> (choose (1,10000) :: Gen Integer)) <*> arbitrary

instance Arbitrary ImageSize_1 where
    arbitrary = ImageSize_1 <$> arbitrary <*> (fromInteger <$> (choose (1,10000) :: Gen Integer)) <*> arbitrary

instance Arbitrary ImageFile where
    arbitrary = ImageFile <$> arbitrary
                          <*> arbitrary
                          <*> choose (1,5000)
                          <*> choose (1,5000)
                          <*> choose (1,255)

instance Arbitrary ImageCrop where
    arbitrary = ImageCrop <$> choose (0,100)
                          <*> choose (0,100)
                          <*> choose (0,100)
                          <*> choose (0,100)
                          <*> elements [0, 90, 180, 270]

instance Arbitrary ImageKey where
    arbitrary = oneof [ ImageOriginal <$> arbitrary
                      , ImageCropped <$> arbitrary <*> arbitrary
                      , ImageScaled <$> arbitrary <*> arbitrary <*> arbitrary
                      , ImageUpright <$> arbitrary ]

instance Arbitrary ImageKey_1 where
    arbitrary = oneof [ ImageOriginal_1 <$> arbitrary
                      , ImageCropped_1 <$> arbitrary <*> arbitrary
                      , ImageScaled_1 <$> arbitrary <*> arbitrary <*> arbitrary
                      , ImageUpright_1 <$> arbitrary ]

$(deriveSafeCopy 1 'base ''ImageSize_1)
$(deriveSafeCopy 2 'extension ''ImageSize)
$(deriveSafeCopy 0 'base ''Dimension)
$(deriveSafeCopy 0 'base ''Units)
$(deriveSafeCopy 0 'base ''ImageCrop)
$(deriveSafeCopy 1 'base ''ImageKey_1)
$(deriveSafeCopy 2 'extension ''ImageKey)
$(deriveSafeCopy 0 'base ''ImageType)
$(deriveSafeCopy 0 'base ''ImageFile)

$(deriveLiftMany [
   ''ImageFile,
   ''ImageType,
   ''ImageKey,
   ''ImageSize,
   ''Units,
   ''ImageCrop,
   ''Dimension
  ])
