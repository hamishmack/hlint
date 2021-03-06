{-# LANGUAGE PatternGuards, ViewPatterns, RelaxedPolyRec, RecordWildCards, FlexibleContexts #-}

{-
The matching does a fairly simple unification between the two terms, treating
any single letter variable on the left as a free variable. After the matching
we substitute, transform and check the side conditions. We also "see through"
both ($) and (.) functions on the right.

TRANSFORM PATTERNS
_eval_ - perform deep evaluation, must be used at the top of a RHS
_noParen_ - don't bracket this particular item

SIDE CONDITIONS
(&&), (||), not - boolean connectives
isAtom x - does x never need brackets
isFoo x - is the root constructor of x a "Foo"
notEq x y - are x and y not equal
notIn xs ys - are all x variables not in ys expressions
noTypeCheck, noQuickCheck - no semantics, a hint for testing only

($) AND (.)
We see through ($)/(.) by expanding it if nothing else matches.
We also see through (.) by translating rules that have (.) equivalents
to separate rules. For example:

concat (map f x) ==> concatMap f x
-- we spot both these rules can eta reduce with respect to x
concat . map f ==> concatMap f
-- we use the associativity of (.) to add
concat . map f . x ==> concatMap f . x
-- currently 36 of 169 rules have (.) equivalents

We see through (.) if the RHS is dull using id, e.g.

not (not x) ==> x
not . not ==> id
not . not . x ==> x
-}

module Hint.Match(readMatch) where

import Data.List.Extra
import Data.Maybe
import Data.Data
import Unsafe.Coerce
import Settings
import Hint.Type
import Control.Monad
import Control.Applicative
import Data.Tuple.Extra
import Util
import qualified Data.Set as Set


fmapAn = fmap (const an)


---------------------------------------------------------------------
-- READ THE RULE

readMatch :: [HintRule] -> DeclHint
readMatch settings = findIdeas (concatMap readRule settings)


readRule :: HintRule -> [HintRule]
readRule (m@HintRule{hintRuleLHS=(fmapAn -> hintRuleLHS), hintRuleRHS=(fmapAn -> hintRuleRHS), hintRuleSide=(fmap fmapAn -> hintRuleSide)}) =
    (:) m{hintRuleLHS=hintRuleLHS,hintRuleSide=hintRuleSide,hintRuleRHS=hintRuleRHS} $ fromMaybe [] $ do
        (l,v1) <- dotVersion hintRuleLHS
        (r,v2) <- dotVersion hintRuleRHS
        guard $ v1 == v2 && l /= [] && (length l > 1 || length r > 1) && Set.notMember v1 (freeVars $ maybeToList hintRuleSide ++ l ++ r)
        if r /= [] then return
            [m{hintRuleLHS=dotApps l, hintRuleRHS=dotApps r, hintRuleSide=hintRuleSide}
            ,m{hintRuleLHS=dotApps (l++[toNamed v1]), hintRuleRHS=dotApps (r++[toNamed v1]), hintRuleSide=hintRuleSide}]
         else if length l > 1 then return
            [m{hintRuleLHS=dotApps l, hintRuleRHS=toNamed "id", hintRuleSide=hintRuleSide}
            ,m{hintRuleLHS=dotApps (l++[toNamed v1]), hintRuleRHS=toNamed v1, hintRuleSide=hintRuleSide}]
         else
            Nothing


-- find a dot version of this rule, return the sequence of app prefixes, and the var
dotVersion :: Exp_ -> Maybe ([Exp_], String)
dotVersion (view -> Var_ v) | isUnifyVar v = Just ([], v)
dotVersion (fromApps -> xs) | length xs > 1 = first (apps (init xs) :) <$> dotVersion (fromParen $ last xs)
dotVersion _ = Nothing


---------------------------------------------------------------------
-- PERFORM THE MATCHING

findIdeas :: [HintRule] -> Scope -> Module S -> Decl_ -> [Idea]
findIdeas matches s _ decl =
  [ (idea (hintRuleSeverity m) (hintRuleName m) x y){ideaNote=notes}
  | decl <- case decl of InstDecl{} -> children decl; _ -> [decl]
  , (parent,x) <- universeParentExp decl, not $ isParen x, let x2 = fmapAn x
  , m <- matches, Just (y,notes) <- [matchIdea s decl m parent x2]]


matchIdea :: Scope -> Decl_ -> HintRule -> Maybe (Int, Exp_) -> Exp_ -> Maybe (Exp_,[Note])
matchIdea s decl HintRule{..} parent x = do
    let nm a b = scopeMatch (hintRuleScope,a) (s,b)
    u <- unifyExp nm True hintRuleLHS x
    u <- check u
    let e = subst u hintRuleRHS
    let res = addBracket parent $ unqualify hintRuleScope s u $ performEval e
    guard $ (freeVars e Set.\\ Set.filter (not . isUnifyVar) (freeVars hintRuleRHS))
            `Set.isSubsetOf` freeVars x
        -- check no unexpected new free variables
    guard $ checkSide hintRuleSide $ ("original",x) : ("result",res) : u
    guard $ checkDefine decl parent res
    return (res,hintRuleNotes)


---------------------------------------------------------------------
-- UNIFICATION

type NameMatch = QName S -> QName S -> Bool

nmOp :: NameMatch -> QOp S -> QOp S -> Bool
nmOp nm (QVarOp _ x) (QVarOp _ y) = nm x y
nmOp nm (QConOp _ x) (QConOp _ y) = nm x y
nmOp nm  _ _ = False


-- unify a b = c, a[c] = b
unify :: Data a => NameMatch -> Bool -> a -> a -> Maybe [(String,Exp_)]
unify nm root x y | Just x <- cast x = unifyExp nm root x (unsafeCoerce y)
                  | Just x <- cast x = unifyPat nm x (unsafeCoerce y)
                  | otherwise = unifyDef nm x y


unifyDef :: Data a => NameMatch -> a -> a -> Maybe [(String,Exp_)]
unifyDef nm x y = fmap concat . sequence =<< gzip (unify nm False) x y


-- App/InfixApp are analysed specially for performance reasons
-- root = True, this is the outside of the expr
-- do not expand out a dot at the root, since otherwise you get two matches because of readRule (Bug #570)
unifyExp :: NameMatch -> Bool -> Exp_ -> Exp_ -> Maybe [(String,Exp_)]
unifyExp nm root x y | isParen x || isParen y = unifyExp nm root (fromParen x) (fromParen y)
unifyExp nm root (Var _ (fromNamed -> v)) y | isUnifyVar v = Just [(v,y)]
unifyExp nm root (Var _ x) (Var _ y) | nm x y = Just []
unifyExp nm root x@(App _ x1 x2) (App _ y1 y2) =
    liftM2 (++) (unifyExp nm False x1 y1) (unifyExp nm False x2 y2) `mplus`
    (do guard $ not root; InfixApp _ y11 dot y12 <- return $ fromParen y1; guard $ isDot dot; unifyExp nm root x (App an y11 (App an y12 y2)))
unifyExp nm root x (InfixApp _ lhs2 op2 rhs2)
    | InfixApp _ lhs1 op1 rhs1 <- x = guard (nmOp nm op1 op2) >> liftM2 (++) (unifyExp nm False lhs1 lhs2) (unifyExp nm False rhs1 rhs2)
    | isDol op2 = unifyExp nm root x $ App an lhs2 rhs2
    | otherwise = unifyExp nm root x $ App an (App an (opExp op2) lhs2) rhs2
unifyExp nm root x y | isOther x, isOther y = unifyDef nm x y
unifyExp nm root _ _ = Nothing


unifyPat :: NameMatch -> Pat_ -> Pat_ -> Maybe [(String,Exp_)]
unifyPat nm (PVar _ x) (PVar _ y) = Just [(fromNamed x, toNamed $ fromNamed y)]
unifyPat nm (PVar _ x) PWildCard{} = Just [(fromNamed x, toNamed $ "_" ++ fromNamed x)]
unifyPat nm x y = unifyDef nm x y 


-- types that are not already handled in unify
{-# INLINE isOther #-}
isOther Var{} = False
isOther App{} = False
isOther InfixApp{} = False
isOther _ = True


---------------------------------------------------------------------
-- SUBSTITUTION UTILITIES

-- check the unification is valid
check :: [(String,Exp_)] -> Maybe [(String,Exp_)]
check = mapM f . groupSort
    where f (x,ys) = if length (nub ys) == 1 then Just (x,head ys) else Nothing


-- perform a substitution
subst :: [(String,Exp_)] -> Exp_ -> Exp_
subst bind = transform g . transformBracket f
    where
        f (Var _ (fromNamed -> x)) | isUnifyVar x = lookup x bind
        f _ = Nothing

        g (App _ np x) | np ~= "_noParen_" = fromParen x
        g x = x


---------------------------------------------------------------------
-- SIDE CONDITIONS

checkSide :: Maybe Exp_ -> [(String,Exp_)] -> Bool
checkSide x bind = maybe True f x
    where
        f (InfixApp _ x op y)
            | opExp op ~= "&&" = f x && f y
            | opExp op ~= "||" = f x || f y
        f (App _ x y) | x ~= "not" = not $ f y
        f (Paren _ x) = f x

        f (App _ cond (sub -> y))
            | 'i':'s':typ <- fromNamed cond
            = isType typ y
        f (App _ (App _ cond (sub -> x)) (sub -> y))
            | cond ~= "notIn" = and [x `notElem` universe y | x <- list x, y <- list y]
            | cond ~= "notEq" = x /= y
        f x | x ~= "noTypeCheck" = True
        f x | x ~= "noQuickCheck" = True
        f x = error $ "Hint.Match.checkSide, unknown side condition: " ++ prettyPrint x

        isType "Compare" x = True -- just a hint for proof stuff
        isType "Atom" x = isAtom x
        isType "WHNF" x = isWHNF x
        isType "Nat" (asInt -> Just x) | x >= 0 = True
        isType "Pos" (asInt -> Just x) | x >  0 = True
        isType "Neg" (asInt -> Just x) | x <  0 = True
        isType "NegZero" (asInt -> Just x) | x <= 0 = True
        isType ('L':'i':'t':typ@(_:_)) (Lit _ x) = head (words $ show x) == typ
        isType typ x = head (words $ show x) == typ

        asInt :: Exp_ -> Maybe Integer
        asInt (Paren _ x) = asInt x
        asInt (NegApp _ x) = negate <$> asInt x
        asInt (Lit _ (Int _ x _)) = Just x
        asInt _ = Nothing

        list :: Exp_ -> [Exp_]
        list (List _ xs) = xs
        list x = [x]

        sub :: Exp_ -> Exp_
        sub = transform f
            where f (view -> Var_ x) | Just y <- lookup x bind = y
                  f x = x


-- does the result look very much like the declaration
checkDefine :: Decl_ -> Maybe (Int, Exp_) -> Exp_ -> Bool
checkDefine x Nothing y = fromNamed x /= fromNamed (transformBi unqual $ head $ fromApps y)
checkDefine _ _ _ = True


---------------------------------------------------------------------
-- TRANSFORMATION

-- if it has _eval_ do evaluation on it
performEval :: Exp_ -> Exp_
performEval (App _ e x) | e ~= "_eval_" = evaluate x
performEval x = x


-- contract Data.List.foo ==> foo, if Data.List is loaded
-- change X.foo => Module.foo, where X is looked up in the subst
unqualify :: Scope -> Scope -> [(String,Exp_)] -> Exp_ -> Exp_
unqualify from to subs = transformBi f
    where
        f (Qual _ (ModuleName _ [m]) x) | Just y <- fromNamed <$> lookup [m] subs
            = if null y then UnQual an x else Qual an (ModuleName an y) x
        f x = scopeMove (from,x) to


addBracket :: Maybe (Int,Exp_) -> Exp_ -> Exp_
addBracket (Just (i,p)) c | needBracket i p c = Paren an c
addBracket _ x = x
