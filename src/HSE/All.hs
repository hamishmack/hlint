{-# LANGUAGE RecordWildCards #-}

module HSE.All(
    module X,
    ParseFlags(..), defaultParseFlags, parseFlagsAddFixities, parseFlagsSetExtensions,
    parseModuleEx, ParseError(..)
    ) where

import HSE.Util as X
import HSE.Evaluate as X
import HSE.Type as X
import HSE.Bracket as X
import HSE.Match as X
import HSE.Scope as X
import HSE.FreeVars as X
import Util
import CmdLine
import Control.Exception
import Data.Char
import Data.List.Extra
import Data.Maybe
import Language.Preprocessor.Cpphs
import qualified Data.Map as Map


-- | Created with 'defaultParseFlags', used by 'parseModuleEx'.
data ParseFlags = ParseFlags
    {encoding :: Encoding -- ^ How the file is read in (defaults to 'defaultEncoding').
    ,cppFlags :: CppFlags -- ^ How the file is preprocessed (defaults to 'NoCpp').
    ,hseFlags :: ParseMode -- ^ How the file is parsed (defaults to all fixities in the @base@ package and most non-conflicting extensions).
    }

-- | Default values for 'ParseFlags'.
defaultParseFlags :: ParseFlags
defaultParseFlags = ParseFlags defaultEncoding NoCpp defaultParseMode{fixities=Just baseFixities, ignoreLinePragmas=False, extensions=defaultExtensions}

parseFlagsNoLocations :: ParseFlags -> ParseFlags
parseFlagsNoLocations x = x{cppFlags = case cppFlags x of Cpphs y -> Cpphs $ f y; y -> y}
    where f x = x{boolopts = (boolopts x){locations=False}}

parseFlagsAddFixities :: [Fixity] -> ParseFlags -> ParseFlags
parseFlagsAddFixities fx x = x{hseFlags=hse{fixities = Just $ fx ++ fromMaybe [] (fixities hse)}}
    where hse = hseFlags x

parseFlagsSetExtensions :: [Extension] -> ParseFlags -> ParseFlags
parseFlagsSetExtensions es x = x{hseFlags=(hseFlags x){extensions = es}}


runCpp :: CppFlags -> FilePath -> String -> IO String
runCpp NoCpp _ x = return x
runCpp CppSimple _ x = return $ unlines [if "#" `isPrefixOf` trimStart x then "" else x | x <- lines x]
runCpp (Cpphs o) file x = runCpphs o file x


---------------------------------------------------------------------
-- PARSING

-- | A parse error from 'parseModuleEx'.
data ParseError = ParseError
    {parseErrorLocation :: SrcLoc -- ^ Location of the error.
    ,parseErrorMessage :: String -- ^ Message about the cause of the error.
    ,parseErrorContents :: String -- ^ Snippet of several lines (typically 5) including a @>@ character pointing at the faulty line.
    }

-- | Parse a Haskell module. Applies the C pre processor, and uses best-guess fixity resolution if there are ambiguities.
--   The filename @-@ is treated as @stdin@. Requires some flags (often 'defaultParseFlags'), the filename, and optionally the contents of that file.
parseModuleEx :: ParseFlags -> FilePath -> Maybe String -> IO (Either ParseError (Module SrcSpanInfo, [Comment]))
parseModuleEx flags file str = do
        str <- maybe (readFileEncoding (encoding flags) file) return str
        ppstr <- runCpp (cppFlags flags) file str
        case parseFileContentsWithComments (mode flags) ppstr of
            ParseOk (x, cs) -> return $ Right (applyFixity fixity x, cs)
            ParseFailed sl msg -> do
                -- figure out the best line number to grab context from, by reparsing
                flags <- return $ parseFlagsNoLocations flags
                ppstr2 <- runCpp (cppFlags flags) file str
                pe <- return $ case parseFileContentsWithMode (mode flags) ppstr2 of
                    ParseFailed sl2 _ -> context (srcLine sl2) ppstr2
                    _ -> context (srcLine sl) ppstr
                Control.Exception.evaluate $ length pe -- if we fail to parse, we may be keeping the file handle alive
                return $ Left $ ParseError sl msg pe
    where
        fixity = fromMaybe [] $ fixities $ hseFlags flags
        mode flags = (hseFlags flags)
            {parseFilename = file
            ,fixities = Nothing
            }


-- | Given a line number, and some source code, put bird ticks around the appropriate bit.
context :: Int -> String -> String
context lineNo src =
    unlines $ dropWhileEnd (all isSpace) $ dropWhile (all isSpace) $
    zipWith (++) ticks $ take 5 $ drop (lineNo - 3) $ lines src ++ ["","","","",""]
    where ticks = ["  ","  ","> ","  ","  "]


---------------------------------------------------------------------
-- FIXITIES

-- resolve fixities later, so we don't ever get uncatchable ambiguity errors
-- if there are fixity errors, try the cheapFixities (which never fails)
applyFixity :: [Fixity] -> Module_ -> Module_
applyFixity base modu = descendBi f modu
    where
        f x = fromMaybe (cheapFixities fixs x) $ applyFixities fixs x :: Decl_
        fixs = concatMap getFixity (moduleDecls modu) ++ base


-- Apply fixities, but ignoring any ambiguous fixity errors and skipping qualified names,
-- local infix declarations etc. Only use as a backup, if HSE gives an error.
--
-- Inspired by the code at:
-- http://hackage.haskell.org/trac/haskell-prime/attachment/wiki/FixityResolution/resolve.hs
cheapFixities :: [Fixity] -> Decl_ -> Decl_
cheapFixities fixs = descendBi (transform f)
    where
        ask = askFixity fixs
    
        f o@(InfixApp s1 (InfixApp s2 x op1 y) op2 z)
                | p1 == p2 && (a1 /= a2 || a1 == AssocNone) = o -- Ambiguous infix expression!
                | p1 > p2 || p1 == p2 && (a1 == AssocLeft || a2 == AssocNone) = o
                | otherwise = InfixApp s1 x op1 (f $ InfixApp s1 y op2 z)
            where
                (a1,p1) = ask op1
                (a2,p2) = ask op2
        f x = x


askFixity :: [Fixity] -> QOp S -> (Assoc, Int)
askFixity xs = \k -> Map.findWithDefault (AssocLeft, 9) (fromNamed k) mp
    where
        mp = Map.fromList [(s,(a,p)) | Fixity a p x <- xs, let s = fromNamed x, s /= ""]
