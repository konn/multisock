module Network.Socket.Streaming (putAppData, fromAppData) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteString as BS
import Data.Streaming.Network (HasReadWrite, appRead, appWrite)
import qualified Streaming.ByteString as Q

putAppData :: (MonadIO m, HasReadWrite a) => a -> Q.ByteStream m b -> m b
putAppData unix = Q.chunkMapM_ (liftIO . appWrite unix)

fromAppData :: (MonadIO m, HasReadWrite a) => a -> Q.ByteStream m ()
fromAppData unix = go
  where
    go = do
      bs <- liftIO $ appRead unix
      if BS.null bs
        then pure ()
        else Q.chunk bs >> go
