module Main (main) where

import Control.Exception (bracket)
import Control.Monad (replicateM_, unless, when)
import Data.IORef
import Data.Word (Word64)
import System.Environment (getArgs)

import qualified GHC.Internal.Event.Control as C
import qualified GHC.Internal.Event.Internal as I
import qualified GHC.Internal.Event.TimerManager as TM
import GHC.Internal.System.Posix.Types (Fd)

-- The fake backend records waits and dispatches real control messages on
-- demand. It never calls poll, spawns a process, or sends an OS signal.
type PollAction = Maybe I.Timeout -> (Fd -> I.Event -> IO ()) -> IO Int

data Harness = Harness
  { manager :: TM.TimerManager
  , waits :: IORef [Maybe I.Timeout]
  , onPoll :: IORef PollAction
  , deletes :: IORef Int
  }

data Variant = Original | Capped

capNS :: Word64
capNS = 1000000000

check :: String -> Bool -> IO ()
check message ok = unless ok $ fail message

newHarness :: IO Harness
newHarness = do
  seen <- newIORef []
  action <- newIORef $ \_ _ -> pure 0
  removed <- newIORef 0
  let poll () timeout callback = do
        modifyIORef' seen (timeout :)
        f <- readIORef action
        f timeout callback
      backend = I.backend poll (\() _ _ _ -> pure True)
        (\() _ _ -> pure True) (\() -> modifyIORef' removed (+ 1)) ()
  mgr <- TM.newWith backend
  pure $ Harness mgr seen action removed

withHarness :: (Harness -> IO a) -> IO a
withHarness = bracket newHarness $ \h -> do
  count <- readIORef (deletes h)
  -- loop cleans up itself; direct step tests need explicit cleanup.
  when (count == 0) $ TM.cleanup (manager h)

lastWait :: Harness -> IO I.Timeout
lastWait h = do
  seen <- readIORef (waits h)
  case seen of
    Just timeout : _ -> pure timeout
    _ -> fail "TimerManager did not request a blocking backend wait"

expectEmptyWait :: Variant -> Harness -> IO ()
expectEmptyWait variant h = do
  timeout <- lastWait h
  case (variant, timeout) of
    (Original, I.Forever) -> pure ()
    (Capped, I.Timeout ns) | ns == capNS -> pure ()
    _ -> fail $ "unexpected empty-queue wait: " ++ show timeout

expectLongWait :: Variant -> Harness -> IO ()
expectLongWait variant h = do
  timeout <- lastWait h
  case (variant, timeout) of
    (Original, I.Timeout ns) | ns > capNS -> pure ()
    (Capped, I.Timeout ns) | ns == capNS -> pure ()
    _ -> fail $ "unexpected long-deadline wait: " ++ show timeout

emptyQueue :: Variant -> IO ()
emptyQueue variant = withHarness $ \h -> do
  _ <- TM.step (manager h)
  expectEmptyWait variant h

noEarlyCallback :: Variant -> IO ()
noEarlyCallback variant = withHarness $ \h -> do
  fired <- newIORef (0 :: Int)
  key <- TM.registerTimeout (manager h) 60000000 $ modifyIORef' fired (+ 1)
  -- Returning zero models successive spurious/early backend wakeups.
  replicateM_ 16 $ do
    _ <- TM.step (manager h)
    expectLongWait variant h
    readIORef fired >>= check "future timer fired on an early wakeup" . (== 0)
  -- Move the same timer to now, without sleeping or adding watchdog timers.
  TM.updateTimeout (manager h) key 0
  _ <- TM.step (manager h)
  readIORef fired >>= check "due timer did not fire exactly once" . (== 1)
  _ <- TM.step (manager h)
  readIORef fired >>= check "expired timer fired twice" . (== 1)
  expectEmptyWait variant h

expectShortWait :: Harness -> IO ()
expectShortWait h = do
  timeout <- lastWait h
  case timeout of
    I.Timeout ns | ns > 0 && ns <= 500000000 -> pure ()
    _ -> fail $ "short deadline was lengthened (or test was descheduled for 0.5s): " ++ show timeout

earlierTimerWake :: Variant -> IO ()
earlierTimerWake variant = withHarness $ \h -> do
  fired <- newIORef False
  _ <- TM.registerTimeout (manager h) 60000000 $ writeIORef fired True
  let control = TM.emControl (manager h)
      wakeFd = C.wakeupReadFd control
  initial <- C.readControlMessage control wakeFd
  check "initial registration did not send wakeup" $ initial == C.CMsgWakeup
  writeIORef (onPoll h) $ \_ callback -> do
    -- Insert while the backend is handling its previous wait. The manager's
    -- real control handler must be able to consume the new wakeup message.
    _ <- TM.registerTimeout (manager h) 500000 $ writeIORef fired True
    callback wakeFd I.evtRead
    pure 1
  _ <- TM.step (manager h)
  expectLongWait variant h
  writeIORef (onPoll h) $ \_ _ -> pure 0
  _ <- TM.step (manager h)
  expectShortWait h
  readIORef fired >>= check "earlier future timer fired immediately" . not

cancelledTimer :: Variant -> IO ()
cancelledTimer variant = withHarness $ \h -> do
  fired <- newIORef False
  key <- TM.registerTimeout (manager h) 60000000 $ writeIORef fired True
  TM.updateTimeout (manager h) key 0
  TM.unregisterTimeout (manager h) key
  _ <- TM.step (manager h)
  readIORef fired >>= check "cancelled due timer still fired" . not
  expectEmptyWait variant h

controlAndShutdown :: Variant -> IO ()
controlAndShutdown variant = withHarness $ \h -> do
  let mgr = manager h
      control = TM.emControl mgr
  writeIORef (onPoll h) $ \_ callback -> do
    TM.wakeManager mgr
    callback (C.wakeupReadFd control) I.evtRead
    TM.finished mgr >>= check "wakeup stopped the manager" . not
    TM.shutdown mgr
    callback (C.controlReadFd control) I.evtRead
    pure 2
  TM.loop mgr
  TM.finished mgr >>= check "shutdown did not finish the loop"
  readIORef (deletes h) >>= check "loop cleanup did not delete backend exactly once" . (== 1)
  readIORef (waits h) >>= check "shutdown required another poll" . ((== 1) . length)
  expectEmptyWait variant h

main :: IO ()
main = do
  args <- getArgs
  variant <- case args of
    ["original"] -> pure Original
    ["capped"] -> pure Capped
    _ -> fail "usage: timer-manager-wait-cap original|capped"
  emptyQueue variant
  noEarlyCallback variant
  earlierTimerWake variant
  cancelledTimer variant
  controlAndShutdown variant
  putStrLn "PASS: wait selection, deadlines, wakeup, cancellation, and shutdown"
