{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
module Control.Concurrent.NQE.Network where

import           Control.Concurrent.Lifted      (fork, killThread)
import           Control.Concurrent.NQE.Process
import           Control.Exception.Lifted       (bracket)
import           Control.Monad                  (forever)
import           Control.Monad.Base             (MonadBase)
import           Control.Monad.IO.Class         (MonadIO)
import           Control.Monad.Trans.Control    (MonadBaseControl)
import           Data.Conduit                   (Consumer, Producer,
                                                 awaitForever, yield, ($$))
import           Data.Typeable                  (Typeable)

type Remote = Process

fromProducer :: (MonadIO m, Typeable a)
             => Producer m a
             -> Process  -- ^ will receive all messages
             -> m ()
fromProducer src p = src $$ awaitForever (`send` p)

fromConsumer :: (MonadBase IO m, MonadIO m, Typeable a)
             => Consumer a m b
             -> m b
fromConsumer snk = forever (receive >>= yield) $$ snk

withNet :: (MonadIO m, MonadBaseControl IO m, Typeable a, Typeable b)
        => Producer m a
        -> Consumer b m ()
        -> (Remote -> m c)  -- ^ run in this thread
        -> m c
withNet src snk f = do
    me <- myProcess
    bracket (fork $ fromProducer src me) killThread $ const $
        withProcess (fromConsumer snk) f
