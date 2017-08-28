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

newtype Ping m =
    Ping (m ())

pong :: Mailbox (Ping IO) -> IO ()
pong mbox =
    forever $ do
        Ping action <- receive mbox
        action

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
    inChan <- atomicallyIO $ newTBMChan 2048
    outChan <- atomicallyIO $ newTBMChan 2048
    return ( sourceTBMChan inChan
           , sinkTBMChan outChan True
           , sourceTBMChan outChan
           , sinkTBMChan inChan True
           )

pongServer :: Source IO ByteString
           -> Sink ByteString IO ()
           -> (Async () -> IO a)
           -> IO a
pongServer source sink go = withActor action $ go . fst
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
pongClient source sink = withActor action go
  where
    action mbox = withSource src mbox $ const $ processor mbox
    go (a, _) = wait a
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
                tv <- atomicallyIO newEmptyTMVar
                let act = atomicallyIO $ putTMVar tv ()
                withActor pong $ \(_, mbox) -> Ping act `send` mbox
                atomicallyIO $ readTMVar tv
        describe "network process" $ do
            it "responds to a ping" $ do
                (source1, sink1, source2, sink2) <- conduits
                msg <-
                    pongServer source1 sink1 $ \_ -> pongClient source2 sink2
                msg `shouldBe` "pong"
        describe "utilities" $ do
            it "timeout action fails" $ do
                n <- timeout 0xbeef (threadDelay 0xdeadbeef)
                n `shouldBe` Nothing
            it "timeout action succeeds" $ do
                n <- timeout 0xdeadbeef (return 0xbeef)
                n `shouldBe` Just 0xbeef
