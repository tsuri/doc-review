{-| Comment storage in SQLite -}
module State.SQLite
    ( new
    )
where

import Network.URI ( URI, parseRelativeReference )
import Data.Maybe ( listToMaybe, maybeToList )
import Data.List ( intercalate )
import System.IO ( hPutStrLn, stderr )
import qualified Data.Text.Encoding as E
import qualified Data.Text as T
import Database.SQLite ( openConnection
                       , SQLiteHandle
                       , execParamStatement
                       , execStatement_
                       , execParamStatement_
                       , execStatement
                       , defineTableOpt
                       )
import Control.Exception ( onException )
import qualified Database.SQLite as Q
import State.Types         ( State(..), CommentId, commentId , ChapterId
                           , chapterId, mkCommentId, Comment(..)
                           , SessionId(..), SessionInfo(..) )
import Control.Monad ( forM_, when, (<=<) )

-- |Open a new SQLite comment store
new :: FilePath -> IO State
new dbName = do
  hdl <- openConnection dbName
  checkSchema hdl
  return $ State { findComments = findComments' hdl
                 , getCounts    = getCounts' hdl
                 , addComment   = addComment' hdl
                 , addChapter   = addChapter' hdl
                 , getLastInfo  = getLastInfo' hdl
                 , getChapterComments = getChapterComments' hdl
                 , getChapterURI = getChapterURI' hdl
                 }

handleDefault :: b -> String -> Either String a -> (a -> IO b) -> IO b
handleDefault d msg (Left err) _ = do
  hPutStrLn stderr $ "Error " ++ msg ++ ": " ++ err
  return d
handleDefault _ _ (Right x) f = f x

getLastInfo' :: SQLiteHandle -> SessionId -> IO (Maybe SessionInfo)
getLastInfo' hdl sid = do
  let sql = "SELECT name, email \
            \FROM comments \
            \WHERE session_id = :session_id \
            \ORDER BY date DESC \
            \LIMIT 1"
      binder = [(":session_id", Q.Blob $ sidBS sid)]
  res <- execParamStatement hdl sql binder
  let toInfo [(_, Q.Blob n), (_, ef)] =
          SessionInfo (E.decodeUtf8 n) `fmap` loadEmail ef
      toInfo _ = []
  handleDefault Nothing "loading info" res $
                return . listToMaybe . concatMap toInfo . concat

loadEmail :: Q.Value -> [Maybe T.Text]
loadEmail Q.Null     = return Nothing
loadEmail (Q.Blob s) = return $ Just $ E.decodeUtf8 s
loadEmail _          = []

-- Load all of the comments for a given comment id
findComments' :: SQLiteHandle -> CommentId -> IO [Comment]
findComments' hdl cId = do
  let commentIdBlob = txtBlob $ commentId cId
      sql = "SELECT name, comment, email, date, session_id \
            \FROM comments WHERE comment_id = :comment_id"
      binder = [(":comment_id", commentIdBlob)]
  res <- execParamStatement hdl sql binder
  let toComment [(_, Q.Blob n), (_, Q.Blob c), (_, ef), (_, Q.Double i), (_, Q.Blob sid)] =
          do e <- loadEmail ef
             let d = realToFrac i
             [Comment (E.decodeUtf8 n) (E.decodeUtf8 c) e d (SessionId sid)]
      toComment _ = []
  handleDefault [] "loading comments" res $
                return . concatMap toComment . concat

-- Load the comment counts for the current chapter, or all counts if
-- no chapter is supplied
getCounts' :: SQLiteHandle -> Maybe ChapterId -> IO [(CommentId, Int)]
getCounts' hdl mChId = do
  res <- case mChId of
           Nothing ->
               let sql = "SELECT comment_id, COUNT(comment_id) \
                         \FROM comments GROUP BY comment_id"
               in execStatement hdl sql
           Just chId ->
               let sql = "SELECT comments.comment_id, \
                         \       COUNT(comments.comment_id) \
                         \FROM comments JOIN chapters \
                         \ON comments.comment_id == chapters.comment_id \
                         \WHERE chapters.chapter_id = :chapter_id \
                         \      AND chapters.chapter_id IS NOT NULL \
                         \GROUP BY comments.comment_id"
                   chIdBlob = txtBlob $ chapterId chId
                   binder = [(":chapter_id", chIdBlob)]
               in execParamStatement hdl sql binder

  let convertRow [(_, Q.Blob cIdBS), (_, Q.Int cnt)] =
          case mkCommentId $ E.decodeUtf8 cIdBS of
            Just cId | cnt > 0 -> [(cId, fromIntegral cnt)]
            _ -> []
      convertRow _ = []
  handleDefault [] "getting counts" res $
                return . concatMap convertRow . concat

