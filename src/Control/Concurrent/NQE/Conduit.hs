{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
module Control.Concurrent.NQE.Conduit where

import           Conduit
import           Control.Concurrent.NQE.Process
import           Data.Typeable

-- | Consumes messages from a 'Conduit' and sends them to a mailbox.
conduitMailbox ::
       (MonadIO m, OutChan mbox, Typeable msg)
    => mbox
    -> ConduitT msg o m ()
conduitMailbox mbox = awaitForever (`send` mbox)
