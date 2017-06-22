{-# LANGUAGE FlexibleContexts #-}
module Control.Concurrent.NQE.Network where

import           Control.Concurrent.NQE.Process
import           Control.Monad.IO.Class         (liftIO)
import           Data.ByteString                (ByteString)
import           Data.Conduit                   (Conduit (..), awaitForever,
                                                 yield, ($$), (=$=))
import           Data.Conduit.Network           (AppData, appSink, appSource)
import           Data.Typeable                  (Typeable)

listener :: Typeable i
         => AppData
         -> Conduit ByteString IO i
         -> Process
         -> IO ()
listener ad c p =
    appSource ad =$= c $$ awaitForever (\x -> liftIO $ send x p)

sender :: Typeable o
       => AppData
       -> Conduit o IO ByteString
       -> IO ()
sender ad c = (liftIO receive >>= yield) =$= c $$ appSink ad

withNet :: (Typeable i, Typeable o)
        => Conduit ByteString IO i  -- ^ incoming conduit
        -> Conduit o IO ByteString  -- ^ outgoing conduit
        -> AppData
        -> (Process -> IO a)
        -> IO a
withNet i o ad go =
    myProcess >>= \me ->
    withProcess (listener ad i me) $ \_ ->
    withProcess (sender ad o) go
