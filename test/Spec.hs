{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Conduit
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
  ( AsyncCancelled (..),
    ExceptionInLinkedThread (..),
    cancel,
  )
import Control.Concurrent.STM (atomically, check)
import Control.Exception
import Control.Monad
import NQE
import Test.Hspec

data Pong = Pong deriving (Eq, Show)

newtype Ping = Ping (Listen Pong)

data TestError
  = TestError1
  | TestError2
  deriving (Show, Eq)

instance Exception TestError

testError :: Selector TestError
testError = const True

testError1 :: Selector TestError
testError1 e = e == TestError1

threadError :: (Exception e) => Selector e -> Selector ExceptionInLinkedThread
threadError e (ExceptionInLinkedThread _ s) = maybe False e (fromException s)

notifError :: (Exception e) => Selector e -> Selector (Maybe SomeException)
notifError e s = maybe False e (s >>= fromException)

-- A child that died of an asynchronous exception, as its supervisor reports it.
asyncChildError :: (Exception e) => Selector e -> Selector AsyncChildException
asyncChildError e (AsyncChildException s) = maybe False e (fromException s)

pongServer :: Inbox Ping -> IO ()
pongServer mbox =
  forever $ do
    Ping r <- receive mbox
    atomically (r Pong)

main :: IO ()
main =
  hspec $ do
    describe "two communicating processes" $
      it "exchange ping/pong messages" $ do
        g <- withProcess pongServer (query Ping)
        g `shouldBe` Pong
    describe "timeouts" $ do
      it "give up on a query that is never answered" $ do
        inbox <- newInbox :: IO (Inbox Ping)
        queryU (10 * 1000) Ping inbox `shouldReturn` Nothing
      it "give up on a message that never comes" $ do
        inbox <- newInbox :: IO (Inbox Pong)
        receiveMatchU (10 * 1000) inbox Just `shouldReturn` Nothing
      it "do not get in the way of an answer" $ do
        g <- withProcess pongServer (queryS 5 Ping)
        g `shouldBe` Just Pong
    describe "supervisor" $ do
      let dummy = threadDelay $ 1000 * 1000
      it "all processes end without failure" $ do
        let action =
              withSupervisor KillAll $ \sup -> do
                addChild sup dummy
                addChild sup dummy
                threadDelay $ 100 * 1000
        action `shouldReturn` ()
      it "one process crashes" $ do
        let action =
              withSupervisor IgnoreGraceful $ \sup -> do
                addChild sup dummy
                addChild sup (throwIO TestError1)
                threadDelay $ 500 * 1000
        action `shouldThrow` threadError testError1
      it "both processes crash" $ do
        let action =
              withSupervisor IgnoreGraceful $ \sup -> do
                addChild sup (throwIO TestError1)
                addChild sup (throwIO TestError2)
                threadDelay $ 500 * 1000
        action `shouldThrow` threadError testError
      it "reports a child that was cancelled behind its back" $ do
        let cancelled AsyncCancelled = True
            action =
              withSupervisor KillAll $ \sup -> do
                child <- addChild sup dummy
                cancel child
                threadDelay $ 500 * 1000
        action `shouldThrow` threadError (asyncChildError cancelled)
      it "monitors processes" $ do
        let rcv i = receive i :: IO (Maybe SomeException)
        (inbox, mailbox) <- newMailbox
        (t1, t2) <-
          withSupervisor (Notify ((`sendSTM` mailbox) . snd)) $ \sup -> do
            addChild sup (throwIO TestError1)
            addChild sup (throwIO TestError2)
            (,) <$> rcv inbox <*> rcv inbox
        t1 `shouldSatisfy` notifError testError
        t2 `shouldSatisfy` notifError testError
    describe "pubsub" $ do
      it "sends messages to all subscribers" $ do
        let msgs = words "hello world"
        (inbox1, mbox1) <- newMailbox
        (inbox2, mbox2) <- newMailbox
        (msgs1, msgs2) <-
          withPublisher $ \pub -> do
            subscribe pub (`sendSTM` mbox1)
            subscribe pub (`sendSTM` mbox2)
            mapM_ ((`send` pub) . Event) msgs
            msgs1 <- replicateM 2 (receive inbox1)
            msgs2 <- replicateM 2 (receive inbox2)
            return (msgs1, msgs2)
        msgs1 `shouldBe` msgs
        msgs2 `shouldBe` msgs
      it "subscribes for the length of a scope" $ do
        (msg, after) <-
          withPublisher $ \pub -> do
            (inbox, msg) <-
              withSubscription pub $ \inbox -> do
                publish "hello" pub
                (,) inbox <$> receive inbox
            publish "world" pub
            -- The publisher handles messages in order, so by the
            -- time it answers this it has dealt with "world".
            _ <- subscribe pub (const (return ()))
            (,) msg <$> mailboxEmpty inbox
        msg `shouldBe` "hello"
        after `shouldBe` True
      it "drops messages when bounded queue full" $ do
        let msgs = words "hello world drop"
        let f mbox msg =
              mailboxFullSTM mbox >>= \case
                True -> return ()
                False -> msg `sendSTM` mbox
        msgs' <-
          withPublisher $ \pub -> do
            inbox <- newBoundedInbox 2
            subscribe pub (f (inboxToMailbox inbox))
            mapM_ ((`send` pub) . Event) msgs
            atomically $ check =<< mailboxFullSTM inbox
            threadDelay $ 250 * 1000
            msgs' <- replicateM 2 (receive inbox)
            Event "meh" `send` pub
            msg <- receive inbox
            return $ msgs' <> [msg]
        msgs' `shouldBe` words "hello world meh"
