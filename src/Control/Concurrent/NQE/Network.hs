{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
module Control.Concurrent.NQE.Network where

import           Control.Concurrent.NQE.Process
import           Control.Concurrent.STM         (check, isEmptyTQueue)
import           Control.Exception.Lifted       (Exception, SomeException,
                                                 catch, finally)
import           Control.Monad                  (forever, (<=<))
import           Control.Monad.Base             (MonadBase)
import           Control.Monad.IO.Class         (MonadIO, liftIO)
import           Control.Monad.Trans.Control    (MonadBaseControl)
import           Data.Conduit                   (Consumer, Producer,
                                                 awaitForever, yield, ($$))
import           Data.Typeable                  (Typeable)

type Remote = Process

data NetworkError
    = ProducerDied SomeException
    | ConsumerDied SomeException
    deriving (Show, Typeable)

instance Exception NetworkError

fromProducer :: (MonadIO m,
                 MonadBaseControl IO m,
                 Typeable a)
             => Producer m a
             -> Process  -- ^ will receive all messages
             -> m ()
fromProducer src p = src $$ awaitForever (`send` p)

fromConsumer :: (MonadBase IO m,
                 MonadBaseControl IO m,
                 MonadIO m,
                 Typeable a)
             => Consumer a m ()
             -> m ()
fromConsumer snk = forever (receive >>= yield) $$ snk

flush :: MonadIO m => Process -> m ()
flush p = atomically $ check =<< mailboxEmptySTM p

withNet :: (MonadIO m,
            MonadBaseControl IO m,
            Typeable a,
            Typeable b)
        => Producer m a
        -> Consumer b m ()
        -> (Remote -> m c)  -- ^ run in this thread
        -> m c
withNet src snk f = do
    me <- myProcess
    withProcess (fromProducer src me) $ \prod -> do
        link prod
        withProcess (fromConsumer snk) $ \cons -> do
            link cons
            ret <- f cons
            flush cons
            return ret
