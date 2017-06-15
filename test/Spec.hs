{-# LANGUAGE ScopedTypeVariables #-}
import           Control.Concurrent.NQE
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Data.Dynamic
import           Test.Hspec

data Ping = Ping deriving (Eq, Show, Typeable)
data Pong = Pong deriving (Eq, Show, Typeable)

data IKillYou = IKillYou deriving (Eq, Show, Typeable)
instance Exception IKillYou

pong :: ProcessSpec
pong = ProcessSpec
    { provides = "pong"
    , depends  = []
    , action = respond $ \Ping -> return Pong
    }

dispatch :: ProcessSpec
dispatch = ProcessSpec
    { provides = "dispatch"
    , depends = ["recipient"]
    , action = go
    }
  where
    go = do
        r:_ <- getProcess "recipient"
        forever $ receiveAny
            [ Case $ \(i :: Int) -> send "int" r
            , Case $ \(t :: String) -> send "string" r
            , Default $ send "default" r
            ]

ooo :: ProcessSpec
ooo = ProcessSpec
    { provides = "out-of-order"
    , depends = ["recipient"]
    , action = go
    }
  where
    go = do
        r:_ <- getProcess "recipient"
        msg1 <- receiveMatch (==1)
        send (msg1 :: Int) r
        msg2 <- receiveMatch (==2)
        send (msg2 :: Int) r
        msg3 <- receiveMatch (==3)
        send (msg3 :: Int) r

main :: IO ()
main = hspec $ do
    describe "two communicating processes" $ do
        it "exchange ping/pong messages" $ do
            initProcess "test"
            ans <- withProcess pong $ query Ping
            ans `shouldBe` Pong
        it "monitor setup" $ do
            initProcess "test"
            (lns, mns) <- withProcess pong $ \s -> do
                monitor s
                atomically $ do
                    lns <- readTVar $ links s
                    mns <- readTVar $ monitors s
                    return (lns, mns)
            map thread lns `shouldBe` []
            my <- myProcess
            map thread mns `shouldBe` [thread my]
        it "monitor one another" $ do
            initProcess "test"
            (sig, tid) <- withProcess pong $ \s -> do
                monitor s
                stop s
                sig <- receive
                return (sig, thread s)
            remoteThread sig `shouldBe` tid
        it "kill one another" $ do
            initProcess "test"
            (sig, tid) <- withProcess pong $ \s -> do
                monitor s
                kill s $ toException IKillYou
                sig <- receive
                return (sig, thread s)
            remoteThread sig `shouldBe` tid
        it "dispatch multiple types of message" $ do
            initProcess "recipient"
            types <- withProcess dispatch $ \d -> do
                send "This is a string" d
                send (42 :: Int) d
                send ["List", "of", "strings"] d
                replicateM 3 receive
            types `shouldBe` ["string", "int", "default"]
        it "process messages out of order if needed" $ do
            initProcess "recipient"
            messages <- withProcess ooo $ \o -> do
                send (2 :: Int) o
                send (3 :: Int) o
                send (1 :: Int) o
                replicateM 3 receive
            messages `shouldBe` ([1, 2, 3] :: [Int])
