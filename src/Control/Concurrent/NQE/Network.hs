{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
module Control.Concurrent.NQE.Network
    ( fromSource
    , withSource
    ) where

import           Control.Concurrent.NQE.Process
import           Data.Conduit
import           UnliftIO

fromSource ::
       (MonadIO m, Mailbox mbox)
    => ConduitT () msg m ()
    -> mbox msg -- ^ will receive all messages
    -> m ()
fromSource src mbox = runConduit $ src .| awaitForever (`send` mbox)

withSource ::
       (MonadUnliftIO m, Mailbox mbox)
    => ConduitT () msg m ()
    -> mbox msg
    -> (Async () -> m a)
    -> m a
withSource src mbox = withAsync (fromSource src mbox)
