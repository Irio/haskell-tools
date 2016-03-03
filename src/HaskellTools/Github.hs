module HaskellTools.Github
    ( searchRepos
    , haskellRepos
    ) where

import Data.Monoid ((<>))

import Network.Wreq ( getWith
                    , Options
                    , Response
                    , asJSON
                    , header
                    , defaults
                    )
import Network.Wreq.Lens (responseBody)
import Control.Lens ( (&)
                    , (.~)
                    , (^..)
                    )

import Data.Aeson.Types (FromJSON
                        , Object
                        , Value
                        )

import Data.ByteString.Lazy
import Data.Aeson.Lens (key, _String, values)

baseUrl :: String
baseUrl = "https://api.github.com/"

getJSON :: Options -> String -> IO (Response ByteString)
getJSON requestOptions path =
    getWith requestOptions (baseUrl ++ path)

searchRepos :: Options -> String -> IO (Response ByteString)
searchRepos options query =
    getJSON options $ "search/repositories?q=" ++ show query

haskellRepos :: Show a => a -> IO [Value]
haskellRepos page = do
  results <- searchRepos defaults $ "a in%3Aname language%3Ahaskell created%3A>2013-10-01&per_page=100&page=" <> show page
  return $ results ^.. repos . (key "name" <> key "watchers" <> key "forks_count" <> owner)
  where
    owner = key "owner" . key "login"
    repos = responseBody . key "items" . values
