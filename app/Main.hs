{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import Network.Socket.Multiplex (defaultMain, versionInfo)

main :: IO ()
main = defaultMain $$(versionInfo "multisock")
