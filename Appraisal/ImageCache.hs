-- | Maintain a cache of image files.
--
-- Database transactions to manage a cache of image files.  This
-- allows us to find derived versions of an image (resized, cropped,
-- rotated) given the ImageKey for the desired version, which contains
-- the checksum of the original image and the desired transformation.
-- If the desired transformation is not in the cached it is produced
-- and added.
--
-- The 'ImageKey' type describes the 'ImageFile' we would like the
-- system to produce.  This is passed to the 'build' method (which may
-- use IO) of 'MonadCache', and if that 'ImageKey' is not already in
-- the cache the desired 'ImageFile' is generated, added to the cache,
-- and returned.

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS -Wall #-}
module Appraisal.ImageCache
    ( -- * Image cache monad
      MonadImageCache
    , runImageCacheIO
    -- * ImageFile upload
    , imageFileFromBytes
    , imageFileFromURI
    , imageFileFromPath
    -- * ImageFile query
    , imageFilePath
    -- * Deriving new ImageFiles
    , uprightImage
    , scaleImage
    , editImage
    ) where

import Appraisal.AcidCache (MonadCache(..))
import Appraisal.Exif (normalizeOrientationCode)
import Appraisal.FileCache (CacheFile(..), File(..), FileCacheT, FileCacheTop, fileFromBytes, fileFromPath, fileFromURI,
                            fileFromCmdViaTemp, loadBytes, MonadFileCache, MonadFileCacheIO, runFileCacheIO)
import Appraisal.Image (ImageCrop(..), ImageFile(..), ImageType(..), ImageKey(..), ImageCacheMap,
                        fileExtension, imageFileType, PixmapShape(..), scaleFromDPI, approx)
import Appraisal.Utils.ErrorWithIO (logException, ensureLink)
import Control.Exception (IOException, SomeException, throw)
import Control.Lens (makeLensesFor, view)
import Control.Monad.Catch (MonadCatch(catch))
import Control.Monad.Except (catchError, MonadError)
import Control.Monad.Reader (MonadReader(ask), ReaderT)
import Control.Monad.Trans (liftIO, MonadIO)
import Data.Acid (AcidState)
import Data.ByteString (ByteString)
import Data.Generics (Typeable)
import Data.List (intercalate)
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.SafeCopy (SafeCopy)
import qualified Data.ByteString.Lazy as P (fromStrict, toStrict)
#ifdef LAZYIMAGES
import qualified Data.ByteString.Lazy as P
#else
import qualified Data.ByteString.UTF8 as P
import qualified Data.ByteString as P
#endif
import Network.URI (URI, uriToString)
import Numeric (fromRat, showFFloat)
import System.Exit (ExitCode(..))
import System.Log.Logger (logM, Priority(ERROR))
import System.Process (CreateProcess(..), CmdSpec(..), proc, showCommandForUser)
import System.Process.ListLike (readCreateProcessWithExitCode, readProcessWithExitCode, showCreateProcessForUser)
import Text.Regex (mkRegex, matchRegex)

-- |Return the local pathname of an image file with an appropriate extension (e.g. .jpg).
imageFilePath :: MonadFileCache m => ImageFile -> m FilePath
imageFilePath img = fileCachePath (imageFile img) >>= \ path -> return $ path ++ fileExtension (imageFileType img)

imageFileFromBytes :: MonadFileCacheIO m => ByteString -> m ImageFile
imageFileFromBytes bs = fileFromBytes bs >>= makeImageFile

-- | Find or create a cached image file from a URI.
imageFileFromURI :: MonadFileCacheIO m => URI -> m ImageFile
imageFileFromURI uri = fileFromURI (uriToString id uri "") >>= makeImageFile . fst

imageFileFromPath :: MonadFileCacheIO m => FilePath -> m ImageFile
imageFileFromPath path = fileFromPath path >>= makeImageFile . fst

-- | Create an image file from a 'File'.  An ImageFile value implies
-- that the image has been found in or added to the acid-state cache.
makeImageFile :: forall m. MonadFileCacheIO m => File -> m ImageFile
makeImageFile file = $logException $ do
    -- logM "Appraisal.ImageFile.makeImageFile" INFO ("Appraisal.ImageFile.makeImageFile - INFO file=" ++ show file) >>
    path <- fileCachePath file
    (getFileType path >>= $logException . imageFileFromType path file) `catchError` handle
    where
      handle :: IOError -> m ImageFile
      handle e =
          $logException $ fail $ "Failure making image file " ++ show file ++ ": " ++ show e

