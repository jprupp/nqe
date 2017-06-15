module Control.Concurrent.NQE.Network where

import           Control.Concurrent.NQE.Process
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Data.ByteString                (ByteString)
import           Data.Conduit
import           Data.Conduit.Network
import           Data.Streaming.Network
import           Data.Typeable

data HasReadWrite s => NetworkSpec i o s = NetworkSpec
    { netProvides :: String
    , netDepends :: [String]
    , netAction :: Process  -- ^ remote system
                -> IO ()
    , netConnect :: (s -> IO ()) -> IO ()
    , inConduit :: Conduit ByteString IO i
    , outConduit :: Conduit o IO ByteString
    }

data KeepAlive = KeepAlive deriving (Show, Eq, Typeable)
data Network i = Network i deriving Typeable

listener :: (HasReadWrite s, Typeable i)
         => s
         -> Conduit ByteString IO i
         -> Process
         -> ProcessSpec
listener s c p = ProcessSpec
    { provides = "listener"
    , depends = []
    , action = appSource s =$= c $$ go
    }
  where
    go = awaitForever (`send` p)

sender :: (HasReadWrite s, Typeable o)
       => s
       -> Conduit o IO ByteString
       -> ProcessSpec
sender s c = ProcessSpec
    { provides = "sender"
    , depends = []
    , action = go =$= c $$ appSink s
    }
  where
    go = receive >>= yield

netProcess :: (HasReadWrite s, Typeable i, Typeable o)
           => NetworkSpec i o s
           -> ProcessSpec
netProcess spec = ProcessSpec
    { provides = netProvides spec
    , depends = netDepends spec
    , action = do
        my <- myProcess
        netConnect spec $ \s ->
            withProcess (sender s (outConduit spec)) $ \sndr ->
                withProcess (listener s (inConduit spec) my) $ \lstnr -> do
                    link sndr
                    link lstnr
                    netAction spec sndr
    }
