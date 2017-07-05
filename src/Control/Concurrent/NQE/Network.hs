{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
module Control.Concurrent.NQE.Network where

import           Control.Concurrent.Lifted      (fork, killThread)
import           Control.Concurrent.NQE.Process
import           Control.Exception.Lifted       (AsyncException (..), Exception,
                                                 SomeException, bracket, catch,
                                                 fromException)
import           Control.Monad                  (forever)
import           Control.Monad.Base             (MonadBase)
import           Control.Monad.IO.Class         (MonadIO)
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
fromProducer src p =
    go `catch` e
  where
    go = src $$ awaitForever (`send` p)
    e ex = case fromException (ex :: SomeException) of
        Just ThreadKilled -> return ()  -- gracefully die
        _                 -> ProducerDied ex `kill` p

fromConsumer :: (MonadBase IO m,
                 MonadBaseControl IO m,
                 MonadIO m,
                 Typeable a)
             => Consumer a m ()
             -> Process  -- ^ stop when done
             -> m ()
fromConsumer snk p =
    go `catch` e
  where
    go = forever (receive >>= yield) $$ snk
    e ex = case fromException (ex :: SomeException) of
        Just Stop -> return ()  -- gracefully die
        _         -> ConsumerDied ex `kill` p

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
    bracket (fork $ fromProducer src me) killThread $ const $
        withProcess (fromConsumer snk me) f