-- Add the comment, possibly associating it with a chapter
addComment' :: SQLiteHandle -> CommentId -> Maybe ChapterId -> Comment -> IO ()
addComment' hdl cId mChId c =
    txn hdl $ do
      case mChId of
        Nothing   -> return ()
        Just chId -> insertChapterComment cId chId hdl

      insertComment cId c hdl

-- Insert a row that adds a comment for the given comment id
insertComment :: CommentId -> Comment -> SQLiteHandle -> IO ()
insertComment cId c hdl = do
  maybeErr =<< insertRowVal hdl "comments"
             [ ("comment_id", txtBlob $ commentId cId)
             , ("name", txtBlob $ cName c)
             , ("comment", txtBlob $ cComment c)
             , ("email", maybe Q.Null txtBlob $ cEmail c)
             , ("date", Q.Double $ realToFrac $ cDate c)
             , ("session_id", Q.Blob $ sidBS $ cSession c)
             ]

-- Insert a row that maps a comment id with a chapter
insertChapterComment :: CommentId -> ChapterId -> SQLiteHandle -> IO ()
insertChapterComment cId chId hdl = do
  let sql = "SELECT 1 FROM chapters \
            \WHERE chapter_id = :chId AND comment_id = :cId"
      binder = [ (":chId", txtBlob $ chapterId chId)
               , (":cId", txtBlob $ commentId cId)
               ]
  res <- execParamStatement hdl sql binder
  case (res :: Either String [[Q.Row ()]]) of
    Left err -> error err
    Right rs -> when (null $ concat rs) $
                maybeErr =<< insertRowVal hdl "chapters"
                [ ("chapter_id", txtBlob $ chapterId chId)
                , ("comment_id", txtBlob $ commentId cId)
                ]

addChapter' :: SQLiteHandle -> ChapterId -> [CommentId] -> Maybe URI -> IO ()
addChapter' hdl chId cIds mURI =
    txn hdl $ do
      forM_ cIds $ \cId -> insertChapterComment cId chId hdl
      case mURI of
        Nothing -> return ()
        Just uri ->
            do let sql = "INSERT OR REPLACE INTO \
                         \    chapter_info (chapter_id, url) \
                         \VALUES (:chId, :url)"
                   binder = [ (":chId", txtBlob $ chapterId chId)
                            , (":url", txtBlob $ T.pack $ show uri)
                            ]
               maybeErr =<< execParamStatement_ hdl sql binder

getChapterURI' :: SQLiteHandle -> ChapterId -> IO (Maybe URI)
getChapterURI' hdl chId = do
  let sql = "SELECT url FROM chapter_info WHERE chapter_id = :chId"
      binder = [(":chId", txtBlob $ chapterId chId)]
      convertRow [(_, Q.Blob u)] =
          maybeToList $ parseRelativeReference $ T.unpack $ E.decodeUtf8 u
      convertRow _ = []
  res <- execParamStatement hdl sql binder
  handleDefault Nothing "getting URI" res $
                return . listToMaybe . concatMap convertRow . concat

