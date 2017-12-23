{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
module Control.Concurrent.NQE.Network
    ( fromSource
    , withSource
    ) where

import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.NQE.Process
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Control
import           Data.Conduit

fromSource ::
       (MonadIO m, Mailbox mbox)
    => Source m msg
    -> mbox msg -- ^ will receive all messages
    -> m ()
fromSource src mbox = src $$ awaitForever (`send` mbox)

withSource ::
       (MonadIO m, MonadBaseControl IO m, Forall (Pure m), Mailbox mbox)
    => Source m msg
    -> mbox msg
    -> (Async () -> m a)
    -> m a
withSource src mbox = withAsync (fromSource src mbox)
