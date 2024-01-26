{-# LANGUAGE GHC2021 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE NoFieldSelectors #-}

module Network.Socket.Multiplex.VersionInfo (
  VersionInfo (..),
  versionInfo,
  CompilerInfo (..),
  defaultCompilerInfo,
  formatCompiler,
) where

import Data.Aeson (FromJSON, ToJSON (..), object, (.=))
import Data.Version
import GHC.Generics (Generic)
import GitHash
import Language.Haskell.TH
import Language.Haskell.TH.Syntax (liftData, liftTyped)
import Paths_multisock qualified as Pkg (version)
import RIO.Time
import System.Info qualified as Info

data CompilerInfo = CompilerInfo {compiler :: String, version :: Version, os :: String, arch :: String}
  deriving (Show, Eq, Ord, Generic)
  deriving anyclass (FromJSON, ToJSON)

data VersionInfo = VersionInfo
  { appName :: String
  , version :: Version
  , commit :: GitInfo
  , compilerInfo :: CompilerInfo
  , builtAt :: ZonedTime
  }
  deriving (Show, Generic)

instance ToJSON VersionInfo where
  toJSON VersionInfo {..} =
    object
      [ "appName" .= appName
      , "version" .= showVersion version
      , "commit" .= giHash commit
      , "compilerInfo" .= compilerInfo
      , "builtAt" .= builtAt
      ]

versionInfo :: String -> CodeQ VersionInfo
versionInfo appName =
  [||
  VersionInfo
    $$(liftTyped appName)
    Pkg.version
    $$tGitInfoCwd
    defaultCompilerInfo
    $$(unsafeCodeCoerce $ liftData =<< runIO getZonedTime)
  ||]

defaultCompilerInfo :: CompilerInfo
defaultCompilerInfo =
  CompilerInfo
    { compiler = Info.compilerName
    , version = Info.fullCompilerVersion
    , os = Info.os
    , arch = Info.arch
    }

formatCompiler :: CompilerInfo -> String
formatCompiler CompilerInfo {..} = compiler <> "-" <> showVersion version <> "-" <> os <> "-" <> arch
