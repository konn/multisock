{-# LANGUAGE GHC2021 #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoFieldSelectors #-}

module Network.Socket.Multiplex (
  defaultMain,
  AppOpts (..),
  defaultMainWith,
  appOptsP,
  AppConfig (..),
  defaultAppConfig,
  SocketLocation (..),

  -- * Re-exports
  versionInfo,
) where

import Control.Applicative
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as J
import Data.Bifunctor qualified as Bi
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Generics.Labels ()
import Data.Streaming.Network (AppData, AppDataUnix, HasReadWrite, HostPreference, clientSettingsTCP, clientSettingsUnix, runTCPClient, runTCPServer, runUnixClient, runUnixServer, serverSettingsTCP, serverSettingsUnix)
import Data.Version (showVersion)
import Data.Yaml qualified as Y
import GitHash (giDescribe)
import Network.Socket.Multiplex.VersionInfo
import Network.Socket.Streaming (fromAppData, putAppData)
import Options.Applicative qualified as Opts
import Path
import Path.IO (XdgDirectory (..), createDirIfMissing, doesFileExist, getXdgDir, makeAbsolute)
import RIO
import RIO.FilePath (takeFileName)
import RIO.Process (HasProcessContext (processContextL), ProcessContext, mkDefaultProcessContext, runProcess_)
import RIO.Text qualified as T
import RIO.Text.Partial qualified as T
import RIO.Time
import System.FSNotify qualified as FS
import Text.Read (readEither)

newtype AppOpts = AppOpts {config :: SomeBase File}
  deriving (Show, Eq, Ord, Generic)

appOptsP :: VersionInfo -> Path Abs File -> Opts.ParserInfo AppOpts
appOptsP vi@VersionInfo {..} defCfgFile =
  Opts.info (p <**> jsonVersioner <**> numericVersioner <**> versioner <**> Opts.helper) $ Opts.progDesc "Multiplexing Unix Socket File to a port"
  where
    jsonVersioner =
      Opts.infoOption
        (LBS8.unpack $ J.encode vi)
        (Opts.long "build-info" <> Opts.help "Show version and build info in JSON format and quit")
    numericVersioner =
      Opts.infoOption
        (showVersion version)
        (Opts.long "numeric-version" <> Opts.help "Show numeric version and quit")
    versioner =
      Opts.infoOption
        ( appName
            <> ", version "
            <> showVersion version
            <> " (commit: "
            <> giDescribe commit
            <> ", built at: "
            <> formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S%z" builtAt
            <> ", compiler: "
            <> formatCompiler compilerInfo
            <> ")"
        )
        (Opts.long "version" <> Opts.short 'V' <> Opts.help "Show version and quit")
    p = do
      config <-
        Opts.option (Opts.eitherReader $ Bi.first displayException . parseSomeFile) $
          Opts.short 'c'
            <> Opts.long "config"
            <> Opts.metavar "PATH"
            <> Opts.help "Path to the config file"
            <> Opts.value (Abs defCfgFile)
            <> Opts.showDefault
      pure AppOpts {..}

defaultMain :: VersionInfo -> IO ()
defaultMain vinfo = do
  cfg <- getXdgDir XdgConfig Nothing
  defaultMainWith =<< Opts.execParser (appOptsP vinfo $ cfg </> [relfile|multisock.yml|])

data SocketLocation
  = UnixSocket !(Path Abs File)
  | TCPSocket !HostPreference !Int
  deriving (Eq, Ord, Generic)

instance Show SocketLocation where
  showsPrec _ (UnixSocket p) = showString $ fromAbsFile p
  showsPrec _ (TCPSocket h p) = showString $ show h <> ":" <> show p

instance ToJSON SocketLocation where
  toJSON = \case
    UnixSocket path -> J.toJSON $ fromAbsFile path
    TCPSocket host port -> J.toJSON (show host <> ":" <> show port)

instance FromJSON SocketLocation where
  parseJSON = J.withText "absolute path or HOST:PORT" \text ->
    UnixSocket <$> either (fail . displayException) pure (parseAbsFile (T.unpack text))
      <|> do
        [host, port] <- pure $ T.splitOn ":" text
        p <- either fail pure $ readEither $ T.unpack port
        pure $ TCPSocket (fromString $ T.unpack host) p

data AppConfig = AppConfig
  { origin :: SocketLocation
  , proxies :: [SocketLocation]
  , reconnect :: String
  }
  deriving (Generic)
  deriving anyclass (FromJSON, ToJSON)

defaultAppConfig :: AppConfig
defaultAppConfig =
  AppConfig
    { origin = UnixSocket [absfile|/path/to/original/sock|]
    , proxies =
        [ UnixSocket [absfile|/path/to/proxy1|]
        , UnixSocket [absfile|/another/path/to/proxy2|]
        ]
    , reconnect = "gpg-connect-agent reloadagent /bye"
    }

data AppEnv = AppEnv
  { procCtx :: ProcessContext
  , configPath :: Path Abs File
  , logFunc :: LogFunc
  , config :: TMVar AppConfig
  }
  deriving (Generic)

instance HasLogFunc AppEnv where
  logFuncL = #logFunc

instance HasProcessContext AppEnv where
  processContextL = #procCtx

{- HLint ignore "Functor law" -}

defaultMainWith :: AppOpts -> IO ()
defaultMainWith options = do
  logOpts <-
    logOptionsHandle stderr True
      <&> setLogUseLoc False
      <&> setLogVerboseFormat True
  configPath <- makeAbsolute options.config

  withLogFunc logOpts \logFunc -> runRIO logFunc do
    logInfo $ "Reading config from: " <> fromString (fromAbsFile configPath)
    there <- doesFileExist configPath
    config <-
      newTMVarIO
        =<< if there
          then liftIO $ Y.decodeFileThrow $ fromAbsFile configPath
          else do
            logWarn $
              "Config file not found: "
                <> fromString (fromAbsFile configPath)
                <> "; Creating a new one..."
            createDirIfMissing True $ parent configPath
            liftIO $ Y.encodeFile (fromAbsFile configPath) defaultAppConfig
            pure defaultAppConfig
    procCtx <- mkDefaultProcessContext
    runRIO AppEnv {..} relay

data ParentState = Absent | Present
  deriving (Show, Eq, Ord, Generic)

relay :: RIO AppEnv ()
relay = do
  cfg0 <- atomically . takeTMVar =<< view #config
  withRunInIO \runInIO -> FS.withManager \man -> do
    cfgPath <- runInIO $ view #configPath
    cancelWatch <-
      FS.watchDir
        man
        (fromAbsDir $ parent cfgPath)
        ((== fromRelFile (filename cfgPath)) . takeFileName . FS.eventPath)
        $ runInIO . \case
          FS.Added {} -> updated
          FS.Modified {} -> updated
          FS.Removed {} -> do
            logWarn $ "Config file removed: " <> fromString (fromAbsFile cfgPath)
          evt -> logInfo $ "Unknown event: " <> displayShow evt
    runInIO $ body cfg0 `finally` liftIO cancelWatch
  where
    updated = do
      cfgPath <- view #configPath
      logInfo $ "Config file updated: " <> fromString (fromAbsFile cfgPath)
      cfg <- liftIO $ Y.decodeFileThrow $ fromAbsFile cfgPath
      cfgVar <- view #config
      atomically $ putTMVar cfgVar cfg
    body cfg@AppConfig {..} = do
      cfgVar <- view #config
      jobs <- async $ scheduleJobs cfg proxies
      body =<< atomically (takeTMVar cfgVar) `finally` cancel jobs

scheduleJobs :: AppConfig -> [SocketLocation] -> RIO AppEnv ()
scheduleJobs AppConfig {..} = mapConcurrently_ \dest -> do
  logInfo $ "Socket created: " <> fromString (show dest)
  runServer dest \childData -> do
    logInfo $ "New connection: " <> fromString (show dest)
    there <- isAlive origin
    unless there $ fix \self -> do
      logWarn "No socket file found. Spawining a new one..."
      eith <- tryAny $ runProcess_ $ fromString reconnect
      case eith of
        Right () -> pure ()
        Left err -> do
          logError "Spawning failed! Retrying after 1 sec..."
          logError $ fromString $ displayException err
          threadDelay $ 10 ^ (6 :: Int)
          self

    runClient origin \superData -> do
      let upstream =
            fromAppData superData & putAppData childData
          downstream =
            fromAppData childData & putAppData superData
      upstream `race_` downstream

isAlive :: SocketLocation -> RIO AppEnv Bool
isAlive (UnixSocket dest) = doesFileExist dest
isAlive TCPSocket {} = pure True

runServer :: SocketLocation -> (forall appData. (HasReadWrite appData) => appData -> RIO env ()) -> RIO env ()
runServer (UnixSocket dest) act =
  withRunInIO \runInIO ->
    runUnixServer (serverSettingsUnix $ fromAbsFile dest) $
      runInIO . act @AppDataUnix
runServer (TCPSocket host p) act =
  withRunInIO \runInIO ->
    runTCPServer (serverSettingsTCP p host) $ runInIO . act @AppData

runClient ::
  (HasLogFunc env) =>
  SocketLocation ->
  (forall appData. (HasReadWrite appData) => appData -> RIO env ()) ->
  RIO env ()
runClient (UnixSocket dest) act =
  withRunInIO \runInIO ->
    runUnixClient (clientSettingsUnix $ fromAbsFile dest) $ runInIO . act @AppDataUnix
runClient (TCPSocket host p) act = fix \self ->
  withRunInIO \runInIO ->
    runTCPClient (clientSettingsTCP p $ BS8.pack $ show host) (runInIO . act @AppData)
      `catch` \(err :: IOException) -> runInIO do
        logError "Spawning failed! Retrying after 1 sec..."
        logError $ fromString $ displayException err
        threadDelay $ 10 ^ (6 :: Int)
        self
