{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
import           Control.Concurrent
import           Control.Concurrent.NQE
import           Control.Concurrent.STM (readTVar)
import           Control.Exception      ()
import           Control.Monad
import           Control.Monad.Catch    (MonadThrow)
import           Control.Monad.State
import           Data.ByteString        (ByteString)
import           Data.Conduit
import           Data.Conduit.Network
import           Data.Conduit.TMChan
import           Data.Conduit.Text      (decode, encode, utf8)
import qualified Data.Conduit.Text      as CT
import           Data.Dynamic
import           Data.Text              (Text)
import           Test.Hspec

data Ping = Ping deriving (Eq, Show, Typeable)
data Pong = Pong deriving (Eq, Show, Typeable)

pong :: IO ()
pong = forever $ do
    (p, Ping) <- getRequest
    sendResponse Pong p

encoder :: MonadThrow m => Conduit Text m ByteString
encoder = encode utf8

decoder :: MonadThrow m => Conduit ByteString m Text
decoder = decode utf8 =$= CT.lines

conduits :: IO ( Source IO ByteString
               , Sink ByteString IO ()
               , Source IO ByteString
               , Sink ByteString IO ()
               )
conduits = do
    inChan <- atomically $ newTBMChan 16
    outChan <- atomically $ newTBMChan 16
    return ( sourceTBMChan inChan
           , sinkTBMChan outChan True
           , sourceTBMChan outChan
           , sinkTBMChan inChan True
           )

pongServer :: Source IO ByteString
           -> Sink ByteString IO ()
           -> IO ()
pongServer source sink =
    withNet (toProducer src) (toConsumer snk) $ \p -> do
    msg <- receive
    case msg of
        ("ping" :: Text) -> send ("pong\n" :: Text) p
        _                -> return ()
  where
    src = source =$= decoder
    snk = encoder =$= sink

pongClient :: Source IO ByteString
           -> Sink ByteString IO ()
           -> IO Text
pongClient source sink =
    withNet (toProducer src) (toConsumer snk) $ \p -> do
    send ("ping\n" :: Text) p
    receive
  where
    src = source =$= decoder
    snk = encoder =$= sink

dispatch :: Process -> IO ()
dispatch p = forever $ handle
    [ Handle $ \(i :: Int) -> send ("int" :: String) p
    , Handle $ \(t :: String) -> send ("string" :: String) p
    , HandleDefault $ \_ -> send ("default" :: String) p
    ]

ooo :: Process -> IO ()
ooo p = do
    msg1 <- receiveMatch (==1)
    send (msg1 :: Int) p
    msg2 <- receiveMatch (==2)
    send (msg2 :: Int) p
    msg3 <- receiveMatch (==3)
    send (msg3 :: Int) p


main :: IO ()
main = hspec $ do
    describe "two communicating processes" $ do
        it "exchange ping/pong messages" $ do
            ans <- withProcess pong $ query Ping
            ans `shouldBe` Pong
        it "setup a link" $ do
            lns <- withProcess pong $ \s -> do
                link s
                atomically $ readTVar $ links s
            tid <- myThreadId
            map thread lns `shouldBe` [tid]
        it "linked and stopped" $ do
            (sig, tid) <- withProcess pong $ \s -> do
                link s
                stop s
                sig <- receiveMsg
                return (sig, thread s)
            case sig of
                Left (Died tid) -> return ()
                _               -> error "Unexpected signal"
        it "dispatch multiple types of message" $ do
            types <- do
                me <- myProcess
                withProcess (dispatch me) $ \d -> do
                    send ("This is a string" :: String) d
                    send (42 :: Int) d
                    send (["List", "of", "strings"] :: [String]) d
                    replicateM 3 receive
            types `shouldBe` (["string", "int", "default"] :: [String])
        it "process messages out of order if needed" $ do
            messages <- do
                me <- myProcess
                withProcess (ooo me) $ \o -> do
                    send (2 :: Int) o
                    send (3 :: Int) o
                    send (1 :: Int) o
                    replicateM 3 receive
            messages `shouldBe` ([1, 2, 3] :: [Int])
    describe "network process" $ do
        it "responds to a ping" $ do
            (source1, sink1, source2, sink2) <- conduits
            msg <- withProcess (pongServer source1 sink1) $ \_ ->
                pongClient source2 sink2
            msg `shouldBe` ("pong" :: Text)
