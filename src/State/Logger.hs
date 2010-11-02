{-|
  Module that logs all state actions to a file so that they could
  theoretically be reconstructed.
 -}
module State.Logger
    ( wrap
    , replay
    , foldLogFile
    , foldLogFile_
    , foldComments
    , foldMapComments
    )
where

import Control.Monad ( (<=<), forever )
import System.IO.Error ( try )
import System.IO ( stderr, openBinaryFile, hPutStrLn, hClose
                 , IOMode(AppendMode, ReadMode), Handle, withBinaryFile )
import Data.ByteString.Lazy as B
import Data.Binary.Get ( runGetState )
import Data.Binary ( Binary(..), getWord8, putWord8, encode )
import Control.Applicative ( (<$>), (<*>) )
import Control.Concurrent.MVar ( MVar, newMVar, modifyMVar )
import Control.Concurrent ( forkIO, threadDelay )
import Data.Monoid ( mempty, mappend, Monoid )

import State.Types

data Action = AddComment CommentId (Maybe ChapterId) Comment
            | AddChapter ChapterId [CommentId]
              deriving (Eq, Show)

instance Binary Action where
    get = do
      ty <- getWord8
      case ty of
        0xfe -> AddComment <$> get <*> get <*> get
        0xff -> AddChapter <$> get <*> get
        _    -> error $ "Bad type code: " ++ show ty

    put (AddComment cId mChId c) =
        do putWord8 0xfe
           put cId
           put mChId
           put c
    put (AddChapter chId cs) =
        do putWord8 0xff
           put chId
           put cs

-- Attempt to replay a log file, skipping corrupted sections of the file
foldLogFile :: Binary act => (act -> a -> IO a) -> a -> FilePath -> IO a
foldLogFile playOne initial logFileName =
    withBinaryFile logFileName ReadMode $ go initial <=< B.hGetContents
    where
      go x bs | B.null bs = return x
      go x bs = uncurry go =<< (step x bs `catch` \_ -> return (x, B.drop 1 bs))

      step x bs = do
        let (act, bs', _) = runGetState get bs 0
        x' <- playOne act x
        return (x', bs')

foldLogFile_ :: Binary act => (act -> IO ()) -> FilePath -> IO ()
foldLogFile_ f = foldLogFile (const . f) ()

replay :: State -> FilePath -> IO ()
replay st =
    foldLogFile_ $ \act ->
    case act of
      AddComment cId mChId c -> addComment st cId mChId c
      AddChapter chId cs     -> addChapter st chId cs

-- | Strict fold over the comments in the log file
foldComments :: (CommentId -> Maybe ChapterId -> Comment -> b -> b) -> b
             -> FilePath -> IO b
foldComments f =
    foldLogFile $ \act ->
    case act of
      AddChapter _ _         -> return
      AddComment cId mChId c -> \x -> let x' = f cId mChId c x
                                      in  x' `seq` return x'

foldMapComments :: Monoid b => (CommentId -> Maybe ChapterId -> Comment -> b)
                -> FilePath -> IO b
foldMapComments f =
    foldComments (\cId mChId c -> (f cId mChId c `mappend`)) mempty

-- |Wrap a store so that all of its modifying operations are logged to
-- a file. The file can later be replayed to restore the state.
wrap :: FilePath -> State -> IO State
wrap logFileName st = do
  ref <- newMVar Nothing
  forkIO $ rotateLog ref
  return st { addComment = \cId mChId c -> do
                             writeLog logFileName ref $ AddComment cId mChId c
                             addComment st cId mChId c

            , addChapter = \chId cs -> do
                             writeLog logFileName ref $ AddChapter chId cs
                             addChapter st chId cs
            }

-- |Attempt to close the log file every five minutes so that we can
-- open new files and make sure that the entries are being written to
-- a mapped disk file
rotateLog :: MVar (Maybe Handle) -> IO ()
rotateLog v = forever $ do
                modifyMVar v $ \mh -> do
                          hPutStrLn stderr "Rotating"
                          maybe (return ()) closeLog mh
                          return (Nothing, ())

                -- reopen the log file every five minutes
                threadDelay $ 1000000 * 600

    where
      closeLog h = hClose h `catch` putErr "Failed to close log handle"

-- Write any errors to stderr so that we have a record of them
-- somewhere
putErr :: String -> IOError -> IO ()
putErr msg e = hPutStrLn stderr $ msg ++ ": " ++ show e

-- |Write a log entry to a file, opening the file for append if
-- necessary
writeLog :: FilePath -> MVar (Maybe Handle) -> Action -> IO ()
writeLog fn v act =
    modifyMVar v $ \mh -> do
      mh' <- getHandle mh >>= writeEntry
      return (mh', ())

    where
      -- If we don't have a handle, try to open one
      getHandle (Just h) = return $ Just h
      getHandle Nothing  = do
        res <- try $ openBinaryFile fn AppendMode
        case res of
          Right h -> return $ Just h
          Left e  -> do putErr "Failed to open log file" e
                        return Nothing

      -- Try to write the log entry, but don't raise an exception if
      -- we can't, so that we have the best chance of actually saving
      -- the data
      writeEntry Nothing  = return Nothing
      writeEntry (Just h) = do
        res <- try $ B.hPut h (encode act)
        case res of
          Right () -> return $ Just h
          Left e   -> do putErr "Failed to write log entry" e
                         hClose h `catch` putErr "Failed to close log file"
                         return Nothing
