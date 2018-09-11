{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
module Control.Concurrent.NQE.Conduit
    ( conduitMailbox
    ) where

import           Control.Concurrent.NQE.Process
import           Conduit

-- | Consumes messages and sends them to a mailbox.
conduitMailbox ::
       (MonadIO m, Mailbox mbox msg)
    => mbox msg
    -> ConduitT msg o m ()
conduitMailbox mbox = awaitForever (`send` mbox)
