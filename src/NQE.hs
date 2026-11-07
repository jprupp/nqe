{-|
Module      : NQE
Copyright   : Haskoin Developers
License     : MIT
Maintainer  : jprupp@protonmail.ch
Stability   : experimental
Portability : POSIX

Concurrency library inspired by Erlang/OTP.

NQE helps you build programs out of many small threads that each own their
state and talk by passing messages, instead of threads that share mutable
state. It adds a few well-known patterns on top of 'STM' and @async@:
mailboxes, request and reply, supervision and publish/subscribe. Each module
explains why it works the way it does.

This module re-exports everything in the library:

* "Control.Concurrent.NQE.Process": processes, inboxes, mailboxes and
  synchronous queries.
* "Control.Concurrent.NQE.Supervisor": supervisors that start, monitor and stop
  child threads.
* "Control.Concurrent.NQE.Publisher": a process that broadcasts messages to any
  number of subscribers.
* "Control.Concurrent.NQE.Conduit": glue to feed a 'Data.Conduit.ConduitT'
  stream into a mailbox.
-}
module NQE
    ( -- * Processes and Mailboxes
      module Process
      -- * Process Supervisors
    , module Supervisor
      -- * Publisher and Subscribers
    , module Publisher
      -- * Conduit Integration
    , module Conduit
    ) where

import           Control.Concurrent.NQE.Conduit    as Conduit
import           Control.Concurrent.NQE.Process    as Process
import           Control.Concurrent.NQE.Publisher  as Publisher
import           Control.Concurrent.NQE.Supervisor as Supervisor