-- If the tables we expect are not there, add them (to deal with the
-- case that this is a new database)
--
-- This can cause problems if the schema changes, since it does not
-- actually check to see that the schema matches what we expect.
checkSchema :: SQLiteHandle -> IO ()
checkSchema hdl =
    txn hdl $ do
      mapM_ (maybeErr <=< defineTableOpt hdl True)
                [ t "comments"
                        [ tCol "comment_id"
                        , tCol "name"
                        , tCol "comment"
                        , tColN "email" []
                        , Q.Column "date" real [notNull]
                        , tCol "session_id"
                        ]
                , t "chapters" [ tCol "chapter_id"
                               , tCol "comment_id"
                               ]
                , t "chapter_info" [ tColN "chapter_id" [ notNull
                                                        , Q.PrimaryKey False
                                                        ]
                                   , tColN "url" []
                                   ]
                ]
      mapM_ (maybeErr <=< execStatement_ hdl)
                [ "CREATE INDEX IF NOT EXISTS comments_comment_id_idx \
                  \ON comments(comment_id)"
                , "CREATE INDEX IF NOT EXISTS chapters_comment_id_idx \
                  \ON chapters(comment_id)"
                , "CREATE INDEX IF NOT EXISTS chapters_chapter_id_idx \
                  \ON chapters(chapter_id)"
                , "CREATE INDEX IF NOT EXISTS comments_date_idx \
                  \ON comments(date)"
                , "CREATE INDEX IF NOT EXISTS comments_session_id \
                  \ON comments(session_id)"
                , "CREATE INDEX IF NOT EXISTS chapter_info_chapter_id \
                  \ON chapters(chapter_id)"
                ]
    where
      real = Q.SQLFloat Nothing Nothing
      tColN c cs = Q.Column c txt cs
      notNull = Q.IsNullable False
      tCol c = tColN c [notNull]
      t n cs = Q.Table n cs []
      txt = Q.SQLBlob $ Q.NormalBlob Nothing

getChapterComments' :: SQLiteHandle -> ChapterId -> IO [(CommentId, Comment)]
getChapterComments' hdl chId = do
  let sql = "SELECT comments.comment_id, name, comment, \
            \       email, date, session_id \
            \FROM comments JOIN chapters \
            \              ON comments.comment_id = chapters.comment_id \
            \WHERE chapters.chapter_id = :chapter_id \
            \ORDER BY comments.date DESC"
      binder = [(":chapter_id", txtBlob $ chapterId chId)]
  res <- execParamStatement hdl sql binder
  let toResult [ (_, Q.Blob cIdB)
               , (_, Q.Blob n)
               , (_, Q.Blob c)
               , (_, ef)
               , (_, Q.Double i)
               , (_, Q.Blob sid)
               ] = do
        e <- loadEmail ef
        cId <- maybeToList $ mkCommentId $ E.decodeUtf8 cIdB
        let d = realToFrac i
            name = E.decodeUtf8 n
            commentTxt = E.decodeUtf8 c
            sId = SessionId sid
            comment = Comment name commentTxt e d sId
        [(cId, comment)]
      toResult _ = []
  handleDefault [] "loading comments for chapter" res $
                return . concatMap toResult . concat

--------------------------------------------------
-- Helpers

-- Convert a Data.Text.Text value to a UTF-8-encoded Blob. We use
-- Blobs to avoid dealing with database encodings (the application
-- does all of the encoding and decoding)
txtBlob :: T.Text -> Q.Value
txtBlob = Q.Blob . E.encodeUtf8

-- If there is a string in the value, throw an error. Otherwise, do
-- nothing.
maybeErr :: Maybe String -> IO ()
maybeErr Nothing = return ()
maybeErr (Just e) = error e

-- Perform the supplied action inside of a database transaction
txn :: SQLiteHandle -> IO () -> IO ()
txn hdl act = do
  let execSql sql = maybeErr =<< execStatement_ hdl sql
  execSql "BEGIN"
  act `onException` (execSql "ROLLBACK" >> return ())
  execSql "COMMIT"
  return ()

-- Insert a row into a table, using type Value for the values
insertRowVal :: SQLiteHandle -> Q.TableName -> Q.Row Q.Value
             -> IO (Maybe String)
insertRowVal hdl tbl r = execParamStatement_ hdl sql row
    where
      sql = "INSERT INTO " ++ tbl ++ cols ++ " VALUES " ++ vals
      tupled l = '(':(intercalate "," l ++ ")")
      cols = tupled $ map fst r
      vals = tupled valNames
      valNames = take (length r) $
                 map (showString ":val") $
                 map show [(1::Integer)..]
      row = zip valNames $ map snd r
