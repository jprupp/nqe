{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
import           Conduit
import           Control.Concurrent.STM (check)
import           Control.Exception
import           Control.Monad
import           Data.ByteString        (ByteString)
import           Data.Conduit.Text      (decode, encode, utf8)
import qualified Data.Conduit.Text      as CT
import           Data.Conduit.TMChan
import           Data.Text              (Text)
import           NQE
import           Test.Hspec
import           UnliftIO
import           UnliftIO.Concurrent    hiding (yield)

data Pong = Pong deriving (Eq, Show)
newtype Ping = Ping (Pong -> STM ())

data TestError
    = TestError1
    | TestError2
    | TestError3
    deriving (Show, Eq)
instance Exception TestError

pong :: TQueue Ping -> IO ()
pong mbox =
    forever $ do
        Ping reply <- receive mbox
        atomically (reply Pong)

encoder :: MonadThrow m => ConduitT Text ByteString m ()
encoder = encode utf8

decoder :: MonadThrow m => ConduitT ByteString Text m ()
decoder = decode utf8 .| CT.lines

conduits ::
       IO ( ConduitT () ByteString IO ()
          , ConduitT ByteString Void IO ()
          , ConduitT () ByteString IO ()
          , ConduitT ByteString Void IO ())
conduits = do
    inChan <- newTBMChanIO 2048
    outChan <- newTBMChanIO 2048
    return ( sourceTBMChan inChan
           , sinkTBMChan outChan
           , sourceTBMChan outChan
           , sinkTBMChan inChan
           )

pongServer ::
       ConduitT () ByteString IO ()
    -> ConduitT ByteString Void IO ()
    -> (Async () -> IO a)
    -> IO a
pongServer source sink go = do
    mbox <- newTQueueIO
    withAsync (in_pipe mbox) $ const $ withAsync (out_pipe mbox) go
  where
    in_pipe mbox = runConduit $ source .| decoder .| conduitMailbox mbox
    out_pipe mbox = runConduit $ processor mbox .| encoder .| sink
    processor mbox =
        forever $
        receive mbox >>= \case
            ("ping" :: Text) -> yield ("pong\n" :: Text)
            _ -> return ()

pongClient :: ConduitT () ByteString IO ()
           -> ConduitT ByteString Void IO ()
           -> IO Text
pongClient source sink = do
    mbox <- newTQueueIO
    withAsync out_pipe $
        const $ withAsync (in_pipe mbox) $ const $ receive mbox
  where
    in_pipe mbox = runConduit $ source .| decoder .| conduitMailbox mbox
    out_pipe = runConduit $ generator .| encoder .| sink
    generator = yield ("ping\n" :: Text)

main :: IO ()
main =
    hspec $ do
        describe "two communicating processes" $
            it "exchange ping/pong messages" $ do
                mbox <- newTQueueIO
                g <- withAsync (pong mbox) $ const $ query Ping mbox
                g `shouldBe` Pong
        describe "network process" $
            it "responds to a ping" $ do
                (source1, sink1, source2, sink2) <- conduits
                msg <-
                    pongServer source1 sink1 $ const $ pongClient source2 sink2
                msg `shouldBe` "pong"
        describe "utilities" $ do
            it "timeout action fails" $ do
                n <- timeout 0xbeef (threadDelay 0xdeadbeef)
                n `shouldBe` Nothing
            it "timeout action succeeds" $ do
                n <- timeout 0xdeadbeef (return (0xbeef :: Integer))
                n `shouldBe` Just 0xbeef
        describe "supervisor" $ do
            let p1 m = forever $ receive m >>= \r -> atomically $ r ()
                p2 = query id
            it "all processes end without failure" $ do
                mbox <- newTQueueIO
                sup <- newTQueueIO
                g <- async $ supervisor KillAll sup [p1 mbox, p2 mbox]
                wait g `shouldReturn` ()
            it "one process crashes" $ do
                mbox <- newTQueueIO
                sup <- newTQueueIO
                g <-
                    async $
                    supervisor
                        IgnoreGraceful
                        sup
                        [p1 mbox, p2 mbox >> throw TestError1]
                wait g `shouldThrow` (== TestError1)
            it "both processes crash" $ do
                sup <- newTQueueIO
                g <-
                    async $
                    supervisor
                        IgnoreGraceful
                        sup
                        [throw TestError1, throw TestError2]
                wait g `shouldThrow` (\e -> e == TestError1 || e == TestError2)
            it "process crashes ignored" $ do
                sup <- newTQueueIO
                g <-
                    async $
                    supervisor
                        IgnoreAll
                        sup
                        [throw TestError1, throw TestError2]
                stopSupervisor sup
                wait g `shouldReturn` ()
            it "monitors processes" $ do
                sup <- newTQueueIO
                mon <- newTQueueIO
                g <-
                    async $
                    supervisor
                        (Notify (writeTQueue mon))
                        sup
                        [throw TestError1, throw TestError2]
                (t1, t2) <-
                    atomically $ (,) <$> readTQueue mon <*> readTQueue mon
                let er e =
                        case e of
                            Right () -> False
                            Left x ->
                                case fromException x of
                                    Just TestError1 -> True
                                    Just TestError2 -> True
                                    _               -> False
                snd t1 `shouldSatisfy` er
                snd t2 `shouldSatisfy` er
                stopSupervisor sup
                wait g `shouldReturn` ()
        describe "pubsub" $ do
            it "sends messages to all subscribers" $ do
                let msgs = words "hello world"
                pub <- newTQueueIO >>= newInbox
                withAsync (publisher pub) $
                    const $
                    withPubSub Nothing pub $ \sub1 ->
                        withPubSub Nothing pub $ \sub2 -> do
                            mapM_ ((`send` pub) . Event) msgs
                            sub1msgs <- replicateM 2 (receive sub1)
                            sub2msgs <- replicateM 2 (receive sub2)
                            sub1msgs `shouldBe` msgs
                            sub2msgs `shouldBe` msgs
            it "drops messages when bounded queue full" $ do
                let msgs = words "hello world drop"
                pub <- newTQueueIO >>= newInbox
                withAsync (publisher pub) $
                    const $
                    withPubSub (Just 2) pub $ \sub -> do
                        mapM_ ((`send` pub) . Event) msgs
                        atomically $ do
                            check =<< mailboxFullSTM sub
                            check =<< mailboxEmptySTM pub
                        msgs' <- replicateM 2 (receive sub)
                        Event "meh" `send` pub
                        msg <- receive sub
                        msgs' <> [msg] `shouldBe` words "hello world meh"
