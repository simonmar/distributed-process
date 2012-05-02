module Main where

import TestTransport 
import Network.Transport
import Network.Transport.TCP (createTransport)
import Data.Int (Int32)
import Data.Maybe (fromJust)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, readMVar)
import Control.Monad (replicateM)
import Network.Transport.TCP (decodeEndPointAddress, EndPointId, ControlHeader(..), ConnectionRequestResponse(..))
import Network.Transport.Internal (encodeInt32, prependLength, tlog)
import Network.Transport.Internal.TCP (recvInt32)
import qualified Network.Socket as N ( getAddrInfo
                                     , socket
                                     , connect
                                     , addrFamily
                                     , addrAddress
                                     , SocketType(Stream)
                                     , SocketOption(ReuseAddr)
                                     , defaultProtocol
                                     , setSocketOption
                                     , sClose
                                     , HostName
                                     , ServiceName
                                     )
import Network.Socket.ByteString (sendMany)                                     

-- Test that the server gets a ConnectionClosed message when the client closes
-- the socket without sending an explicit control message to the server first
testEarlyDisconnect :: IO ()
testEarlyDisconnect = do
    serverAddr <- newEmptyMVar
    serverDone <- newEmptyMVar
    Right transport  <- createTransport "127.0.0.1" "8081" 
 
    forkIO $ server transport serverAddr serverDone
    forkIO $ client transport serverAddr 

    takeMVar serverDone
  where
    server :: Transport -> MVar (N.HostName, N.ServiceName, EndPointId) -> MVar () -> IO ()
    server transport serverAddr serverDone = do
      Right endpoint <- newEndPoint transport
      putMVar serverAddr (fromJust . decodeEndPointAddress . address $ endpoint)
      ConnectionOpened _ _ _ <- receive endpoint
      ConnectionClosed _ <- receive endpoint
      putMVar serverDone ()

    client :: Transport -> MVar (N.HostName, N.ServiceName, EndPointId) -> IO ()
    client transport serverAddr = do
      Right endpoint <- newEndPoint transport
      let EndPointAddress myAddress = address endpoint
  
      -- Connect to the server
      addr:_ <- N.getAddrInfo Nothing (Just "127.0.0.1") (Just "8081")
      sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
      N.setSocketOption sock N.ReuseAddr 1
      N.connect sock (N.addrAddress addr)
  
      (_, _, endPointIx) <- readMVar serverAddr
      sendMany sock (encodeInt32 endPointIx : prependLength [myAddress])

      -- Wait for acknowledgement
      ConnectionRequestAccepted <- recvInt32 sock
  
      -- Request a new connection, but don't wait for the response
      let reqId = 0 :: Int32
      sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId]
  
      -- Close the socket without closing the connection explicitly
      -- The server should still receive a ConnectionClosed message
      N.sClose sock

