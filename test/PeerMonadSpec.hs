module PeerMonadSpec where

import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import Control.Exception.Base
import Control.Monad.Catch hiding(throwM, catch)
import qualified Control.Monad.Catch as Catch
import Control.Monad.Catch.Pure
import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.Free.Church
import Control.Monad.Reader
import Control.Monad.State.Strict
import qualified Data.ByteString as B
import Data.Functor.Identity
import qualified Data.Map.Strict as Map
import Data.Word
import Network.BitTorrent.Bencoding
import qualified Network.BitTorrent.BitField as BF
import Network.BitTorrent.Client
import Network.BitTorrent.MetaInfo
import Network.BitTorrent.MemoryMonad
import Network.BitTorrent.PeerMonad
import qualified Network.BitTorrent.PeerSelection as PS
import Network.BitTorrent.PWP
import Network.BitTorrent.Types
import System.Directory
import System.IO
import System.Timeout

import Test.Hspec
import SpecHelper

data Memory = Memory { memoryBitField :: BF.BitField
                     , memoryPieceChunks :: Chunks
                     , memoryAvailabilityData :: PS.AvailabilityData
                     }

clientStateToMemory :: ClientState -> IO Memory
clientStateToMemory state = atomically (Memory
                                           <$> readTVar (bitField state)
                                           <*> readTVar (pieceChunks state)
                                           <*> readTVar (availabilityData state))

type MemoryMonadTest = StateT Memory Identity

runMemoryMonadTest :: Memory -> F MemoryMonad a -> (a, Memory)
runMemoryMonadTest mem t = runIdentity (runStateT (iterM evalMemoryMonadTest t) mem)

evalMemoryMonadTest :: MemoryMonad (MemoryMonadTest a) -> MemoryMonadTest a
evalMemoryMonadTest (ModifyAvailability mut next) = do
  memory <- get
  put $ memory { memoryAvailabilityData = mut (memoryAvailabilityData memory) }
  next

data PeerState = PeerState { peerStateData :: PeerData
                           , peerStateOutputs :: [PWP]
                           , peerStateCleanups :: [(Word32, Word32)]
                           , peerStateEvents :: [PeerEvent]
                           , peerStateMemory :: Memory
                           }

type PeerMonadTest = ReaderT ClientState (StateT PeerState Catch)

runPeerMonadTest :: ClientState
                 -> PeerData
                 -> Memory
                 -> [PeerEvent]
                 -> F PeerMonad a
                 -> Either (Maybe PeerError) (a, PeerState)
runPeerMonadTest state pData memory events t =
  case result of
    Left e -> Left (fromException e)
    Right a -> Right a
  where peerState = PeerState pData [] [] events memory
        result = runCatch (
                   runStateT (
                     runReaderT (
                       iterM evalPeerMonadTest t
                     )
                     state
                   )
                   peerState
                 )

evalPeerMonadTest :: PeerMonad (PeerMonadTest a) -> PeerMonadTest a
evalPeerMonadTest (GetPeerData next) = do
  PeerState pData _ _ _ _ <- get
  next pData
evalPeerMonadTest (Emit msg next) = do
  pState@(PeerState _ outputs _ _ _) <- get
  put $ pState { peerStateOutputs = msg : outputs }
  next
evalPeerMonadTest (GetMeta next) = metaInfo <$> ask >>= next
evalPeerMonadTest (UpdatePeerData pData next) = do
  pState <- get
  put $ pState { peerStateData = pData }
  next
evalPeerMonadTest (GetPeerEvent next) = do
  pState@(PeerState _ _ _ events _) <- get
  case events of
    [] -> Catch.throwM ConnectionLost
    (event:rest) -> do
      put $ pState { peerStateEvents = rest }
      next event
evalPeerMonadTest (RunMemory action next) = do
  pState <- get
  let (res, mem') = runMemoryMonadTest (peerStateMemory pState) action
  put $ pState { peerStateMemory = mem' }
  next res
evalPeerMonadTest (Throw e next) = Catch.throwM e *> next
evalPeerMonadTest (Catch action handler ) =
  Catch.catch action handler

spec :: SpecWith ()
spec = do
  tmpdir <- runIO getTemporaryDirectory
  state <- runIO $ newClientState tmpdir testMeta 9999
  handle <- runIO $ openFile "/dev/null" WriteMode
  memory <- runIO $ clientStateToMemory state
  let addr = testAddr [1, 0, 0, 127] 9999
      peerId = B.replicate (fromEnum '1') 20
      bf = BF.newBitField 4
      pData = newPeer bf addr peerId

  describe "PeerMonad" $ do
    describe "handlePWP" $ do
      describe "for Have message" $ do
        it "properly adjust the peer bitfield" $ do
          let exp = handlePWP (Have 2) *> getPeerData
              Right (pData', _) = runPeerMonadTest state pData memory [] exp
          BF.get (peerBitField pData') 2 `shouldBe` True

    describe "exception handling" $ do
      it "catches errors from monad evaluation" $ do
        let exp = catchError (getPeerEvent *> pure 0) (const $ pure 2)
            res = fst <$> runPeerMonadTest state pData memory [] exp
        res `shouldBe` Right 2

  describe "PeerMonadTest" $ do
    describe "exception handling" $ do
      describe "on getPeerEvent" $ do
        it "throws ConnectionLost after all messages" $ do
          let events = [PWPEvent KeepAlive, SharedEvent Checkup]
              exp = do
                res  <- sequence (replicate 2 getPeerEvent)
                res2 <- catchError (getPeerEvent *> pure False) (const $ pure True)
                return (res, res2)
              res = fst <$> runPeerMonadTest state pData memory events exp
          res `shouldBe` Right (events, True)

  describe "PeerMonadIO" $ do
    describe "local state manipulation" $ do
      it "respects state updates" $ do
        let pData' = pData { amChoking = False }
            exp = updatePeerData pData' *> getPeerData
        returned <- runPeerMonad state pData handle exp
        returned `shouldBe` Right pData'