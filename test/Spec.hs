{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
import           Control.Concurrent
import           Control.Concurrent.NQE
import           Control.Concurrent.STM
import           Control.Exception      ()
import           Control.Monad
import           Control.Monad.Catch    (MonadThrow)
import           Control.Monad.State
import           Data.ByteString        (ByteString)
import           Data.Conduit
import           Data.Conduit.Network
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

server :: (AppData -> IO ()) -> IO ThreadId
server = forkTCPServer ss
  where
    ss = serverSettings 34828 "127.0.0.1"

client :: (AppData -> IO a) -> IO a
client = runTCPClient cs
  where
    cs = clientSettings 34828 "127.0.0.1"

pongServer :: AppData -> IO ()
pongServer ad = asProcess $ withNet decoder encoder ad $ \p -> forever $ do
    msg <- receive
    case msg of
        ("ping" :: Text) -> send ("pong\n" :: Text) p
        _                -> error "Expected ping"

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
main = do
    server pongServer
    hspec $ do
        describe "two communicating processes" $ do
            it "exchange ping/pong messages" $ do
                ans <- asProcess $
                    withProcess pong $ query Ping
                ans `shouldBe` Pong
            it "setup a link" $ do
                lns <- asProcess $ do
                    withProcess pong $ \s -> do
                        link s
                        atomically $ readTVar $ links s
                tid <- myThreadId
                map thread lns `shouldBe` [tid]
            it "linked and stopped" $ do
                (sig, tid) <- asProcess $
                    withProcess pong $ \s -> do
                    link s
                    stop s
                    sig <- receiveMsg
                    return (sig, thread s)
                case sig of
                    Left (Died tid) -> return ()
                    _               -> error "Unexpected signal"
            it "dispatch multiple types of message" $ do
                types <- asProcess $ do
                    me <- myProcess
                    withProcess (dispatch me) $ \d -> do
                        send ("This is a string" :: String) d
                        send (42 :: Int) d
                        send (["List", "of", "strings"] :: [String]) d
                        replicateM 3 receive
                types `shouldBe` (["string", "int", "default"] :: [String])
            it "process messages out of order if needed" $ do
                messages <- asProcess $ do
                    me <- myProcess
                    withProcess (ooo me) $ \o -> do
                        send (2 :: Int) o
                        send (3 :: Int) o
                        send (1 :: Int) o
                        replicateM 3 receive
                messages `shouldBe` ([1, 2, 3] :: [Int])
        describe "network process" $ do
            it "responds to a ping" $
                asProcess $ client $ \ad ->
                withNet decoder encoder ad $ \p -> do
                send ("ping\n" :: Text) p
                msg <- receive
                case msg of
                    ("pong" :: Text) -> return ()
                    _                -> error "Expected pong"
