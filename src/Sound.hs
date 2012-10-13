{-# LANGUAGE RecordWildCards #-}
module Sound where

import Sound.Play
import System.FilePath
import Paths_Ninjas


data World = World
  { ding :: Sample
  }

loadSample :: FilePath -> IO Sample
loadSample x = sampleFromFile =<< getDataFileName ("sounds" </> x <.> "ogg")


loadWorld :: IO World
loadWorld =
  do ding <- loadSample "ding"
     return World { .. }



