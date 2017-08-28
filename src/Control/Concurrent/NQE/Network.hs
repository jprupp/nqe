{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
module Control.Concurrent.NQE.Network where
import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.NQE.Process
import           Control.Concurrent.STM
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Control
import           Data.Conduit

fromSource ::
       (MonadIO m, MonadBaseControl IO m)
    => Source m msg
    -> Mailbox msg -- ^ will receive all messages
    -> m ()
fromSource src mbox = src $$ awaitForever (atomicallyIO . writeTQueue mbox)

withSource ::
       (MonadIO m, MonadBaseControl IO m, Forall (Pure m))
    => Source m msg
    -> Mailbox msg
    -> (Async () -> m a)
    -> m a
withSource src mbox = withAsync (fromSource src mbox)