-- | Test that an endpoint can ignore CloseSocket requests (in "reality" this
-- would happen when the endpoint sends a new connection request before
-- receiving an (already underway) CloseSocket request) 
testIgnoreCloseSocket :: IO ()
testIgnoreCloseSocket = do
    serverAddr <- newEmptyMVar
    clientDone <- newEmptyMVar
    Right transport <- createTransport "127.0.0.1" "8084"
  
    forkIO $ server transport serverAddr
    forkIO $ client transport serverAddr clientDone 
  
    takeMVar clientDone

  where
    server :: Transport -> MVar (N.HostName, N.ServiceName, EndPointId) -> IO ()
    server transport serverAddr = do
      tlog "Server"
      Right endpoint <- newEndPoint transport
      putMVar serverAddr (fromJust . decodeEndPointAddress . address $ endpoint)

      -- Wait for the client to connect and disconnect
      tlog "Waiting for ConnectionOpened"
      ConnectionOpened _ _ _ <- receive endpoint
      tlog "Waiting for ConnectionClosed"
      ConnectionClosed _ <- receive endpoint

      -- At this point the server will have sent a CloseSocket request to the
      -- client, which however ignores it, instead it requests and closes
      -- another connection
      tlog "Waiting for ConnectionOpened"
      ConnectionOpened _ _ _ <- receive endpoint
      tlog "Waiting for ConnectionClosed"
      ConnectionClosed _ <- receive endpoint

      
      tlog "Server waiting.."

    client :: Transport -> MVar (N.HostName, N.ServiceName, EndPointId) -> MVar () -> IO ()
    client transport serverAddr clientDone = do
      tlog "Client"
      Right endpoint <- newEndPoint transport
      let EndPointAddress myAddress = address endpoint

      -- Connect to the server
      addr:_ <- N.getAddrInfo Nothing (Just "127.0.0.1") (Just "8084")
      sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
      N.setSocketOption sock N.ReuseAddr 1
      N.connect sock (N.addrAddress addr)

      tlog "Connecting to endpoint"
      (_, _, endPointIx) <- readMVar serverAddr
      sendMany sock (encodeInt32 endPointIx : prependLength [myAddress])

      -- Wait for acknowledgement
      ConnectionRequestAccepted <- recvInt32 sock

      -- Request a new connection
      tlog "Requesting connection"
      let reqId = 0 :: Int32
      sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId]
      response <- replicateM 4 $ recvInt32 sock :: IO [Int32] 

      -- Close the connection again
      tlog "Closing connection"
      sendMany sock [encodeInt32 CloseConnection, encodeInt32 (response !! 3)] 

      -- Server will now send a CloseSocket request as its refcount reached 0
      tlog "Waiting for CloseSocket request"
      CloseSocket <- recvInt32 sock

      -- But we ignore it and request another connection
      tlog "Ignoring it, requesting another connection"
      let reqId' = 1 :: Int32
      sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId']
      response' <- replicateM 4 $ recvInt32 sock :: IO [Int32] 

      -- Close it again
      tlog "Closing connection"
      sendMany sock [encodeInt32 CloseConnection, encodeInt32 (response !! 3)] 

      -- We now get a CloseSocket again, and this time we heed it
      tlog "Waiting for second CloseSocket request"
      CloseSocket <- recvInt32 sock
    
      tlog "Closing socket"
      sendMany sock [encodeInt32 CloseSocket]
      N.sClose sock

      putMVar clientDone ()

-- | Test the creation of a transport with an invalid address
testInvalidAddress :: IO ()
testInvalidAddress = do
  Left _ <- createTransport "invalidHostName" "8082"
  return ()

-- | Test connecting to invalid or non-existing endpoints
testInvalidConnect :: IO ()
testInvalidConnect = do
  Right transport <- createTransport "127.0.0.1" "8083"
  Right endpoint <- newEndPoint transport

  -- Syntax error in the endpoint address
  Left (FailedWith ConnectInvalidAddress _) <- 
    connect endpoint (EndPointAddress "InvalidAddress") ReliableOrdered
 
  -- Syntax connect, but invalid hostname (TCP address lookup failure)
  Left (FailedWith ConnectInvalidAddress _) <- 
    connect endpoint (EndPointAddress "invalidHost:port:0") ReliableOrdered
 
  -- TCP address correct, but nobody home at that address
  Left (FailedWith ConnectFailed _) <- 
    connect endpoint (EndPointAddress "127.0.0.1:9000:0") ReliableOrdered
 
  -- Valid TCP address but invalid endpoint number
  Left (FailedWith ConnectInvalidAddress _) <- 
    connect endpoint (EndPointAddress "127.0.0.1:8083:1") ReliableOrdered

  return ()

main :: IO ()
main = do
  runTestIO "EarlyDisconnect" testEarlyDisconnect
  runTestIO "InvalidAddress" testInvalidAddress
  runTestIO "InvalidConnect" testInvalidConnect
  runTestIO "IgnoreCloseSocket" testIgnoreCloseSocket
  Right transport <- createTransport "127.0.0.1" "8080" 
  testTransport transport 