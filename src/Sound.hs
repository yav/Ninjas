{-# LANGUAGE RecordWildCards #-}
module Sound where

import Sound.Play
import Control.Monad(unless)
import Data.Word(Word)
import System.FilePath
import Paths_Ninjas

audioRate, audioChannels :: Word
audioChannels = 2
audioRate     = 44100


loadSample :: FilePath -> IO Sample
loadSample x =
  do s <- sampleFromFile =<< getDataFileName ("sounds" </> x <.> "ogg")
     unless (sampleChans s == audioChannels &&
             sampleRate s == audioRate)
        $ fail $ unlines
                [ "Unexpected sound encoding.  We'd like:"
                , "channels = " ++ show audioChannels
                , "rate     = " ++ show audioRate
                ]
     return s


data World = World
  { ding :: Sample
  , npc  :: NPC
  }

loadWorld :: IO World
loadWorld =
  do ding <- loadSample "ding"
     npc  <- loadNPC
     return World { .. }


data NPC = NPC
  { attack :: Sample
  }

loadNPC :: IO NPC
loadNPC =
  do attack <- loadSample "attack"
     return NPC { .. }



