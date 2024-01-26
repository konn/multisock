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

  -- * Re-exports
  versionInfo,
) where

import Control.Applicative
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as J
import Data.Bifunctor qualified as Bi
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Generics.Labels ()
import Data.Streaming.Network (clientSettingsUnix, runUnixClient, runUnixServer, serverSettingsUnix)
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
import RIO.Time
import System.FSNotify qualified as FS

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

data AppConfig = AppConfig
  { origin :: Path Abs File
  , proxies :: [Path Abs File]
  , reconnect :: String
  }
  deriving (Generic)
  deriving anyclass (FromJSON, ToJSON)

defaultAppConfig :: AppConfig
defaultAppConfig =
  AppConfig
    { origin = [absfile|/path/to/original/sock|]
    , proxies =
        [ [absfile|/path/to/proxy1|]
        , [absfile|/another/path/to/proxy2|]
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

scheduleJobs :: AppConfig -> [Path Abs File] -> RIO AppEnv ()
scheduleJobs AppConfig {..} = mapConcurrently_ \dest -> do
  logInfo $ "Socket created: " <> fromString (fromAbsFile dest)
  withRunInIO \runInIO ->
    runUnixServer (serverSettingsUnix $ fromAbsFile dest) \childData -> do
      runInIO do
        logInfo $ "New connection: " <> fromString (fromAbsFile dest)
        there <- doesFileExist origin
        unless there do
          logWarn "No socket file found. Spawining a new one..."
          runProcess_ $ fromString reconnect

      runUnixClient (clientSettingsUnix $ fromAbsFile origin) \superData -> runInIO do
        let upstream =
              fromAppData superData & putAppData childData
            downstream =
              fromAppData childData & putAppData superData
        upstream `race_` downstream
