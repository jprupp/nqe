module Control.Concurrent.NQE.Network
    ( fromSource
    , withSource
    ) where

import           Control.Concurrent.Async
import           Control.Concurrent.NQE.Process
import           Control.Monad.IO.Class         (liftIO)
import           Data.Conduit

fromSource ::
       Mailbox mbox
    => Source IO msg
    -> mbox msg -- ^ will receive all messages
    -> IO ()
fromSource src mbox = src $$ awaitForever (\msg -> liftIO $ msg `send` mbox)

withSource ::
       Mailbox mbox => Source IO msg -> mbox msg -> (Async () -> IO a) -> IO a
withSource src mbox = withAsync (fromSource src mbox)
