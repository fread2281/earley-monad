{-# LANGUAGE RankNTypes, GADTs, TupleSections, OverloadedLists, BangPatterns, ScopedTypeVariables, LambdaCase, FlexibleContexts, FlexibleInstances #-}
module Text.Earley.Parser.Rewrite where

import Control.Monad.ST
-- import Control.Monad.Trans
import Data.STRef
import Control.Monad
import Data.Foldable
import Control.Applicative
import Control.Monad.Fix
import Control.Arrow
import Text.Earley.Grammar
import Data.IntMap (IntMap)
import qualified Data.IntMap as M
import Text.Parser.Combinators

import GHC.Stack


import Debug.Trace
import Data.Coerce
import Data.List.NonEmpty (NonEmpty)




type M s i = State s i -> ST s (State s i)

-- TODO: more stuff here
data State s i = State {
  reset :: ![ST s ()],
  next :: ![M s i],
  -- actions to process once we're done at current position but before next position
  -- used only for rules, keyed by birthpos of the rule
  -- so we can get better complexity
  here :: !(IntMap [M s i]),
  curPos :: {-# UNPACK #-} !Int,
  input :: !i,
  -- | Named productions processed at current positition, used for reporting expected in errors
  names :: ![String]
}
-- obvious way to do coalescing & skip through input is to have next be
-- :: Map (Position,RuleI s e i a) [a -> State s e i -> ST s (State s e i)]


newtype Parser s i a = Parser {
  unParser :: (Results s i a -> M s i) -> M s i
}

liftST :: ST s a -> Parser s i a
liftST f = Parser $ \cb s -> f >>= \x -> cb (pure x) s
{-# INLINE liftST #-}

push :: Int -> a -> IntMap [a] -> IntMap [a]
push i a = M.alter (Just . maybe [a] (a:)) i

-- for some reason this is faster than [a], probably because the instances are lazier
-- / can detect nulls faster ??
newtype Seq a = Seq {unSeq :: Maybe (NonEmpty a) }

instance Functor Seq where
  fmap f = Seq . fmap (fmap f) . unSeq

instance Applicative Seq where
  pure a = Seq $ Just $ pure a
  {-# INLINE pure #-}
  Seq Nothing <*> _ = Seq Nothing
  _ <*> Seq Nothing = Seq Nothing
  Seq (Just f) <*> Seq (Just a) = Seq $ Just (f <*> a)

instance Semigroup (Seq a) where
  Seq Nothing <> a = a
  a <> Seq Nothing = a
  Seq (Just a) <> Seq (Just b) = Seq (Just $ a <> b)
  {-# INLINE (<>) #-}
instance Monoid (Seq a) where
  mempty = Seq Nothing
  {-# INLINE mempty #-}

instance Foldable Seq where
  null (Seq Nothing) = True
  null _ = False
  {-# INLINE null #-}

  toList (Seq Nothing) = []
  toList (Seq (Just l)) = toList l
  foldMap f = foldMap f . toList


newtype Results s i a = Results ((Seq a -> M s i) -> M s i)

instance Functor (Results s i) where
  fmap f (Results g) = Results (\cb -> g (\x -> let !r = fmap f x in cb r))
  {-# INLINE fmap #-}
instance Applicative (Results s i) where
  pure x = Results (\cb -> cb $! pure x)
  {-# INLINE pure #-}
  Results f <*> Results x = Results (\cb -> f (\a -> x (\b -> cb (a <*> b))))
  {-# INLINE (<*>) #-}
  liftA2 f (Results x) (Results y) = Results (\cb -> x (\a -> y (\b -> cb (liftA2 f a b))))
  {-# INLINE liftA2 #-}
  Results x *> Results y = Results (\cb -> x (\a -> y (\b -> cb (a *> b))))
  {-# INLINE (*>) #-}
  Results x <* Results y = Results (\cb -> x (\a -> y (\b -> let !r = a <* b in cb r)))
  {-# INLINE (<*) #-}



-- Can merge results at same rule w/ diff start pos & same end pos!
-- (if a calls b at pos i and j, and i-k & j-k both return results, only need to return once with merged results)
-- however, with fuly binarized/memoized grammars, ignoring alts, we can assume that `a = b <*> c`, but `c` must be a rule, which does some merging for us

-- But this still adds too many callbacks to `c` (if b returns at `i-k` & `j-k`, then `c` gets two instances of `a` in its conts),
-- and callbacks in `c` cost per position where `c` succeeds starting from `k`

-- Practical, General Parser Combinators (Meerkat) avoids this by using a HashSet of Conts in rules.

-- However, this might not cause worst case complexity to go over cubic with fully binarized grammars. According to the meerkat paper,

-- > In Appendix A.3 we show that the execution of memoized CPS
-- > recognizers of Figure 2 and 6 can require O(n^(m+1)) operations, where
-- > m is the length of the longest rule in the grammar. The reason for
-- > such unbounded polynomial behaviour is that the same continuation
-- > can be called multiple times at the same input position. As illustrated
-- > in Appendix A.3, this happens when the same continuation is
-- > added to different continuation lists that are associated with calls
-- > made to the same recognizer but at different input positions.
-- > If the recognizer produces the same input position starting from different
-- > input positions, duplicate calls are made. The duplicate calls further
-- > result in adding the same continuations to the same continuation
-- > lists multiple times

-- I think it still affects non-worst case complexity though :(

-- I don't know if this is avoidable without using StableNames or similar to compare Conts


-- recover :: Parser s e i a -> ST s (Parser s e i a)
-- recover p = do
--   _


data RuleI s i a = RuleI {-# UNPACK #-} !(STRef s (RuleResults s i a)) [Results s i a -> M s i]

-- TODO: maybe store a (Maybe [a]) or have a variant w/o unprocessed? & another w/o processed?
data RuleResults s i a = RuleResults {
  processed :: !(Seq a),
  unprocessed :: !(Seq a),
  callbacks :: [Seq a -> M s i],
  queued :: !Bool
} | DelayedResults [(Seq a -> M s i) -> M s i] | ProcessedResults !(Seq a)


-- what if keeping callabcks around is what's causing the leak?
-- 

-- NOTE: techincally this is two things in one (GLL (and us) merge them):
-- 1. merge multiple `Result`s at same position (optimization, needed to be `O(n^3)`, speeds up `rule (\_ -> (a <|> b) <*> c`)
-- 2. cps processing for start position, to deal with left recursion
ruleP :: forall s i a. (Parser s i a -> Parser s i a) -> ST s (Parser s i a)
ruleP f = do
  -- TODO: remove the Maybe, just use an empty RuleI
  currentRef <- newSTRef (Nothing :: Maybe (STRef s (RuleI s i a)))

  emptyResults <- newSTRef (undefined :: RuleResults s i a)
  let
    resetcb = writeSTRef currentRef Nothing
    resetr !rs =
      -- TODO: when can we gc processed here?
      modifySTRef ({-# SCC "reset2_rs" #-} rs) $ \case
        RuleResults xs s _ False | null s -> ProcessedResults xs
        DelayedResults rxs -> DelayedResults rxs
        _ -> error "earley-monad: invariant violated"
    results !birthPos !pos !ref = Results $ \cb s -> do
      !res <- readSTRef ref
      case res of
        ProcessedResults xs -> cb xs s
        DelayedResults rxs -> do
          writeSTRef ref $ RuleResults {
            processed = mempty,
            unprocessed = mempty,
            callbacks = [cb],
            queued = False
          }
          foldMA (h birthPos ref) rxs $ s { reset = resetr ref:reset s }
        RuleResults{} -> do
          writeSTRef ref $! res { callbacks = cb:callbacks res }
          if null (processed res) then pure s else
            cb (processed res) s
    recheck !ref s = do
      !rs <- readSTRef ref
      case rs of
        RuleResults{} -> do
          let xs = unprocessed rs
          if null xs then pure s else {-# SCC "propagate" #-} do
            writeSTRef ref $! rs { unprocessed = mempty, processed = xs <> processed rs, queued = False }
            -- traceM $ "propagate " <> (show $ length $ callbacks rs) <> " at " <> (show $ curPos s)
            foldMA xs (callbacks rs) s
        _ -> error "earley-monad: invariant violated"
    h !birthPos !ref x s = do
      !res <- readSTRef ref
      -- traceM $ "h " <> show (length x) <> " at "<> (show $ curPos s) <> " from " <> (show birthPos)
      -- when (not $ queued res) $
          --   traceM $ "g again at " <> (show $ curPos s) <> " from " <> (show birthPos)
      writeSTRef ref $! {-# SCC "g_res" #-} res { unprocessed = x <> unprocessed res, queued = True }
      pure $! if queued res then s else {-# SCC "g_s" #-} s { here = push birthPos (recheck ref) (here s) }
    p = Parser $ \cb st -> do
      let !birthPos = curPos st
      readSTRef currentRef >>= \r -> case r of
        Just ref -> do
          RuleI r cbs <- readSTRef ref
          -- traceM $ "new child " <> (show $ length cbs) <> " at " <> (show birthPos)
          writeSTRef ref $ RuleI r (cb:cbs)
          if r == emptyResults then pure st else cb (results birthPos birthPos r) st
        Nothing -> do
          ref <- newSTRef (RuleI emptyResults [cb])
          writeSTRef currentRef (Just ref)
          let
            reset2 =
              modifySTRef ({-# SCC "reset2_ref" #-} ref) (\(RuleI _ cbs) -> RuleI emptyResults cbs)
            g (Results rxs) s = do
              RuleI rs cbs <- readSTRef ref
              if rs == emptyResults
                then do
                  rs' <- {-# SCC "g_rs'" #-} newSTRef $ DelayedResults [rxs]
                  writeSTRef ref $ {-# SCC "g_ref" #-} RuleI rs' cbs
                  -- traceM $ "g " <> (show $ length cbs) <> " at " <> (show birthPos) <> "-" <> (show $ curPos s)
                  let !s' = {-# SCC "g_s1" #-} s {reset = reset2:reset s}
                  foldMA (results birthPos (curPos s) rs') cbs s'
                else do
                  !res <- readSTRef rs
                  -- traceM $ "g again at " <> (show birthPos) <> "-" <> (show $ curPos s)
                  case res of
                    DelayedResults rxs' -> do
                      writeSTRef rs (DelayedResults (rxs:rxs'))
                      pure s
                    RuleResults{} ->
                      rxs (h birthPos rs) s
                    _ -> error "earley-monad: invariant violated"
          unParser (f p) g (st {reset = resetcb:reset st})
  pure p

foldMA :: forall s a b. a -> [a -> b -> ST s b] -> b -> ST s b
foldMA y (x:xs) s = x y s >>= foldMA y xs
foldMA _ [] s = pure s



-- fixP :: (Parser s e i a -> Parser s e i a) -> Parser s e i a
-- fixP f = join $ liftST (ruleP f)

rule :: Parser s i a -> ST s (Parser s i a)
rule p = ruleP (\_ -> p)

bindList :: ([a] -> Parser s i b) -> Parser s i a -> Parser s i b
bindList f (Parser p) = Parser $ \cb -> p (\(Results x) -> x (\l -> unParser (f $ toList l) cb))

fmapList :: ([a] -> b) -> Parser s i a -> Parser s i b
-- TODO: strictness here matters
-- (should be strict for thin, but probably not in general)
fmapList f (Parser p) = Parser $ \cb -> p (\(Results rs) -> cb (Results $ \g -> rs (\l -> g $ pure $! f $ toList l)))
-- {-# INLINE fmapList #-}

-- thin :: Parser s e i a -> Parser s e i ()
-- thin = fmapList (\_ -> ())
thin = bindList (\_ -> pure ())
-- {-# INLINE thin #-}

traceP :: String -> Parser s i a -> Parser s i a
traceP st (Parser p) = Parser $ \cb s -> do
  let !left = curPos s
  traceM $ (show left) <> ": " <> st
  p (\r s' -> (traceM $ (show left) <> "-" <> (show $ curPos s') <> ": " <> st) >> cb r s') s

instance Functor (Parser s i) where
  fmap f (Parser p) = Parser $ \cb -> p (\x -> cb (f <$> x))
  {-# INLINE fmap #-}
  r <$ Parser a = Parser $ \cb -> a (\x -> cb (r <$ x))
  {-# INLINE (<$) #-}
instance Applicative (Parser s i) where
  Parser f <*> Parser a = Parser $ \cb -> f (\f' -> a (\a' -> cb (f' <*> a')))
  {-# INLINE (<*>) #-}
  pure a = Parser ($ pure a)
  {-# INLINE pure #-}
  liftA2 f (Parser a) (Parser b) = Parser $ \cb -> a (\x -> b (\y -> cb (liftA2 f x y)))
  {-# INLINE liftA2 #-}
  Parser a *> Parser b = Parser $ \cb -> a (\x -> b (\y -> cb (x *> y)))
  {-# INLINE (*>) #-}
  Parser a <* Parser b = Parser $ \cb -> a (\x -> b (\y -> cb (x <* y)))
  {-# INLINE (<*) #-}

  -- this is old, currently we aren't merging results so this doesn't matter
  -- -- TODO: do we want this? currently w/ results it only returns once
  -- -- ((a <|> b) *> x) != (a *> x) <|> (b *> x)
  -- -- if a & b both succeed the first will only have one result and the second will have two
  -- -- Parser a *> Parser b = Parser $ \cb -> a (\_ -> b cb)
  -- -- 
  -- {-# INLINE (*>) #-}
instance Monad (Parser s i) where
  return = pure
  {-# INLINE return #-}
  Parser p >>= f = Parser $ \cb -> p (\(Results a) -> a (\xs s -> foldrM (\x -> unParser (f x) cb) s xs))
  {-# INLINE (>>=) #-}

instance Alternative (Parser s i) where
  empty = Parser $ \_ -> pure
  {-# INLINE empty #-}
  -- TODO: can opt this when a & b both return results at same (start,end) range
  -- (can merge results)
  -- Earley does this
  -- only matters for `(a <|> b) <*> c` though
  Parser a <|> Parser b = Parser $ \cb -> a cb >=> b cb
  {-# INLINE (<|>) #-}

-- class CharStream s where
--   -- satisfyS :: (Char -> Bool) -> s -> Maybe s
--   uncons :: s -> Maybe (Char, s)


-- class IsNull s where
--   isNull :: s -> Bool

instance Parsing (Parser s [i]) where
  try x = x
  (<?>) = named
  unexpected n = empty `named` ("unexpected " ++ n)
  eof = Parser $ \cb s -> case input s of
    [] -> cb (pure ()) s
    _ -> pure s
  -- TODO: notFollowedBy should really backtrack
  -- in general it might consume an arbitrary amount of input before failing
  -- / stop throwing away input / support lookahead
  -- a bit complex to do correctly though
  -- similar(same?) problem to error recovery
  -- TODO: it's possible to implement a non-backtracking notFollowedBy without lookahead
  -- & non-backtracking is actually fine for most (all?) uses

terminalP :: (t -> Maybe a) -> Parser s [t] a
terminalP v = Parser $ \cb s -> case input s of
  [] -> pure s
  (x:_) -> case v x of
    Nothing -> pure s
    Just a -> pure $ s {next = cb (pure a):next s}
-- {-# INLINE terminalP #-}

emptyState :: i -> State s i
emptyState i = State {
  reset = [],
  next = [],
  curPos = 0,
  input = i,
  names = [],
  here = mempty
}

-- | A parsing report, which contains fields that are useful for presenting
-- errors to the user if a parse is deemed a failure.  Note however that we get
-- a report even when we successfully parse something.
data Report i = Report
  { position   :: Int -- ^ The final position in the input (0-based) that the
                      -- parser reached.
  , expected   :: [String] -- ^ The named productions processed at the final
                      -- position.
  , unconsumed :: i   -- ^ The part of the input string that was not consumed,
                      -- which may be empty.
  } deriving (Eq, Ord, Read, Show)

-- newtype EndoC c a = EndoC { runEndoC :: c a a }

-- instance Category c => Semigroup (EndoC c) where
--   EndoC a <> EndoC b = EndoC (a . b)



foldM2 :: forall s a b. [b -> ST s b] -> b -> ST s b
foldM2 (x:xs) s = x s >>= foldM2 xs
foldM2 [] s = pure s

run :: Bool -> Parser s [a] r -> [a] -> ST s ([(Seq r, Int)], Report [a])
run keep p l = do
  results <- newSTRef ([] :: [(Results s i r,Int)])
  s1 <- unParser p (\rs s -> modifySTRef results ((rs,curPos s):) >> pure s) (emptyState l)
  let go s = case M.maxView (here s) of
        Just (l,hr) -> foldMA () (fmap const $ reverse l) (s { here = hr }) >>= go
        Nothing -> if null (next s)
          then do
            sequenceA_ (reset s)
            rs' <- newSTRef ([] :: [(Seq r, Int)])
            -- readSTRef results >>= traceM . show . length
            -- TODO: do we need s in Results?
            s' <- readSTRef results >>= foldr
              (\(Results rs, pos) -> (>>= rs (\x s' -> modifySTRef rs' ((x,pos):) >> pure s')))
              (pure ((emptyState l) {curPos = curPos s + 1}))
            -- t <- foldM2 (fmap foldM2 $ toList $ here s') (s' { here = mempty })
            let l t | null (here t) = pure t
                    | otherwise = foldM2 (fmap foldM2 $ toList $ here t) (t { here = mempty }) >>= l
            l s'
            -- traceM $ show $ length $ here t
            -- when (not $ null $ here s') $ void $ go s'
            -- go s'
            rs <- readSTRef rs'
            -- traceM $ show $ length rs
            pure (rs, Report {
              position = curPos s,
              expected = names s,
              unconsumed = input s
            })
          else do
            sequenceA_ (reset s)
            unless keep $ writeSTRef results []
            -- traceM $ show $ curPos s
            go $ State {
              next = [],
              input = tail $ input s,
              -- TODO: this is wrong, should be keeping
              -- info about birthPos in next
              here = M.fromList [(curPos s + 1, next s)],
              curPos = curPos s + 1,
              names = [],
              reset = []
            }
  go s1

named :: Parser s i a -> String -> Parser s i a
named (Parser p) e = Parser $ \cb s -> p cb (s{names = e:names s})
{-# INLINE named #-}

data Rule s e t a where 
  Rule :: Parser s [t] a -> Rule s String t a

-- interpProd :: Prod (Rule s) String t a -> Parser s [t] a
-- interpProd p = case p of
--   Terminal t f -> terminalP t <**> interpProd f
--   NonTerminal (Rule r) f -> r <**> interpProd f
--   Pure a -> pure a
--   Alts as f -> foldr (<|>) empty (fmap interpProd as) <**> interpProd f
--   Many m f -> many (interpProd m) <**> interpProd f
--   Named f e -> interpProd f `named` e
-- {-# INLINE interpProd #-}

-- interpGrammar :: Grammar (Rule s) a -> ST s a
-- interpGrammar g = case g of
--   RuleBind p f -> do
--     r <- ruleP (\_ -> interpProd p)
--     let p' = NonTerminal (Rule r) (pure id)
--     interpGrammar (f p')
--   FixBind f k -> do
--     a <- mfix (interpGrammar . f)
--     interpGrammar $ k a
--   Return a -> pure a
-- {-# INLINE interpGrammar #-}



-- parser :: (forall r. Grammar r (Prod r String t a)) -> ST s (Parser s [t] a)
-- parser g = fmap interpProd $ interpGrammar g
-- {-# INLINE parser #-}

-- allParses :: (forall s. ST s (Parser s e [t] a)) -> [t] -> ([(Seq a,Int)],Report e [t])
-- allParses p i = runST $ do
--   p' <- p
--   run True p' i

-- fullParses :: (forall s. ST s (Parser s e [t] a)) -> [t] -> ([Seq a],Report e [t])
-- fullParses p i = runST $ do
--   p' <- p
--   first (fmap fst) <$> run False p' i

allParses :: (forall s. ST s (Parser s [t] a)) -> [t] -> ([(a,Int)],Report [t])
allParses p i = runST $ do
  p' <- p
  first (foldMap $ \(s,p) -> (,p) <$> toList s) <$> run True p' i

fullParses :: (forall s. ST s (Parser s [t] a)) -> [t] -> ([a],Report [t])
fullParses p i = runST $ do
  p' <- p
  first (foldMap toList . fmap fst) <$> run False p' i


-- | See e.g. how far the parser is able to parse the input string before it
-- fails.  This can be much faster than getting the parse results for highly
-- ambiguous grammars.
report :: (forall s. ST s (Parser s [t] a)) -> [t] -> Report [t]
report p i = runST $ do
  p' <- p
  snd <$> run False p' i

-- ident (x:_) = isAlpha x
-- ident _     = False

token :: Eq t => t -> Parser s [t] t
token y = satisfy (== y)
{-# NOINLINE token #-}

satisfy :: (t -> Bool) -> Parser s [t] t
satisfy f = terminalP (\x -> if f x then Just x else Nothing)
{-# NOINLINE satisfy #-}

f <?> x = named f x

namedToken x = token x `named` x

