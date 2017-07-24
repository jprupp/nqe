{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
module Control.Concurrent.NQE.Network
( NetworkError(..)
, Remote
, withNet
) where

import           Control.Concurrent.NQE.Process
import           Control.Exception.Lifted       (Exception, SomeException,
                                                 catch, fromException,
                                                 toException)
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
fromProducer src p = (src $$ awaitForever (`send` p)) `catch` e
  where
    e ex =
        case fromException ex of
            Just WrappingActionEnded -> return ()
            Just _                   -> return ()
            Nothing                  -> ProducerDied ex `kill` p

fromConsumer :: (MonadBase IO m,
                 MonadBaseControl IO m,
                 MonadIO m,
                 Typeable a)
             => Consumer a m ()
             -> Process  -- ^ kill if problem
             -> m ()
fromConsumer snk p = (dispatcher $$ snk) `catch` e
  where
    e ex =
        case fromException ex of
            Just WrappingActionEnded -> return ()
            Just _                   -> return ()
            Nothing                  -> ConsumerDied ex `kill` p
    dispatcher = dispatch [Case $ \m -> yield m >> dispatcher, Case sig]
    sig Stop {}   = return ()
    sig d@Died {} = ConsumerDied (toException d) `kill` p

withNet :: (MonadIO m,
            MonadBaseControl IO m,
            Typeable a,
            Typeable b)
        => Producer m a
        -> Consumer b m ()
        -> (Remote -> m c)  -- ^ run in this thread
        -> m c
withNet src snk f =
    myProcess >>= \me ->
        withProcess (fromProducer src me) $ \_ ->
            withProcess (fromConsumer snk me) $ \cons -> do
                ret <- f cons
                stop cons
                waitFor cons
                return ret
