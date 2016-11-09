{-# LANGUAGE GADTs             #-}
{-# LANGUAGE OverloadedStrings #-}
-- | A MySQL backend for @persistent@ using @mysql-haskell@ driver.
module Database.Persist.MySQL where

import Control.Monad (void)
import           Control.Monad.IO.Class
import           Data.Acquire                        (Acquire, mkAcquire, with)
import qualified Data.ByteString.Lazy                as ByteString
import           Data.Conduit
import           Data.Int                            (Int64)
import           Data.IORef
import qualified Data.Map                            as Map
import           Data.Text                           (Text)
import qualified Data.Text                           as Text
import qualified Data.Text.Encoding                  as Text
import           Database.MySQL.Base                 (MySQLConn,
                                                      MySQLValue (..))
import qualified Database.MySQL.Base                 as MySQL
import           Database.Persist.Sql                hiding (toPersistValue)
import           Database.Persist.Sql.Types.Internal (mkPersistBackend)
import           System.IO.Streams                   (InputStream)
import qualified System.IO.Streams                   as Streams

-- | Internal function that opens a connection to the MySQL
-- server.
open :: (IsSqlBackend backend) => MySQL.ConnectInfo -> LogFunc -> IO backend
open connectInfo logger = do
  conn    <- MySQL.connect connectInfo
  stmtMap <- newIORef Map.empty
  return $ mkPersistBackend SqlBackend {
      connPrepare       = prepare conn
    , connStmtMap       = stmtMap
    , connInsertSql     = insertSql conn
    , connInsertManySql = Nothing
    , connUpsertSql     = Nothing
    , connClose         = MySQL.close conn
    , connMigrateSql    = migrateMysql connectInfo
    , connBegin         = beginTransaction conn
    , connCommit        = commitTransaction conn
    , connRollback      = rollbackTransaction conn
    , connEscapeName    = escapeName
    -- This noLimit is suggested by MySQL's own docs, see
    -- <http://dev.mysql.com/doc/refman/5.5/en/select.html>
    , connNoLimit       = "LIMIT 18446744073709551615"
    , connRDBMS         = "mysql"
    , connLimitOffset   = decorateSQLWithLimitOffset "LIMIT 18446744073709551615"
    , connLogFunc       = logger
    }

-- | Escape a database name to be included on a query.
escapeName :: DBName -> Text
escapeName (DBName name) = Text.pack . escape . Text.unpack $ name
  where
    escape :: String -> String
    escape s = '`' : go s
      where
        go ('`':xs) = '`' : '`' : go xs
        go ( x :xs) =     x     : go xs
        go ""       = "`"

-- | Prepare a query.
prepare :: MySQLConn -> Text -> IO Statement
prepare conn = \qry -> do
  let
    mkQuery :: Text -> MySQL.Query
    mkQuery q = MySQL.Query
                $ ByteString.fromStrict
                $ Text.encodeUtf8 q

  stmt <- MySQL.prepareStmt conn (mkQuery qry)

  let
    close :: IO ()
    close = MySQL.closeStmt conn stmt

    reset :: IO ()
    reset = MySQL.resetStmt conn stmt

    execute :: [PersistValue] -> IO Int64
    execute values = do
      ok <- MySQL.executeStmt conn stmt (map toMySQLValue values)
      return $ fromIntegral (MySQL.okAffectedRows ok)

    fetch :: [MySQLValue] -> IO (InputStream [MySQLValue])
    fetch values = snd <$> MySQL.queryStmt conn stmt values

    query :: MonadIO m => [PersistValue] -> Acquire (Source m [PersistValue])
    query values = do
      resultSet <- mkAcquire (fetch (map toMySQLValue values)) (\_ -> close)

      let
        producer :: MonadIO m
                 => InputStream [MySQLValue]
                 -> Source m [PersistValue]
        producer seed = loop
          where loop = do
                  ma <- liftIO (Streams.read seed)
                  case ma of
                    Just a  -> yield (map toPersistValue a) *> loop
                    Nothing -> return ()

      return (producer resultSet)

  return Statement {
      stmtFinalize = close
    , stmtReset    = reset
    , stmtExecute  = execute
    , stmtQuery    = query
    }

beginTransaction :: MySQLConn -> (Text -> IO Statement) -> IO ()
beginTransaction conn _ = void $ MySQL.execute_ conn "BEGIN"

commitTransaction :: MySQLConn -> (Text -> IO Statement) -> IO ()
commitTransaction conn _ = void $ MySQL.execute_ conn "COMMIT"

rollbackTransaction :: MySQLConn -> (Text -> IO Statement) -> IO ()
rollbackTransaction conn _ = void $ MySQL.execute_ conn "ROLLBACK"

-- | SQL code to be executed when inserting an entity.
insertSql :: MySQLConn -> EntityDef -> [PersistValue] -> InsertSqlResult
insertSql conn entityDef values =
  let
    sql :: Text
    sql = Text.concat [ "INSERT INTO "
                      , escapeName (entityDB entityDef)
                      , "("
                      , Text.intercalate "," $ map (escapeName . fieldDB) (entityFields entityDef)
                      , ") VALUES ("
                      , Text.intercalate "," $ map (const "?") (entityFields entityDef)
                      , ")"
                      ]
  in case entityPrimary entityDef of
       Just _  -> ISRManyKeys sql values
       Nothing -> ISRInsertGet sql "SELECT LAST_INSERT_ID()"

insertManySql :: MySQLConn -> EntityDef -> [[PersistValue]] -> InsertSqlResult
insertManySql conn entityDef values = undefined

migrateMysql = undefined

toMySQLValue :: PersistValue -> MySQLValue
toMySQLValue v =
  case v of
    PersistText t       -> MySQLText t
    PersistByteString b -> MySQLBytes b
    PersistInt64 i      -> MySQLInt64 i
    PersistDouble d     -> MySQLDouble d
    PersistRational r   -> undefined -- TODO: fixme
    PersistBool b       -> MySQLInt8U (if b then 1 else 0)
    PersistDay d        -> MySQLDate d
    PersistTimeOfDay t  -> MySQLTime 0 t
    PersistUTCTime u    -> undefined
    PersistNull         -> MySQLNull
    PersistList l       -> MySQLText (listToJSON l)
    PersistMap m        -> MySQLText (mapToJSON m)
    PersistDbSpecific s -> MySQLBytes s
    PersistObjectId _   -> error "Refusing to serialize a PersistObjectId to a MySQL value"

toPersistValue :: MySQLValue -> PersistValue
toPersistValue v =
  case v of
    MySQLDecimal d   -> undefined
    MySQLInt8U i     -> PersistInt64 (fromIntegral i)
    MySQLInt8 i      -> PersistInt64 (fromIntegral i)
    MySQLInt16U i    -> PersistInt64 (fromIntegral i)
    MySQLInt32U i    -> PersistInt64 (fromIntegral i)
    MySQLInt32 i     -> PersistInt64 (fromIntegral i)
    MySQLInt64U i    -> PersistInt64 (fromIntegral i)
    MySQLInt64 i     -> PersistInt64 (fromIntegral i)
    MySQLFloat f     -> PersistDouble (realToFrac f)
    MySQLDouble d    -> PersistDouble d
    MySQLYear y      -> undefined
    MySQLDateTime d  -> undefined
    MySQLTimeStamp t -> undefined
    MySQLDate d      -> PersistDay d
    MySQLTime _s t   -> PersistTimeOfDay t
    MySQLGeometry b  -> PersistDbSpecific b
    MySQLBytes b     -> PersistByteString b
    MySQLBit w       -> PersistInt64 (fromIntegral w)
    MySQLText t      -> PersistText t
    MySQLNull        -> PersistNull
