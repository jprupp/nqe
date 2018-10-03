{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
import           Conduit
import           Control.Concurrent.STM (check)
import           Control.Exception
import           Control.Monad
import           Data.Dynamic
import           NQE
import           Test.Hspec
import           UnliftIO
import           UnliftIO.Concurrent    hiding (yield)

data Pong = Pong deriving (Eq, Show)
newtype Ping = Ping (Reply Pong)

data TestError
    = TestError1
    | TestError2
    | TestError3
    deriving (Show, Eq)
instance Exception TestError

pongServer :: MonadIO m => Inbox -> m ()
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
        describe "supervisor" $ do
            let dummy = threadDelay $ 250 * 1000
            it "all processes end without failure" .
                withSupervisor KillAll [dummy, dummy] $ \(Supervisor sup) ->
                wait (getProcessAsync sup) `shouldReturn` ()
            it "one process crashes" .
                withSupervisor IgnoreGraceful [dummy, throw TestError1] $ \(Supervisor sup) ->
                wait (getProcessAsync sup) `shouldThrow` (== TestError1)
            it "both processes crash" .
                withSupervisor
                    IgnoreGraceful
                    [throw TestError1, throw TestError2] $ \(Supervisor sup) ->
                wait (getProcessAsync sup) `shouldThrow`
                (\e -> e == TestError1 || e == TestError2)
            it "monitors processes" $ do
                let rcv i = receiveSTM i :: STM SupervisorNotif
                (inbox, mailbox) <- newMailbox
                (t1, t2) <-
                    withSupervisor
                        (Notify mailbox)
                        [throw TestError1, throw TestError2] $ \_ ->
                        atomically $ (,) <$> rcv inbox <*> rcv inbox
                let er (ChildStopped _ e) =
                        case e of
                            Nothing -> False
                            Just x ->
                                case fromException x of
                                    Just TestError1 -> True
                                    Just TestError2 -> True
                                    _ -> False
                t1 `shouldSatisfy` er
                t2 `shouldSatisfy` er
        describe "pubsub" $ do
            it "sends messages to all subscribers" $ do
                let msgs = words "hello world"
                (inbox1, mbox1) <- newMailbox
                (inbox2, mbox2) <- newMailbox
                (msgs1, msgs2) <-
                    withPublisher $ \pub -> do
                        subscribe pub mbox1
                        subscribe pub mbox2
                        mapM_ (`send` pub) msgs
                        msgs1 <- replicateM 2 (receive inbox1)
                        msgs2 <- replicateM 2 (receive inbox2)
                        return (msgs1, msgs2)
                msgs1 `shouldBe` msgs
                msgs2 `shouldBe` msgs
            it "drops messages when bounded queue full" $ do
                let msgs = words "hello world drop"
                msgs' <-
                    withPublisher $ \pub -> do
                        inbox <-
                            newTBQueueIO 2 >>= \m ->
                                newInbox (m :: TBQueue Dynamic)
                        subscribe pub (inboxToMailbox inbox)
                        mapM_ (`send` pub) msgs
                        atomically $ check =<< mailboxFullSTM inbox
                        threadDelay $ 250 * 1000
                        msgs' <- replicateM 2 (receive inbox)
                        ("meh" :: String) `send` pub
                        msg <- receive inbox
                        return $ msgs' <> [msg]
                msgs' `shouldBe` words "hello world meh"
