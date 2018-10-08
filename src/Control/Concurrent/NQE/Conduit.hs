{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-|
Module      : Control.Concurrent.NQE.Conduit
Copyright   : No rights reserved
License     : UNLICENSE
Maintainer  : xenog@protonmail.com
Stability   : experimental
Portability : POSIX

Mix NQE processes with conduits for easy concurrent IO.
-}
module Control.Concurrent.NQE.Conduit where

import           Conduit
import           Control.Concurrent.NQE.Process
import           Data.Typeable

-- | Consumes messages from a 'Conduit' and sends them to a channel.
conduitMailbox ::
       (MonadIO m, OutChan mbox, Typeable msg)
    => mbox msg
    -> ConduitT msg o m ()
conduitMailbox mbox = awaitForever (`send` mbox)
