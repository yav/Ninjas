{-# LANGUAGE RecordWildCards #-}
module Client (ClientEnv(..), defaultClientEnv, clientMain) where

import Control.Concurrent
import Control.Monad
import Graphics.Gloss.Interface.IO.Game
import Graphics.Gloss.Data.Vector
import Graphics.Gloss.Geometry.Angle
import System.IO
import Network
import Server (ServerEnv(..), defaultServerEnv)
import NetworkMessages

import Character
import Parameters
import VectorUtils
import qualified Anim

moveButton, stopButton, attackButton, smokeButton,
  newGameButton, clearButton :: Key
moveButton    = MouseButton LeftButton
stopButton    = MouseButton RightButton
attackButton  = Char 'a'
smokeButton   = Char 's'
newGameButton = Char 'n'
clearButton   = Char 'c'

windowPadding :: Int
windowPadding = 60

dingPeriod :: Float
dingPeriod = 1

textScale :: Float
textScale = 0.25

dingPosition :: Point
dingPosition = (fst boardMin + 5, snd boardMax - 20)

targetRadius :: Float
targetRadius = 80


data ClientEnv = ClientEnv
  { hostname   :: HostName
  , clientPort :: Int
  , username   :: String
  }

defaultClientEnv :: ClientEnv
defaultClientEnv = ClientEnv
  { hostname   = "localhost"
  , clientPort = (serverPort defaultServerEnv)
  , username   = "Anon"
  }

clientMain :: ClientEnv -> IO ()
clientMain (ClientEnv host port name) =
  do anim <- Anim.loadWorld
     h <- connectTo host (PortNumber (fromIntegral port))
     hSetBuffering h NoBuffering

     hPutClientCommand h (ClientJoin name)

     poss <- getInitialWorld h
     r <- newMVar (initClientWorld anim poss)
     _ <- forkIO $ clientUpdates h r
     runGame h r

serverWaitingMessage :: Int -> String
serverWaitingMessage n
  = "Server waiting for "
 ++ show n ++ " more ninja"
 ++ if n > 1 then "s." else "."

getInitialWorld :: Handle -> IO [(Int,Point,Vector)]
getInitialWorld h =
  do msg <- hGetServerCommand h
     case msg of
       SetWorld poss -> return poss
       ServerWaiting n ->
         do putStrLn $ serverWaitingMessage n
            getInitialWorld h
       _ -> fail "Unexpected initial message"

initClientWorld :: Anim.World -> [(Int, Point, Vector)] -> World
initClientWorld anim poss =
  World { worldCharacters = [initClientCharacter (Anim.npc anim) i p v
                                | (i,p,v) <- poss ]
        , dingTimers    = []
        , worldMessages = []
        , smokeTimers   = []
        , appearance    = anim
        , mousePtr      = (0,0)
        }

runGame :: Handle -> MVar World -> IO ()
runGame h var =
     playIO
       (InWindow "Ninjas"
         (round width + windowPadding, round height + windowPadding)
         (10,10))
       black
       eventsPerSecond
       () -- "state"
       (\() -> fmap drawWorld (readMVar var))
       (inputEvent h var)
       (\t () -> modifyMVar_ var $ \w -> return $ updateClientWorld t w)
  where (width,height) = subPt boardMax boardMin

drawWorld      :: World -> Picture
drawWorld w     = pictures
                $ borderPicture
                : dingPicture (length (dingTimers w))
                : map (drawPillar w) pillars
               ++ map drawCharacter (worldCharacters w)
               ++ map drawSmoke (smokeTimers w)
               ++ messagePictures (worldMessages w)
               ++ [ translateV (mousePtr w) target ]
  where
  thickness = (magV (subPt (addPt pt boardMax) boardMin) - targetRadius)
  pt        = let wp = 2 * ninjaRadius
              in (wp,wp)

  target    = pictures
              [ color (makeColor 0 0 0 0.8)
                $ thickCircle (targetRadius + thickness / 2) thickness
              , color white $ circle (0.75 * targetRadius)
              , color red   $ circleSolid (0.1 * targetRadius)
              ]


drawSmoke :: (Point, Anim.Animation) -> Picture
drawSmoke (pt,a) = translateV pt (Anim.curFrame a)

messagePictures :: [String] -> [Picture]
messagePictures msgs = zipWith messagePicture [0..] msgs

messagePicture :: Int -> String -> Picture
messagePicture i msg
  = translate (fst boardMin + 5)
              (snd boardMin + 5 + textHeight * fromIntegral i)
  $ scale textScale textScale
  $ color (greyN gray)
  $ text msg
  where
  textHeight = 40
  gray = (4 - fromIntegral (min 3 i)) / 4

dingPicture :: Int -> Picture
dingPicture n =
  pictures [ translateV dingPosition
           $ translate (5 * fromIntegral i) (- 5 * fromIntegral i)
           $ scale textScale textScale
           $ color white
           $ text "DING"
           | i <- [0..n-1]]

drawPillar :: World -> Point -> Picture
drawPillar w pt
  = translateV pt
  $ Anim.curFrame $ Anim.tower $ appearance w

borderPicture  :: Picture
borderPicture   = color red $ rectangleWire (2 * ninjaRadius + width)
                                            (2 * ninjaRadius + height)
  where (width,height) = subPt boardMax boardMin

drawCharacter :: ClientCharacter -> Picture
drawCharacter c
    = translateV (charPos char)
    $ rotate (negate $ radToDeg rads)
    $ Anim.curFrame (clientAnim c)
  where char  = clientCharacter c
        rads  = argV (charFacing char)



-- | Translate a picture using a 'Vector'
translateV :: Vector -> Picture -> Picture
translateV (x,y) = translate x y

inputEvent     :: Handle -> MVar World -> Event -> () -> IO ()
inputEvent _ var (EventMotion p) _ =
  hPutClientCommand h (ClientCommand (Move (0,0) p))
inputEvent h var (EventKey k Down _ pos) ()
  | k == moveButton   = hPutClientCommand h (ClientCommand (Move (0,0) pos))
  | k == stopButton   = hPutClientCommand h (ClientCommand Stop      )
  | k == attackButton = hPutClientCommand h (ClientCommand Attack    )
  | k == smokeButton  = hPutClientCommand h (ClientSmoke             )
  | k == newGameButton = hPutClientCommand h NewGame
  | k == clearButton  = clearMessages var
inputEvent _ _ _ () = return ()

clearMessages :: MVar World -> IO ()
clearMessages var = modifyMVar_ var $ \w -> return $ w { worldMessages = [] }

updateClientWorld :: Float -> World -> World
updateClientWorld d w =
  w { worldCharacters = map (stepClientCharacter npcLooks d) (worldCharacters w)
    , dingTimers  = [ t - d      |  t     <- dingTimers  w, t > d]
    , smokeTimers = [(pt, Anim.update d a) |
                            (pt,a) <- smokeTimers w, not (Anim.finished d a) ]
    , appearance  = Anim.updateWorld d (appearance w)
    }
  where npcLooks = Anim.npc (appearance w)

stepClientCharacter :: Anim.NPC -> Float -> ClientCharacter -> ClientCharacter
stepClientCharacter looks elapsed clientChar =
  case stepCharacter elapsed (clientCharacter clientChar) of
    (char,changed,_)
      | changed   -> newClientCharacter looks char
      | otherwise -> clientChar { clientCharacter = char
                                , clientAnim = Anim.update elapsed (clientAnim clientChar) }

newClientCharacter :: Anim.NPC -> Character -> ClientCharacter
newClientCharacter looks clientCharacter = ClientCharacter { .. }
  where
  clientAnim = case charState clientCharacter of
                 Walking {}               -> Anim.walk looks
                 Waiting w | waitStunned w -> Anim.stun   looks
                           | otherwise    -> Anim.stay   looks
                 Attacking {}             -> Anim.attack looks
                 Dead                     -> Anim.die    looks

clientUpdates :: Handle -> MVar World -> IO ()
clientUpdates h var = forever $
  do c <- hGetServerCommand h
     modifyMVar_ var $ \w -> return $! processCmd w c

  where

  processCmd w c =
    case c of
      ServerReady       -> w { worldMessages = [] }
      ServerMessage txt -> w { worldMessages = txt : worldMessages w }
      ServerDing        -> w { dingTimers = dingPeriod : dingTimers w }
      ServerSmoke pt    -> let smoke = Anim.smoke (appearance w)
                           in w { smokeTimers = (pt,smoke) : smokeTimers w }
      SetWorld poss     -> initClientWorld (appearance w) poss
      ServerCommand i m -> let f = npcCommand w m
                           in w { worldCharacters = updateNpcList i f $ worldCharacters w }
      _                 -> w

  npcCommand w cmd cnpc =
    let npc = clientCharacter cnpc
    in newClientCharacter (Anim.npc $ appearance w) $
       case cmd of
         Move from to   -> walkingCharacter to npc { charPos = from }
         Stop           -> waitingCharacter Nothing False npc
         Stun           -> stunnedCharacter npc
         Die            -> deadCharacter npc
         Attack         -> attackingCharacter npc

updateNpcList :: Int -> (ClientCharacter -> ClientCharacter) -> [ClientCharacter] -> [ClientCharacter]
updateNpcList _ _ [] = []
updateNpcList i f (n:ns)
  | charName (clientCharacter n) == i = f n : ns
  | otherwise      = n : updateNpcList i f ns

data World = World
  { worldCharacters  :: [ClientCharacter]
  , dingTimers       :: [Float]
  , smokeTimers      :: [(Point, Anim.Animation)]
  , worldMessages    :: [String]
  , appearance       :: Anim.World
  , mousePtr         :: Point
  }

-- | Construct a new character given a name, a position,
-- and a facing unit vector. This function is used
-- by clients who are told the parameters by the
-- server.
initClientCharacter :: Anim.NPC -> Int -> Point -> Vector -> ClientCharacter
initClientCharacter anim charName charPos charFacing =
  let charState = Waiting Wait { waitWaiting = Nothing, waitStunned = False }
      clientAnim = Anim.stay anim
      clientCharacter = Character { .. }
  in  ClientCharacter { .. }

data ClientCharacter = ClientCharacter
  { clientCharacter  :: Character
  , clientAnim       :: Anim.Animation
  }