-- | Helper function to build an image once its type is known - JPEG,
-- GIF, etc.
imageFileFromType :: MonadFileCacheIO m => FilePath -> File -> ImageType -> m ImageFile
imageFileFromType path file typ = do
  -- logM "Appraisal.ImageFile.imageFileFromType" DEBUG ("Appraisal.ImageFile.imageFileFromType - typ=" ++ show typ) >>
  let cmd = case typ of
              JPEG -> pipe [proc "jpegtopnm" [path], proc "pnmfile" []]
              PPM ->  (proc "pnmfile" [])
              GIF -> pipe [proc "giftopnm" [path], proc "pnmfile" []]
              PNG -> pipe [proc "pngtopnm" [path], proc "pnmfile" []]
  -- err may contain "Output file write error --- out of disk space?"
  -- because pnmfile closes the output descriptor of the decoder
  -- process early.  This can be ignored.
  (code, out, _err) <- liftIO $ readCreateProcessWithExitCode cmd P.empty
  case code of
    ExitSuccess -> imageFileFromPnmfileOutput file typ out
    ExitFailure _ -> error $ "Failure building image file:\n " ++ showCmdSpec (cmdspec cmd) ++ " -> " ++ show code

-- | Helper function to load a PNM file.
imageFileFromPnmfileOutput :: MonadFileCacheIO m => File -> ImageType -> P.ByteString -> m ImageFile
imageFileFromPnmfileOutput file typ out =
        case matchRegex pnmFileRegex (P.toString out) of
          Just [width, height, _, maxval] ->
            ensureExtensionLink file (fileExtension typ) >>=
            (const . return $ ImageFile { imageFile = file
                                        , imageFileType = typ
                                        , imageFileWidth = read width
                                        , imageFileHeight = read height
                                        , imageFileMaxVal = if maxval == "" then 1 else read maxval })
          _ -> error $ "Unexpected output from pnmfile: " ++ show out
  where
      pnmFileRegex = mkRegex "^stdin:\tP[PGB]M raw, ([0-9]+) by ([0-9]+)([ ]+maxval ([0-9]+))?$"

-- | The image file names are just checksums.  This makes sure a link
-- with a suitable extension (.jpg, .gif) also exists.
ensureExtensionLink :: MonadFileCacheIO m => File -> String -> m ()
ensureExtensionLink file ext = fileCachePath file >>= \ path -> liftIO $ ensureLink (view fileChksumL file) (path ++ ext)

-- | Helper function to learn the 'ImageType' of a file by runing
-- @file -b@.
getFileType :: MonadFileCacheIO m => FilePath -> m ImageType
getFileType path =
    liftIO (readProcessWithExitCode cmd args P.empty) `catchError` err >>= return . test . (\ (_, out, _) -> out)
    where
      cmd = "file"
      args = ["-b", path]
      err (e :: IOError) =
          $logException $ fail ("getFileType Failure: " ++ showCommandForUser cmd args ++ " -> " ++ show e)
      test :: P.ByteString -> ImageType
      test s = maybe (error $ "ImageFile.getFileType - Not an image: " ++ path ++ "(Ident string: " ++ show s ++ ")") id (foldr (testre (P.toString s)) Nothing tests)
      testre _ _ (Just result) = Just result
      testre s (re, typ) Nothing = maybe Nothing (const (Just typ)) (matchRegex re s)
      -- Any more?
      tests = [(mkRegex "Netpbm P[BGPP]M \"rawbits\" image data$", PPM)
              ,(mkRegex "JPEG image data", JPEG)
              ,(mkRegex "PNG image data", PNG)
              ,(mkRegex "GIF image data", GIF)]

-- | Build, cache, and return a version of the image with its
-- orientation fixed based on the EXIF orientation flag.  If the image
-- is already upright it will return the original ImageFile.
uprightImage :: MonadFileCacheIO m => ImageFile -> m ImageFile
uprightImage orig = do
  -- path <- _fileCachePath (imageFile orig)
  bs <- $logException $ loadBytes (imageFile orig)
  bs' <- $logException $ liftIO (normalizeOrientationCode (P.fromStrict bs))
  maybe (return orig) (\ bs'' -> $logException (fileFromBytes (P.toStrict bs'')) >>= makeImageFile) bs'

