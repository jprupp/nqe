{-# LANGUAGE FlexibleContexts #-}
module Control.Concurrent.NQE.Network where

import           Control.Concurrent.NQE.Process
import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.Trans.Control    (MonadBaseControl)
import           Data.ByteString                (ByteString)
import           Data.Conduit
import           Data.Conduit.Network
import           Data.Streaming.Network
import           Data.Typeable

data HasReadWrite s => NetClientSpec i o s = NetClientSpec
    { clientAction :: Process  -- ^ remote system
                   -> IO ()
    , clientConnect :: (s -> IO ()) -> IO ()
    , clientInConduit :: Conduit ByteString IO i
    , clientOutConduit :: Conduit o IO ByteString
    }

data KeepAlive = KeepAlive deriving (Show, Eq, Typeable)
data Network i = Network i deriving Typeable

listener :: (HasReadWrite s, Typeable i)
         => s
         -> Conduit ByteString IO i
         -> Process
         -> IO ()
listener s c p = appSource s =$= c $$ awaitForever (`send` p)

sender :: (HasReadWrite s, Typeable o)
       => s
       -> Conduit o IO ByteString
       -> IO ()
sender s c = (receive >>= yield) =$= c $$ appSink s

withClient :: ( HasReadWrite s
              , Typeable i
              , Typeable o
              , MonadIO m
              , MonadBaseControl IO m
              )
           => Conduit ByteString IO i   -- ^ incoming conduit
           -> Conduit o IO ByteString   -- ^ outgoing conduit
           -> ((s -> IO ()) -> IO ())   -- ^ connection wrapper
           -> String                    -- ^ process name
           -> (Process -> IO ())        -- ^ process action with net sender
           -> (Process -> m a)          -- ^ action in current thread
           -> m a
withClient i o c n f go =
    withProcess n g go
  where
    g = c h
    h s = do
        me <- myProcess
        withProcess (n ++ "-listener") (listener s i me) (j s)
    j s l = do
        link l
        withProcess (n ++ "-sender") (sender s o) k
    k d = do
        link d
        f d
