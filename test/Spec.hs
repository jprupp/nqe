{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
import           Control.Concurrent.Async.Lifted.Safe
import           Control.Concurrent.Lifted            hiding (yield)
import           Control.Concurrent.NQE
import           Control.Concurrent.STM
import           Control.Monad
import           Control.Monad.Catch
import           Data.ByteString                      (ByteString)
import           Data.Conduit
import           Data.Conduit.Text                    (decode, encode, utf8)
import qualified Data.Conduit.Text                    as CT
import           Data.Conduit.TMChan
import           Data.Text                            (Text)
import           Test.Hspec

data Pong = Pong deriving (Eq, Show)
newtype Ping = Ping (Pong -> STM ())

pong :: Mailbox TQueue Ping -> IO ()
pong mbox =
    forever $ do
        Ping reply <- receive mbox
        atomicallyIO (reply Pong)

encoder :: MonadThrow m => Conduit Text m ByteString
encoder = encode utf8

decoder :: MonadThrow m => Conduit ByteString m Text
decoder = decode utf8 =$= CT.lines

conduits ::
       IO ( Source IO ByteString
          , Sink ByteString IO ()
          , Source IO ByteString
          , Sink ByteString IO ())
conduits = do
    inChan <- atomicallyIO $ newTBMChan 2048
    outChan <- atomicallyIO $ newTBMChan 2048
    return ( sourceTBMChan inChan
           , sinkTBMChan outChan True
           , sourceTBMChan outChan
           , sinkTBMChan inChan True
           )

pongServer ::
       Source IO ByteString
    -> Sink ByteString IO ()
    -> (Actor () -> IO a)
    -> IO a
pongServer source sink go = do
    mbox <- newTQueueIO
    withActor (action mbox) go
  where
    action mbox = withSource src mbox $ const $ processor mbox $$ snk
    src = source =$= decoder
    snk = encoder =$= sink
    processor mbox =
        forever $
        receive mbox >>= \case
            ("ping" :: Text) -> yield ("pong\n" :: Text)
            _ -> return ()

pongClient :: Source IO ByteString
           -> Sink ByteString IO ()
           -> IO Text
pongClient source sink = do
    mbox <- newTQueueIO
    withActor (action mbox) go
  where
    action mbox =
        withSource src mbox $ const $ processor mbox
    go = wait
    src = source =$= decoder
    snk = encoder =$= sink
    processor mbox = do
        yield ("ping\n" :: Text) $$ snk
        receive mbox

main :: IO ()
main =
    hspec $ do
        describe "two communicating processes" $ do
            it "exchange ping/pong messages" $ do
                mbox <- newTQueueIO
                g <- withActor (pong mbox) $ const $ query Ping mbox
                g `shouldBe` Pong
        describe "network process" $ do
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
                n <- timeout 0xdeadbeef (return 0xbeef)
                n `shouldBe` Just 0xbeef