-- |Use a decoder, pnmscale, and an encoder to change the size of an
-- |image file.  The new image inherits the home directory of the old.
scaleImage :: forall m. MonadFileCacheIO m => Double -> ImageFile -> m ImageFile
scaleImage scale orig | approx (toRational scale) == 1 = return orig
scaleImage scale orig = $logException $ do
    path <- fileCachePath (imageFile orig)
    let decoder = case imageFileType orig of
                    JPEG -> showCommandForUser "jpegtopnm" [path]
                    PPM -> showCommandForUser "cat" [path]
                    GIF -> showCommandForUser "giftopnm" [path]
                    PNG -> showCommandForUser "pngtopnm" [path]
        scaler = showCommandForUser "pnmscale" [showFFloat (Just 6) scale ""]
        -- Probably we should always build a png here rather than
        -- whatever the original file type was?
        encoder = case imageFileType orig of
                    JPEG -> showCommandForUser "cjpeg" []
                    PPM -> showCommandForUser "cat" []
                    GIF -> showCommandForUser "ppmtogif" []
                    PNG -> showCommandForUser "pnmtopng" []
        cmd = pipe' [decoder, scaler, encoder]
    -- fileFromCmd ver cmd >>= buildImage
    fileFromCmdViaTemp cmd >>= buildImage
    where
      buildImage :: File -> m ImageFile
      buildImage file = makeImageFile file `catchError` (\ e -> fail $ "scaleImage - makeImageFile failed: " ++ show e)

-- |Crop an image.
editImage :: MonadFileCacheIO m => ImageCrop -> ImageFile -> m ImageFile
editImage crop file = $logException $
    case commands of
      [] ->
          return file
      _ ->
          (loadBytes (imageFile file) >>=
           liftIO . pipeline commands >>=
           fileFromBytes >>=
           makeImageFile) `catchError` err
    where
      commands = buildPipeline (imageFileType file) [cut, rotate] (latexImageFileType (imageFileType file))
      -- We can only embed JPEG and PNG images in a LaTeX
      -- includegraphics command, so here we choose which one to use.
      latexImageFileType GIF = PNG
      latexImageFileType PPM = PNG
      latexImageFileType JPEG = JPEG
      latexImageFileType PNG = PNG
      cut = case (leftCrop crop, rightCrop crop, topCrop crop, bottomCrop crop) of
              (0, 0, 0, 0) -> Nothing
              (l, r, t, b) -> Just (PPM, proc "pnmcut" ["-left", show l,
                                                        "-right", show (w - r - 1),
                                                        "-top", show t,
                                                        "-bottom", show (h - b - 1)], PPM)
      rotate = case rotation crop of
                 90 -> Just (JPEG, proc "jpegtran" ["-rotate", "90"], JPEG)
                 180 -> Just (JPEG, proc "jpegtran" ["-rotate", "180"], JPEG)
                 270 -> Just (JPEG, proc "jpegtran" ["-rotate", "270"], JPEG)
                 _ -> Nothing
      w = pixmapWidth file
      h = pixmapHeight file
      buildPipeline :: ImageType -> [Maybe (ImageType, CreateProcess, ImageType)] -> ImageType -> [CreateProcess]
      buildPipeline start [] end = convert start end
      buildPipeline start (Nothing : ops) end = buildPipeline start ops end
      buildPipeline start (Just (a, cmd, b) : ops) end | start == a = cmd : buildPipeline b ops end
      buildPipeline start (Just (a, cmd, b) : ops) end = convert start a ++ buildPipeline a (Just (a, cmd, b) : ops) end
      convert JPEG PPM = [proc "jpegtopnm" []]
      convert GIF PPM = [proc "giftpnm" []]
      convert PNG PPM = [proc "pngtopnm" []]
      convert PPM JPEG = [proc "cjpeg" []]
      convert PPM GIF = [proc "ppmtogif" []]
      convert PPM PNG = [proc "pnmtopng" []]
      convert PNG x = proc "pngtopnm" [] : convert PPM x
      convert GIF x = proc "giftopnm" [] : convert PPM x
      convert a b | a == b = []
      convert a b = error $ "Unknown conversion: " ++ show a ++ " -> " ++ show b
      err e = $logException $ fail $ "editImage Failure: file=" ++ show file ++ ", error=" ++ show e

pipeline :: [CreateProcess] -> P.ByteString -> IO P.ByteString
pipeline [] bytes = return bytes
pipeline (p : ps) bytes =
    (readCreateProcessWithExitCode p bytes >>= doResult)
      `catch` (\ (e :: SomeException) -> doException (showCreateProcessForUser p ++ " -> " ++ show e) e)
    where
      doResult (ExitSuccess, out, _) = pipeline ps out
      doResult (code, _, err) = let message = (showCreateProcessForUser p ++ " -> " ++ show code ++ " (" ++ show err ++ ")") in doException message (userError message)
      -- Is there any exception we should ignore here?
      doException message e = logM "Appraisal.ImageFile" ERROR message >> throw e

{-
pipelineWithExitCode :: [(String, [String])] -> B.ByteString -> IO (ExitCode, B.ByteString, [B.ByteString])
pipelineWithExitCode cmds inp =
    pipeline' cmds inp (ExitSuccess, [])
    where
      pipeline' _ bytes (code@(ExitFailure _), errs) = return (code, bytes, errs)
      pipeline' [] bytes (code, errs) = return (code, bytes, reverse errs)
      pipeline' ((cmd, args) : rest) bytes (code, errs) =
          do (code, out, err) <- readProcessWithExitCode cmd args bytes
             pipeline' rest out (code, err : errs)

showPipelineForUser :: [(String, [String])] -> String
showPipelineForUser ((cmd, args) : rest) =
    showCommandForUser cmd args ++
    case rest of 
      [] -> ""
      _ -> " | " ++ showPipelineForUser rest
-}

showCmdSpec :: CmdSpec -> String
showCmdSpec (ShellCommand s) = s
showCmdSpec (RawCommand p ss) = showCommandForUser p ss

pipe :: [CreateProcess] -> CreateProcess
pipe xs = foldl1 pipe2 xs

pipe2 :: CreateProcess -> CreateProcess -> CreateProcess
pipe2 a b =
    if cwd a == cwd b &&
       env a == env b &&
       close_fds a == close_fds b &&
       create_group a == create_group b
    then a {cmdspec = ShellCommand (showCmdSpec (cmdspec a) ++ " | " ++ showCmdSpec (cmdspec b))}
    else error $ "Pipeline of incompatible commands: " ++ showCreateProcessForUser a ++ " | " ++ showCreateProcessForUser b

pipe' :: [String] -> String
pipe' = intercalate " | "

$(makeLensesFor [("imageFile", "imageFileL")] ''ImageFile)

instance CacheFile ImageFile where
    fileSourceL = imageFileL . fileSourceL
    fileChksumL =  imageFileL . fileChksumL
    fileMessagesL = imageFileL . fileMessagesL
    fileCachePath = fileCachePath . imageFile
    fileFromFile = imageFileFromPath
    fileFromBytes = imageFileFromBytes

-- | Given a file cache monad and an opened image cache database,
-- perform an image cache action.  This is just 'runFileCache'
-- with its arguments reversed to match an older version of the
-- function.
runImageCacheIO :: forall key val m a.
                   (MonadIO m, MonadCatch m, MonadError IOException m,
                    Ord key, Show key, Show val, Typeable key, Typeable val, SafeCopy key, SafeCopy val) =>
                   FileCacheT (ReaderT (AcidState (Map key val)) m) a
                -> FileCacheTop
                -> AcidState (Map key val)
                -> m a
runImageCacheIO action fileCacheDir fileAcidState = runFileCacheIO fileAcidState fileCacheDir action

-- | Build a MonadCache instance for images on top of a MonadFileCache
-- instance and a reader for the acid state.
instance (MonadReader (AcidState ImageCacheMap) m, MonadFileCacheIO m) => MonadCache ImageKey ImageFile m where
    askAcidState = ask
    build (ImageOriginal img) = return img
    build (ImageUpright key) = do
      img <- build key
      $logException $ uprightImage img
    build (ImageScaled sz dpi key) = do
      img <- build key
      let scale = scaleFromDPI dpi sz img
      $logException $ scaleImage (fromRat (fromMaybe 1 scale)) img
    build (ImageCropped crop key) = do
      img <- build key
      $logException $ editImage crop img

class (MonadCache ImageKey ImageFile m, MonadFileCacheIO m) => MonadImageCache m

instance (MonadCache ImageKey ImageFile m, MonadFileCacheIO m) => MonadImageCache m
